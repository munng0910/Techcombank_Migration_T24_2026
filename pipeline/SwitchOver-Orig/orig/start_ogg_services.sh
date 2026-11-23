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
TIMESTAMP=""
LOG_FILE=""
PID_LOCK_FILE="/tmp/ogg_start_process.pid"

DB_DEPLOYMENT="ogg_oracle03"
DAA_DEPLOYMENT="ogg_daa03"
DB_PROCESSES=(DS1EXT3 EXT24P ET24P)
DAA_PROCESSES=(RKKPL01 RKKPL02)

declare -A PROCESS_STATUS=()
declare -A PROCESS_DETAIL=()
SM_STATUS="NOT CHECKED"
SM_DETAIL=""
DB_STATUS="NOT CHECKED"
DAA_STATUS="NOT CHECKED"
DB_RUNNING=0
DAA_RUNNING=0
CURRENT_STEP="Initialization"
FAILURE_REASON=""
HEALTH_VERIFIED=false
LOCK_OWNED=false
LOG_READY=false

# Connection Strings
CONN_SM="connect https://localhost:7801 deployment ServiceManager as oggadmin password oracle_4U"
CONN_DB="connect https://localhost:7801 deployment ogg_oracle03 as oggadmin password oracle_4U"
CONN_DAA="connect https://localhost:7801 deployment ogg_daa03 as oggadmin password oracle_4U"

# ------------------------------------------------------------------------------
# 2. HELPER FUNCTIONS (LOGGING, LOCKING & EXECUTION)
# ------------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local msg="$*"
    local line="[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
    if [[ "${LOG_READY}" == "true" ]]; then
        printf '%s\n' "${line}" | tee -a "${LOG_FILE}"
    else
        printf '%s\n' "${line}"
    fi
}

record_failure() {
    if [[ -z "${FAILURE_REASON}" ]]; then
        FAILURE_REASON="$*"
    fi
}

# The EXIT handler reports cached observations only; it never queries services.
finalize() {
    local rc="$1"
    trap - EXIT INT TERM
    set +e

    local owner=""
    if [[ "${LOCK_OWNED}" == "true" && -f "${PID_LOCK_FILE}" ]]; then
        if IFS= read -r owner < "${PID_LOCK_FILE}" && [[ "${owner}" == "$$" ]]; then
            if ! rm -f -- "${PID_LOCK_FILE}"; then
                record_failure "Could not remove this invocation's PID lock."
                [[ ${rc} -ne 0 ]] || rc=1
            fi
        fi
    fi

    local verdict="FAIL"
    if [[ ${rc} -eq 0 && "${HEALTH_VERIFIED}" == "true" ]]; then
        verdict="PASS"
    else
        [[ ${rc} -ne 0 ]] || rc=1
        record_failure "${CURRENT_STEP} did not complete successfully (exit ${rc})."
    fi

    local -a summary=(
        "================ FINAL STARTUP SUMMARY ================"
        "ServiceManager process: ${SM_STATUS}${SM_DETAIL:+ - ${SM_DETAIL}}"
        "${DB_DEPLOYMENT}:7862 / required Extracts: ${DB_STATUS} (${DB_RUNNING}/${#DB_PROCESSES[@]} RUNNING)"
    )
    local group key
    for group in "${DB_PROCESSES[@]}"; do
        key="${DB_DEPLOYMENT}/${group}"
        summary+=("  EXTRACT ${group}: ${PROCESS_STATUS[${key}]:-NOT CHECKED}${PROCESS_DETAIL[${key}]:+ - ${PROCESS_DETAIL[${key}]}}")
    done
    summary+=("${DAA_DEPLOYMENT}:7872 / required Replicats: ${DAA_STATUS} (${DAA_RUNNING}/${#DAA_PROCESSES[@]} RUNNING)")
    for group in "${DAA_PROCESSES[@]}"; do
        key="${DAA_DEPLOYMENT}/${group}"
        summary+=("  REPLICAT ${group}: ${PROCESS_STATUS[${key}]:-NOT CHECKED}${PROCESS_DETAIL[${key}]:+ - ${PROCESS_DETAIL[${key}]}}")
    done
    local verdict_index=${#summary[@]}
    summary+=("VERDICT: ${verdict}")
    if [[ "${verdict}" == "FAIL" ]]; then
        summary+=("Failed step: ${CURRENT_STEP}" "Reason: ${FAILURE_REASON}")
    fi
    local exit_index=${#summary[@]}
    summary+=("Exit code: ${rc}" "Log file: ${LOG_FILE:-NOT AVAILABLE}" "=======================================================")

    if [[ "${LOG_READY}" == "true" ]]; then
        if ! printf '%s\n' "${summary[@]}" >> "${LOG_FILE}"; then
            [[ ${rc} -ne 0 ]] || rc=1
            summary[${verdict_index}]="VERDICT: FAIL"
            summary[${exit_index}]="Exit code: ${rc}"
            summary+=("Reporting error: Could not append the final summary to the log.")
            if [[ "${verdict}" == "PASS" ]]; then
                summary+=("Failed step: Write final summary" "Reason: Final summary could not be saved to the log.")
            fi
        fi
    fi
    printf '%s\n' "${summary[@]}"
    exit "${rc}"
}

# Prevent concurrent execution using a PID lock file.
check_single_execution() {
    if [[ -f "${PID_LOCK_FILE}" ]]; then
        local pid
        pid=$(cat "${PID_LOCK_FILE}" 2>/dev/null || true)
        if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            record_failure "Script is already running under PID ${pid}."
            log "ERROR" "${FAILURE_REASON}"
            return 1
        fi
    fi
    echo "$$" > "${PID_LOCK_FILE}"
    LOCK_OWNED=true
}

# Require the configured executable AND this instance's exported configuration.
find_service_manager_pid() {
    local expected alternate candidates pid executable entry rc
    local uncertain=false instance_seen matched
    expected=$(readlink -f "${OGG_HOME}/bin/ServiceManager") || return 2
    alternate=$(readlink -f "${SM_HOME}/bin/ServiceManager") || alternate=""
    if candidates=$(pgrep -u "$(id -u)" -x ServiceManager); then
        :
    else
        rc=$?
        [[ ${rc} -eq 1 ]] && return 1
        return 2
    fi

    for pid in ${candidates}; do
        executable=$(readlink -f "/proc/${pid}/exe") || { uncertain=true; continue; }
        [[ "${executable}" == "${expected}" || "${executable}" == "${alternate}" ]] || continue
        if [[ ! -r "/proc/${pid}/environ" ]]; then
            uncertain=true
            continue
        fi
        instance_seen=false
        matched=false
        while IFS= read -r -d '' entry; do
            case "${entry}" in
                OGG_VAR_HOME=*)
                    instance_seen=true
                    [[ "${entry}" != "OGG_VAR_HOME=${OGG_VAR_HOME}" ]] || matched=true
                    ;;
                OGG_CONF_HOME=*)
                    instance_seen=true
                    [[ "${entry}" != "OGG_CONF_HOME=${OGG_CONF_HOME}" ]] || matched=true
                    ;;
            esac
        done < "/proc/${pid}/environ"
        if [[ "${matched}" == "true" ]]; then
            printf '%s\n' "${pid}"
            return 0
        fi
        [[ "${instance_seen}" == "true" ]] || uncertain=true
    done
    [[ "${uncertain}" == "false" ]] || return 2
    return 1
}

run_adminclient_cmd() {
    local bin_path="$1"
    local connect_cmd="$2"
    local ogg_cmds="$3"
    local output diagnostics rc=0 response_error=false

    if [[ ! -x "${bin_path}" ]]; then
        record_failure "AdminClient binary is unavailable: ${bin_path}"
        log "ERROR" "${FAILURE_REASON}"
        return 1
    fi

    output=$("${bin_path}" <<EOF 2>&1
${connect_cmd} !
${ogg_cmds}
exit
EOF
) || rc=$?
    # A normal CONNECT echo starts with "OGG (not connected) 1>".
    # Ignore only those command echoes, not real connection-error diagnostics.
    diagnostics=$(grep -viE '^[[:space:]]*OGG[[:space:]]+\([^)]*\)[[:space:]]+[0-9]+>[[:space:]]*connect[[:space:]]+https?://' <<< "${output}" || true)
    # Match diagnostic lines, not detail fields such as "Error log /...".
    # GoldenGate severity tokens are uppercase, optionally after a timestamp.
    local diagnostic_prefix='^[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2}[T[:space:]][0-9:.+-]+Z?[[:space:]]+)?'
    # Here-strings avoid grep -q causing a producer SIGPIPE under pipefail.
    if grep -qE "${diagnostic_prefix}(ERROR|FATAL)([[:space:]:-]|$)" <<< "${diagnostics}" ||
       grep -qiE "${diagnostic_prefix}((error|fatal)[[:space:]]*[:-]|not connected([[:space:][:punct:]]|$)|connection.*(failed|refused)|authentication.*failed|invalid command|syntax error|unknown command|cannot connect|unable to connect)|^[[:space:]]*OGG[[:space:]]+\(not connected\)[[:space:]]+[0-9]+>" <<< "${diagnostics}"; then
        response_error=true
    fi
    # Filter echoed connection lines before writing any AdminClient output.
    output=$(printf '%s\n' "${output}" | grep -v -i 'connect https://' || true)
    if ! printf '%s\n' "${output}" | tee -a "${LOG_FILE}"; then
        record_failure "Could not log AdminClient output during ${CURRENT_STEP}."
        [[ ${rc} -ne 0 ]] || rc=1
        return "${rc}"
    fi
    if [[ ${rc} -ne 0 || "${response_error}" == "true" ]]; then
        record_failure "AdminClient request failed during ${CURRENT_STEP} (exit ${rc}, error text detected: ${response_error}); see log."
        [[ ${rc} -ne 0 ]] || rc=1
        return "${rc}"
    fi
}

# Parse only exact INFO ALL program/status/group rows for the required inventory.
verify_deployment_processes() {
    local deployment="$1" program="$2" bin_path="$3" connect_cmd="$4"
    shift 4
    local -a groups=("$@")
    local output query_ok=true group key row_program row_status row_group remainder
    local running=0 failed=0 query_rc=0
    local -A counts=()

    if output=$(run_adminclient_cmd "${bin_path}" "${connect_cmd}" 'info all'); then
        :
    else
        query_rc=$?
        query_ok=false
    fi
    for group in "${groups[@]}"; do
        key="${deployment}/${group}"
        PROCESS_STATUS[${key}]="UNKNOWN"
        PROCESS_DETAIL[${key}]="Required group missing from INFO ALL output"
        counts[${group}]=0
        if [[ "${query_ok}" == "false" ]]; then
            PROCESS_DETAIL[${key}]="Status query failed; see log"
        fi
    done

    if [[ "${query_ok}" == "true" ]]; then
        while read -r row_program row_status row_group remainder; do
            [[ "${row_program^^}" == "${program}" ]] || continue
            row_group="${row_group^^}"
            [[ -n "${row_group}" && -n "${counts[${row_group}]+present}" ]] || continue
            key="${deployment}/${row_group}"
            counts[${row_group}]=$((counts[${row_group}] + 1))
            row_status="${row_status^^}"
            if [[ ${counts[${row_group}]} -gt 1 ]]; then
                PROCESS_STATUS[${key}]="UNKNOWN"
                PROCESS_DETAIL[${key}]="Duplicate INFO ALL rows"
            elif [[ "${row_status}" =~ ^(RUNNING|STOPPED|ABENDED|STARTING|STOPPING|SUSPENDED)$ ]]; then
                # Accept an optional Type column, but require both time columns.
                if [[ "${remainder}" =~ ^([[:alpha:]_-]+[[:space:]]+)*[0-9]+:[0-9]{2}:[0-9]{2}[[:space:]]+[0-9]+:[0-9]{2}:[0-9]{2}[[:space:]]*$ ]]; then
                    PROCESS_STATUS[${key}]="${row_status}"
                    PROCESS_DETAIL[${key}]=""
                else
                    PROCESS_DETAIL[${key}]="Malformed INFO ALL row"
                fi
            else
                PROCESS_DETAIL[${key}]="Unrecognized INFO ALL status"
            fi
        done <<< "${output}"
    fi

    for group in "${groups[@]}"; do
        key="${deployment}/${group}"
        if [[ "${PROCESS_STATUS[${key}]}" == "RUNNING" ]]; then
            running=$((running + 1))
        else
            failed=$((failed + 1))
            record_failure "${deployment} ${program} ${group}: ${PROCESS_STATUS[${key}]}${PROCESS_DETAIL[${key}]:+ - ${PROCESS_DETAIL[${key}]}}"
        fi
    done

    local deployment_status="FAIL"
    [[ ${failed} -ne 0 ]] || deployment_status="RUNNING"
    [[ "${query_ok}" == "true" ]] || deployment_status="UNKNOWN"
    if [[ "${deployment}" == "${DB_DEPLOYMENT}" ]]; then
        DB_STATUS="${deployment_status}"
        DB_RUNNING=${running}
    else
        DAA_STATUS="${deployment_status}"
        DAA_RUNNING=${running}
    fi
    [[ ${query_rc} -eq 0 ]] || return "${query_rc}"
    [[ ${failed} -eq 0 ]]
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

    # Wait for this instance's process (not proof of REST listener readiness).
    local retry=0
    local max_retry=15
    local sm_pid="" check_rc=1

    while [[ ${retry} -lt ${max_retry} ]]; do
        sleep 2
        if sm_pid=$(find_service_manager_pid); then
            SM_STATUS="RUNNING"
            SM_DETAIL="PID ${sm_pid}; observed during startup"
            break
        else
            check_rc=$?
        fi
        retry=$((retry + 1))
        log "INFO" "Waiting for ServiceManager (${retry}/${max_retry})..."
    done

    if [[ -n "${sm_pid}" ]]; then
        log "INFO" "ServiceManager STARTED successfully (PID: ${sm_pid})."
    else
        SM_STATUS="STOPPED"
        SM_DETAIL="No process found for this instance"
        if [[ ${check_rc} -ne 1 ]]; then
            SM_STATUS="UNKNOWN"
            SM_DETAIL="Could not identify this instance's process"
        fi
        record_failure "ServiceManager did not become detectable within 30 seconds; launcher log: ${sm_start_log}"
        log "ERROR" "${FAILURE_REASON}"
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

    # ServiceManager INFO ALL lists deployment services in this version.
    # Required Extract/Replicat health is verified through each deployment in Step 5.
    log "INFO" "Deployment start commands completed; required process health will be verified in Step 5."

    log "INFO" "Waiting for deployment Microservices Daemons to initialize (10 seconds)..."
    sleep 10
}

# ------------------------------------------------------------------------------
# 6. STEP 4: START EXTRACTS & REPLICATS VIA ADMINCLIENT
# ------------------------------------------------------------------------------
start_ogg_processes() {
    log "INFO" "=================== STEP 4: START EXTRACT & REPLICAT PROCESSES ==================="

    # --- 4.1. Start required Extracts on the DB deployment ---
    log "INFO" ">> Connecting to Deployment ${DB_DEPLOYMENT} (Port 7862)..."
    local cmds_db="" cmds_daa="" group
    for group in "${DB_PROCESSES[@]}"; do
        cmds_db+="start extract ${group}"$'\n'
    done
    cmds_db+=$'sh sleep 5\ninfo extract * detail\n'
    run_adminclient_cmd "${ADMINCLIENT_DB}" "${CONN_DB}" "${cmds_db}"

    # --- 4.2. Start required Replicats on the DAA deployment ---
    log "INFO" ">> Connecting to Deployment ${DAA_DEPLOYMENT} (Port 7872)..."
    for group in "${DAA_PROCESSES[@]}"; do
        cmds_daa+="start replicat ${group}"$'\n'
    done
    cmds_daa+=$'sh sleep 5\ninfo replicat *\n'
    run_adminclient_cmd "${ADMINCLIENT_DAA}" "${CONN_DAA}" "${cmds_daa}"
}

# ------------------------------------------------------------------------------
# 7. STEP 5: VERIFY ACTUAL STATUS & RETURN FINAL VERDICT PASS/FAIL
# ------------------------------------------------------------------------------
verify_overall_health() {
    log "INFO" "=================== STEP 5: VERIFY OVERALL SYSTEM HEALTH ==================="
    local failed=0 result_rc=0 sm_pid check_rc
    HEALTH_VERIFIED=false

    if sm_pid=$(find_service_manager_pid); then
        SM_STATUS="RUNNING"
        SM_DETAIL="PID ${sm_pid}; verified in Step 5"
    else
        check_rc=$?
        SM_STATUS="STOPPED"
        SM_DETAIL="No process found for this instance"
        if [[ ${check_rc} -ne 1 ]]; then
            SM_STATUS="UNKNOWN"
            SM_DETAIL="Could not identify this instance's process"
        fi
        record_failure "ServiceManager: ${SM_STATUS} - ${SM_DETAIL}"
        failed=$((failed + 1))
        result_rc=1
    fi

    log "INFO" "Checking required Extracts on ${DB_DEPLOYMENT}:7862..."
    if verify_deployment_processes "${DB_DEPLOYMENT}" EXTRACT "${ADMINCLIENT_DB}" "${CONN_DB}" "${DB_PROCESSES[@]}"; then
        :
    else
        check_rc=$?
        failed=$((failed + 1))
        [[ ${result_rc} -ne 0 ]] || result_rc=${check_rc}
    fi

    log "INFO" "Checking required Replicats on ${DAA_DEPLOYMENT}:7872..."
    if verify_deployment_processes "${DAA_DEPLOYMENT}" REPLICAT "${ADMINCLIENT_DAA}" "${CONN_DAA}" "${DAA_PROCESSES[@]}"; then
        :
    else
        check_rc=$?
        failed=$((failed + 1))
        [[ ${result_rc} -ne 0 ]] || result_rc=${check_rc}
    fi

    if [[ ${failed} -eq 0 ]]; then
        HEALTH_VERIFIED=true
        return 0
    fi
    return "${result_rc}"
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION FLOW
# ------------------------------------------------------------------------------
main() {
    trap 'finalize "$?"' EXIT
    trap 'record_failure "Interrupted by SIGINT."; exit 130' INT
    trap 'record_failure "Interrupted by SIGTERM."; exit 143' TERM

    CURRENT_STEP="Initialize logging"
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="${LOG_DIR}/ogg_startup_${TIMESTAMP}_$$.log"
    mkdir -p "${LOG_DIR}"
    : >> "${LOG_FILE}"
    LOG_READY=true

    CURRENT_STEP="Acquire startup lock"
    check_single_execution
    log "INFO" "Starting OGG MA Services startup procedure (Log file: ${LOG_FILE})"

    CURRENT_STEP="Step 1: Cleanup and stop existing services"
    cleanup_and_stop_existing
    CURRENT_STEP="Step 2: Start ServiceManager"
    start_service_manager
    CURRENT_STEP="Step 3: Start deployments"
    start_deployments
    CURRENT_STEP="Step 4: Start Extracts and Replicats"
    start_ogg_processes
    CURRENT_STEP="Step 5: Verify required process health"
    verify_overall_health
    CURRENT_STEP="Completed"
}

# Sourcing exposes helpers for isolated tests without starting or stopping services.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi