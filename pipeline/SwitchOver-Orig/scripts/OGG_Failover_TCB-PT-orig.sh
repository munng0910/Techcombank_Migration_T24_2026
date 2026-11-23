#!/usr/bin/env bash
# ==============================================================================
# Script Name : start_ogg_services.sh
# Purpose     : Idempotent Startup Procedure for Oracle GoldenGate MA (Non-systemd)
# Standards   : Idempotent, Clean Logging, Secure Passwords, Verdict PASS/FAIL
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. ENVIRONMENT & PATH CONFIGURATIONS
# ------------------------------------------------------------------------------
export SM_HOME="/data/ogg_oracle/ServiceManager"
export OGG_HOME="/u01/OracleGoldenGate/ogg_oracle/oggma"
export OGG_VAR_HOME="${SM_HOME}/var"
export OGG_ETC_HOME="${SM_HOME}/etc"
export OGG_CONF_HOME="${SM_HOME}/etc/conf"

ADMINCLIENT_DB="/u01/OracleGoldenGate/ogg_oracle/oggma/bin/adminclient"
ADMINCLIENT_DAA="/u01/OracleGoldenGate/ogg_daa/oggma/bin/adminclient"

LOG_DIR="${OGG_VAR_HOME}/log"
mkdir -p "${LOG_DIR}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/ogg_startup_${TIMESTAMP}.log"
PID_LOCK_FILE="/tmp/ogg_start_process.pid"

# Connection Strings
CONN_SM="connect https://localhost:7801 deployment ServiceManager as oggadmin password oracle_4U"
CONN_DB="connect https://localhost:7862 deployment ogg_oracle03 as oggadmin password oracle_4U"
CONN_DAA="connect https://localhost:7872 deployment ogg_daa03 as oggadmin password oracle_4U"

# ------------------------------------------------------------------------------
# 2. HELPER FUNCTIONS (LOGGING, LOCKING & EXECUTION)
# ------------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local msg="$*"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Prevent concurrent execution using a PID lock file
check_single_execution() {
    if [[ -f "${PID_LOCK_FILE}" ]]; then
        local pid
        pid=$(cat "${PID_LOCK_FILE}" 2>/dev/null || true)
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            echo "[ERROR] Script is already running under PID: ${pid}. Exiting." >&2
            exit 1
        fi
    fi
    echo "$$" > "${PID_LOCK_FILE}"
    trap 'rm -f "${PID_LOCK_FILE}"' EXIT INT TERM
}

run_adminclient_cmd() {
    local bin_path="$1"
    local connect_cmd="$2"
    local ogg_cmds="$3"

    if [[ ! -x "${bin_path}" ]]; then
        log "ERROR" "Adminclient binary not found or not executable: ${bin_path}"
        return 1
    fi

    # Execute adminclient and filter out connect lines containing credentials
    "${bin_path}" <<EOF 2>&1 | grep -v -i "connect https://" | tee -a "${LOG_FILE}"
${connect_cmd} !
${ogg_cmds}
exit
EOF
}

# ------------------------------------------------------------------------------
# 3. STEP 1: CLEANUP & STOP EXISTING PROCESSES / STALE SOCKETS
# ------------------------------------------------------------------------------
cleanup_and_stop_existing() {
    log "INFO" "=================== STEP 1: CLEANUP & STOP EXISTING SERVICES ==================="

    # 1.1. Terminate leftover ServiceManager / Microservices zombie processes
    log "INFO" "Checking and cleaning up stale OGG processes..."
    pkill -9 -f "${SM_HOME}/bin/ServiceManager" 2>/dev/null || true
    pkill -9 -f "adminsrvr|distsrvr|recvsrvr|pmsrvr" 2>/dev/null || true
    sleep 2

    # 1.2. Clean up stale lock files and sockets after a system reboot
    log "INFO" "Cleaning up stale lock/socket files post-reboot..."
    if [[ -d "${OGG_VAR_HOME}/run" ]]; then
        find "${OGG_VAR_HOME}/run" -type f -name "*.pid" -delete 2>/dev/null || true
        find "${OGG_VAR_HOME}/run" -type s -delete 2>/dev/null || true
    fi
    if [[ -d "${OGG_VAR_HOME}/lock" ]]; then
        find "${OGG_VAR_HOME}/lock" -type f -delete 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 4. STEP 2: START SERVICE MANAGER (DAEMON)
# ------------------------------------------------------------------------------
start_service_manager() {
    log "INFO" "=================== STEP 2: START SERVICE MANAGER ==================="

    local start_script="${SM_HOME}/bin/startSM.sh"
    if [[ ! -x "${start_script}" ]]; then
        log "ERROR" "startSM.sh not found or not executable at: ${start_script}"
        return 1
    fi

    log "INFO" "Launching ServiceManager daemon..."

    # Execute in an isolated subshell and disown to completely sever process handles
    local sm_start_log="${LOG_DIR}/servicemanager_start_${TIMESTAMP}.log"

    log "INFO" "ServiceManager launcher output: ${sm_start_log}"

    nohup "${start_script}" </dev/null >>"${sm_start_log}" 2>&1 &
    disown "$!"

    # Wait for ServiceManager to spawn and bind (timeout: 30 seconds)
    local retry=0
    local max_retry=15
    local sm_running=false

    while [[ ${retry} -lt ${max_retry} ]]; do
    sleep 2

    if pgrep -af "[S]erviceManager" >/dev/null 2>&1; then
        sm_running=true
        break
    fi

    retry=$((retry + 1))
    log "INFO" "Waiting for ServiceManager (${retry}/${max_retry})..."
    done


    if [[ "${sm_running}" == "true" ]]; then
        log "INFO" "ServiceManager STARTED successfully (PID: $(pgrep -f "${SM_HOME}/bin/ServiceManager" | head -n1))."
    else
        log "ERROR" "ServiceManager failed to START within 30 seconds!"
        return 1
    fi

    log "INFO" "Waiting for ServiceManager REST listener to initialize (10 seconds)..."
    sleep 10
}

# ------------------------------------------------------------------------------
# 5. STEP 3: START DEPLOYMENTS VIA SERVICEMANAGER
# ------------------------------------------------------------------------------
start_deployments() {
    log "INFO" "=================== STEP 3: START DEPLOYMENTS ==================="

    log "INFO" ">> Connecting to ServiceManager to start all deployments..."
    local cmds_sm="
start deployment *
sh sleep 5
info all
"
    run_adminclient_cmd "${ADMINCLIENT_DB}" "${CONN_SM}" "${cmds_sm}"

    # Verify deployments status
    log "INFO" "Verifying deployment statuses in ServiceManager..."
    local sm_status_output
    sm_status_output=$("${ADMINCLIENT_DB}" <<EOF 2>&1 | grep -v -i "connect https://"
${CONN_SM} !
info all
exit
EOF
)
    echo "${sm_status_output}" >> "${LOG_FILE}"

    if echo "${sm_status_output}" | grep -iE "STOPPED|FAILED|DOWN" >/dev/null 2>&1; then
        log "ERROR" "[CHECK FAIL] One or more deployments failed to start:"
        echo "${sm_status_output}" | grep -iE "STOPPED|FAILED|DOWN" | tee -a "${LOG_FILE}"
        return 1
    else
        log "INFO" "[CHECK PASS] All deployments are RUNNING."
    fi

    log "INFO" "Waiting for deployment Microservices Daemons to initialize (10 seconds)..."
    sleep 10
}

# ------------------------------------------------------------------------------
# 6. STEP 4: START EXTRACTS & REPLICATS VIA ADMINCLIENT
# ------------------------------------------------------------------------------
start_ogg_processes() {
    log "INFO" "=================== STEP 4: START EXTRACT & REPLICAT PROCESSES ==================="

    # --- 4.1. Start Extract / Processes on DB Deployment (CORELIVEDB) ---
    log "INFO" ">> Connecting to Deployment OGGHUB_CORELIVEDB (Port 7801)..."
    local cmds_db="
start extract DS1EXT3
start extract EXT24P
start extract ET24P
sh sleep 5
info extract * detail
"
    run_adminclient_cmd "${ADMINCLIENT_DB}" "${CONN_DB}" "${cmds_db}"

    # --- 4.2. Start Replicat / Processes on DAA Deployment ---
    log "INFO" ">> Connecting to Deployment OGGHUB_DAA (Port 7901)..."
    local cmds_daa="
start REPLICAT RKKAE
start REPLICAT RKKPL01
start REPLICAT RKKPL02
start REPLICAT RMSKC
start REPLICAT RMSKDBP
start REPLICAT RMSKL
start REPLICAT RPLDS1
start REPLICAT RPLDS2
start REPLICAT RPLDS3
start REPLICAT RPMSK
start REPLICAT RPMSK02
sh sleep 5
info replicat *
"
    run_adminclient_cmd "${ADMINCLIENT_DAA}" "${CONN_DAA}" "${cmds_daa}"
}

# ------------------------------------------------------------------------------
# 7. STEP 5: VERIFY ACTUAL STATUS & RETURN FINAL VERDICT PASS/FAIL
# ------------------------------------------------------------------------------
verify_overall_health() {
    log "INFO" "=================== STEP 5: VERIFY OVERALL SYSTEM HEALTH ==================="
    local failed=0

    # 5.1. Check ServiceManager Process
    if pgrep -af "${SM_HOME}/bin/ServiceManager" >/dev/null 2>&1; then
        log "INFO" "[CHECK PASS] ServiceManager is RUNNING."
    else
        log "ERROR" "[CHECK FAIL] ServiceManager is NOT running!"
        ((failed++))
    fi

    # 5.2. Check for stopped/abended processes on DB Deployment
    log "INFO" "Checking process status on OGGHUB_CORELIVEDB..."
    local db_status_output
    db_status_output=$("${ADMINCLIENT_DB}" <<EOF 2>&1 | grep -v -i "connect https://"
${CONN_DB} !
info all
exit
EOF
)
    echo "${db_status_output}" >> "${LOG_FILE}"

    if echo "${db_status_output}" | grep -E "STOPPED|ABENDED" >/dev/null 2>&1; then
        log "WARN" "[CHECK FAIL] Found STOPPED or ABENDED processes on OGGHUB_CORELIVEDB:"
        echo "${db_status_output}" | grep -E "STOPPED|ABENDED" | tee -a "${LOG_FILE}"
        ((failed++))
    else
        log "INFO" "[CHECK PASS] All processes on OGGHUB_CORELIVEDB are RUNNING."
    fi

    # 5.3. Check for stopped/abended processes on DAA Deployment
    log "INFO" "Checking process status on OGGHUB_DAA..."
    local daa_status_output
    daa_status_output=$("${ADMINCLIENT_DAA}" <<EOF 2>&1 | grep -v -i "connect https://"
${CONN_DAA} !
info all
exit
EOF
)
    echo "${daa_status_output}" >> "${LOG_FILE}"

    if echo "${daa_status_output}" | grep -E "STOPPED|ABENDED" >/dev/null 2>&1; then
        log "WARN" "[CHECK FAIL] Found STOPPED or ABENDED processes on OGGHUB_DAA:"
        echo "${daa_status_output}" | grep -E "STOPPED|ABENDED" | tee -a "${LOG_FILE}"
        ((failed++))
    else
        log "INFO" "[CHECK PASS] All processes on OGGHUB_DAA are RUNNING."
    fi

    # 5.4. Final Verdict Evaluation
    log "INFO" "=================================================================="
    if [[ ${failed} -eq 0 ]]; then
        log "INFO" ">>> OVERALL STATUS: [ VERDICT: PASS ] - All OGG Services are operational!"
        return 0
    else
        log "ERROR" ">>> OVERALL STATUS: [ VERDICT: FAIL ] - Detected ${failed} error(s) during startup!"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION FLOW
# ------------------------------------------------------------------------------
main() {
    check_single_execution
    log "INFO" "Starting OGG MA Services startup procedure (Log file: ${LOG_FILE})"

    cleanup_and_stop_existing
    start_service_manager
    start_deployments
    start_ogg_processes

    if verify_overall_health; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
 