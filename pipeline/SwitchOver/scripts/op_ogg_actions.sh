#!/usr/bin/env bash
# ==============================================================================
# Script Name : op_ogg_actions.sh
# Purpose     : Targeted start/stop actions for Oracle GoldenGate MA
# Reference   : ogg_operational_actions_script_specification.md
# ==============================================================================

# The specification also documents invocation through "sh".
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set +x
set -euo pipefail
umask 077

# ------------------------------------------------------------------------------
# 1. ENVIRONMENT & PATH CONFIGURATIONS
# ------------------------------------------------------------------------------
export SM_HOME="${SM_HOME:-/data/ogg_oracle/ServiceManager}"
export OGG_HOME="${OGG_HOME:-/u01/OracleGoldenGate/ogg_oracle/oggma}"
export OGG_VAR_HOME="${OGG_VAR_HOME:-${SM_HOME}/var}"
export OGG_ETC_HOME="${OGG_ETC_HOME:-${SM_HOME}/etc}"
export OGG_CONF_HOME="${OGG_CONF_HOME:-${OGG_ETC_HOME}/conf}"
export OGG_CLIENT_TLS_CAPATH="${OGG_CLIENT_TLS_CAPATH:-/u01/OracleGoldenGate/OGG_Certs/RootCA_cert.pem}"

ADMINCLIENT_DB="${ADMINCLIENT_DB:-${OGG_HOME}/bin/adminclient}"
ADMINCLIENT_DAA="${ADMINCLIENT_DAA:-/u01/OracleGoldenGate/ogg_daa/oggma/bin/adminclient}"
DB_DEPLOYMENT="${DB_DEPLOYMENT:-ogg_oracle03}"
DAA_DEPLOYMENT="${DAA_DEPLOYMENT:-ogg_daa03}"
OGG_ENDPOINT="${OGG_ENDPOINT:-https://localhost:7801}"
OGG_INSECURE_TLS="${OGG_INSECURE_TLS:-false}"
OGG_COMMAND_TIMEOUT="${OGG_COMMAND_TIMEOUT:-60}"
OGG_STOP_ATTEMPTS="${OGG_STOP_ATTEMPTS:-15}"
OGG_START_ATTEMPTS="${OGG_START_ATTEMPTS:-15}"
OGG_POLL_INTERVAL="${OGG_POLL_INTERVAL:-2}"
OGG_SM_START_GRACE="${OGG_SM_START_GRACE:-1}"
LOG_DIR="${LOG_DIR:-${OGG_VAR_HOME}/log}"
LOCK_DIR="${OGG_ACTION_LOCK_DIR:-${OGG_VAR_HOME}/run/op_ogg_actions.lock}"

ACTION=""
CREDENTIAL_NAME=""
DEPLOYMENT=""
PROCESS=""
ADMINCLIENT_BIN="${ADMINCLIENT_BIN:-}"
ADMIN_OUTPUT=""
PROCESS_STATUS="UNKNOWN"
declare -a ALL_PROCESS_GROUPS=()
declare -A ALL_PROCESS_STATUS=()
LOG_FILE=""
LOG_READY=false
LOCK_OWNED=false
ACTION_COMPLETED=false
RESULT="NOT COMPLETED"
FAILURE_REASON=""

usage() {
    printf '%s\n' \
        'Usage: bash op_ogg_actions.sh <action> [deployment_name] [credential_name] [process_name]' \
        '' \
        'Actions:' \
        '  start_ext  <deployment_name> <credential_name> <process_name>' \
        '  stop_ext   <deployment_name> <credential_name> <process_name>' \
        '  start_rep  <deployment_name> <credential_name> <process_name>' \
        '  stop_rep   <deployment_name> <credential_name> <process_name>' \
        '  start_depl <deployment_name> <credential_name>' \
        '  stop_depl  <deployment_name> <credential_name>' \
        '  start_sm' \
        '  stop_sm' \
        '' \
        "Wildcards: quote '*' (or use \\*) so the shell does not expand filenames." \
        "Process '*' selects all groups of that type in one explicit deployment." \
        "Deployment '*' is allowed only for start_depl / stop_depl and affects ALL deployments." \
        'Partial patterns (EXT*, ogg_*, ?, brackets) and wildcard credentials are not supported.' \
        '' \
        'Authentication: use an existing AdminClient credential alias, not a password.' \
        'Provision the alias beforehand for the OS account running this script.' \
        'Endpoint: OGG_ENDPOINT. TLS verification is enabled by default.' \
        'Set OGG_INSECURE_TLS=true only for an approved self-signed endpoint.' \
        'AdminClient override: ADMINCLIENT_BIN; otherwise DB/DAA binaries are selected.' \
        'ServiceManager: SM_HOME; OGG_START_SM_SCRIPT / OGG_STOP_SM_SCRIPT override native scripts.' \
        'Timeout/polling: OGG_COMMAND_TIMEOUT, OGG_START_ATTEMPTS, OGG_STOP_ATTEMPTS, OGG_POLL_INTERVAL.' \
        'Native startup: nohup with a separate launcher log; OGG_SM_START_GRACE seconds checks early exit.' \
        'Logs/locking: LOG_DIR, OGG_ACTION_LOCK_DIR (shared by all these actions).' \
        'A stale lock must be checked and removed manually; it is never stolen.' \
        '' \
        'Examples:' \
        '  bash op_ogg_actions.sh start_ext ogg_oracle03 OGGHUB_CORELIVE EXT24P' \
        '  bash op_ogg_actions.sh stop_ext ogg_oracle03 OGGHUB_CORELIVE EXT24P' \
        '  bash op_ogg_actions.sh start_rep ogg_daa03 OGGHUB_CORELIVE RKKPL01' \
        '  bash op_ogg_actions.sh stop_rep ogg_daa03 OGGHUB_CORELIVE RKKPL01' \
        '  bash op_ogg_actions.sh start_depl ogg_oracle03 OGGHUB_CORELIVE' \
        '  bash op_ogg_actions.sh stop_depl ogg_oracle03 OGGHUB_CORELIVE' \
        "  bash op_ogg_actions.sh start_ext ogg_oracle03 OGGHUB_CORELIVE '*'" \
        "  bash op_ogg_actions.sh stop_rep ogg_daa03 OGGHUB_CORELIVE '*'" \
        "  bash op_ogg_actions.sh start_depl '*' OGGHUB_CORELIVE" \
        '  bash op_ogg_actions.sh start_sm' \
        '  bash op_ogg_actions.sh stop_sm' \
        '' \
        'Deployment/ServiceManager actions affect the entire requested deployment/manager.' \
        'They do not separately start or stop individual Extracts or Replicats.' \
        'Process actions verify RUNNING/STOPPED. Deployment/native stop PASS means command completion.' \
        'Native start PASS means launch accepted or script completed; service state is not verified.'
}

log() {
    local level="$1"
    shift
    local line="[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*"
    if [[ "${LOG_READY}" == "true" ]]; then
        printf '%s\n' "${line}" | tee -a "${LOG_FILE}"
    else
        printf '%s\n' "${line}"
    fi
}

fail() {
    FAILURE_REASON="$*"
    log ERROR "${FAILURE_REASON}"
    exit 1
}

# Report cached results only; never run shutdown or status commands in a trap.
finalize() {
    local rc="$1" verdict="FAIL"
    trap - EXIT INT TERM
    set +e
    if [[ "${LOCK_OWNED}" == "true" ]]; then
        if ! rmdir -- "${LOCK_DIR}"; then
            FAILURE_REASON="${FAILURE_REASON:+${FAILURE_REASON}; }Could not release action lock."
            rc=1
        fi
    fi
    if [[ ${rc} -eq 0 && "${ACTION_COMPLETED}" == "true" ]]; then
        verdict="PASS"
    else
        [[ ${rc} -ne 0 ]] || rc=1
        FAILURE_REASON="${FAILURE_REASON:-Action did not complete (exit ${rc}).}"
    fi
    local summary
    printf -v summary '%s\n' \
        '================ FINAL OGG ACTION SUMMARY ================' \
        "Action: ${ACTION}" \
        "Deployment: ${DEPLOYMENT:-N/A}" \
        "Process: ${PROCESS:-N/A}" \
        "Result: ${RESULT}" \
        "VERDICT: ${verdict}" \
        "Exit code: ${rc}" \
        "Log file: ${LOG_FILE:-NOT AVAILABLE}"
    [[ -z "${FAILURE_REASON}" ]] || summary+="Reason: ${FAILURE_REASON}"$'\n'
    if [[ "${LOG_READY}" == "true" ]] && ! printf '%s' "${summary}" >> "${LOG_FILE}"; then
        summary="${summary/VERDICT: PASS/VERDICT: FAIL}"
        summary="${summary/Exit code: 0/Exit code: 1}"
        summary+=$'Reporting error: Could not save final summary.\n'
        rc=1
    fi
    printf '%s' "${summary}"
    exit "${rc}"
}

validate_arguments() {
    case "${1:-}" in
        start_ext|stop_ext|start_rep|stop_rep)
            [[ $# -eq 4 ]] || { usage >&2; exit 2; }
            ;;
        start_depl|stop_depl)
            [[ $# -eq 3 ]] || { usage >&2; exit 2; }
            ;;
        start_sm|stop_sm)
            [[ $# -eq 1 ]] || { usage >&2; exit 2; }
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) usage >&2; exit 2 ;;
    esac
    ACTION="$1"
    DEPLOYMENT="${2:-}"
    CREDENTIAL_NAME="${3:-}"
    PROCESS="${4:-}"
    # Only a literal '*' is supported; reject partial globs and command separators.
    if [[ "${ACTION}" != "stop_sm" && "${ACTION}" != "start_sm" ]]; then
        [[ "${CREDENTIAL_NAME}" =~ ^[[:alnum:]_][[:alnum:]_.\$#-]*$ ]] || fail 'Invalid credential name; use one existing AdminClient alias.'
        if [[ "${ACTION}" != *_depl || "${DEPLOYMENT}" != '*' ]]; then
            [[ "${DEPLOYMENT}" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]] || fail 'Invalid deployment name; process actions require one explicit deployment.'
        fi
    fi
    if [[ "${ACTION}" == *_ext || "${ACTION}" == *_rep ]]; then
        [[ "${PROCESS}" == '*' || "${PROCESS}" =~ ^[[:alnum:]_][[:alnum:]_]*$ ]] || fail "Invalid process name; use one explicit group or a quoted '*'."
    fi
    PROCESS="${PROCESS^^}"
    if [[ "${ACTION}" == *_depl && "${DEPLOYMENT,,}" == "servicemanager" ]]; then
        fail "Use ${ACTION%%_*}_sm to manage the ServiceManager instance."
    fi
}

configure_adminclient() {
    # AdminClient resolves the alias from its existing credential store.
    # Do not read passwords or provision credentials during operational actions.
    [[ "${OGG_ENDPOINT}" =~ ^https?://[[:alnum:]_.-]+(:[0-9]{1,5})?/?$ ]] || fail 'OGG_ENDPOINT must be an HTTP(S) host URL with an optional port.'
    [[ "${OGG_INSECURE_TLS}" == "true" || "${OGG_INSECURE_TLS}" == "false" ]] || fail 'OGG_INSECURE_TLS must be true or false.'

    # An explicit binary supports other deployment names and installations.
    if [[ -z "${ADMINCLIENT_BIN}" ]]; then
        case "${DEPLOYMENT}" in
            "${DAA_DEPLOYMENT}") ADMINCLIENT_BIN="${ADMINCLIENT_DAA}" ;;
            *) ADMINCLIENT_BIN="${ADMINCLIENT_DB}" ;;
        esac
    fi
    [[ -x "${ADMINCLIENT_BIN}" ]] || fail "AdminClient is not executable: ${ADMINCLIENT_BIN}"
}

write_safe_output() {
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Omit echoed CONNECT commands and any password-bearing diagnostics.
        case "${line,,}" in
            *connect\ http*|*password*) continue ;;
        esac
        printf '%s\n' "${line}"
    done <<< "$1" | tee -a "${LOG_FILE}"
}

run_adminclient_cmd() {
    local commands="$1" context="${DEPLOYMENT}" suffix="" rc=0 diagnostics
    [[ "${ACTION}" != *_depl ]] || context="ServiceManager"
    [[ "${OGG_INSECURE_TLS}" != "true" ]] || suffix=" !"
    ADMIN_OUTPUT=$(timeout --foreground "${OGG_COMMAND_TIMEOUT}s" "${ADMINCLIENT_BIN}" <<EOF 2>&1
connect ${OGG_ENDPOINT} deployment ${context} as ${CREDENTIAL_NAME}${suffix}
${commands}
exit
EOF
) || rc=$?
    diagnostics=$(grep -viE '^[[:space:]]*OGG[[:space:]]+\([^)]*\)[[:space:]]+[0-9]+>[[:space:]]*connect[[:space:]]+https?://' <<< "${ADMIN_OUTPUT}" || true)
    write_safe_output "${ADMIN_OUTPUT}"
    [[ ${rc} -eq 0 ]] || fail "AdminClient failed (exit ${rc}; 124 means timeout); see log."
    # AdminClient may return zero even when a command or authentication failed.
    local prefix='^[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2}[T[:space:]][0-9:.+-]+Z?[[:space:]]+)?'
    if grep -qE "${prefix}(ERROR|FATAL)([[:space:]:-]|$)" <<< "${diagnostics}" ||
       grep -qiE "${prefix}((error|fatal)[[:space:]]*[:-]|not connected([[:space:][:punct:]]|$)|connection.*(failed|refused)|authentication.*failed|invalid command|syntax error|unknown command|cannot connect|unable to connect)|^[[:space:]]*OGG[[:space:]]+\(not connected\)[[:space:]]+[0-9]+>" <<< "${diagnostics}"; then
        fail 'AdminClient reported an error despite a zero exit status; see log.'
    fi
    [[ -n "${ADMIN_OUTPUT//[[:space:]]/}" ]] || fail 'AdminClient returned no output; command completion is unknown.'
}

validate_process_row() {
    local program="$1" group="$2" status="$3" remainder="$4"
    [[ "${group}" =~ ^[[:alnum:]_][[:alnum:]_]*$ ]] || fail "Invalid ${program} group name in INFO ALL: ${group}"
    # Accept one recognized Type column, not arbitrary words that could hide
    # a malformed group name containing whitespace.
    [[ "${remainder^^}" =~ ^((CLASSIC|INTEGRATED|NONINTEGRATED|NON-INTEGRATED|NON_INTEGRATED|COORDINATED|PARALLEL)[[:space:]]+)?[0-9]+:[0-9]{2}:[0-9]{2}[[:space:]]+[0-9]+:[0-9]{2}:[0-9]{2}[[:space:]]*$ ]] || fail "Malformed INFO ALL row for ${program} ${group}."
    [[ "${status}" =~ ^(RUNNING|STOPPED|ABENDED|STARTING|STOPPING)$ ]] || fail "Unrecognized status for ${group}: ${status}"
}

query_all_process_statuses() {
    local program="$1" row_program row_status row_group remainder
    ALL_PROCESS_GROUPS=()
    ALL_PROCESS_STATUS=()
    run_adminclient_cmd 'info all'
    while read -r row_program row_status row_group remainder; do
        [[ "${row_program^^}" == "${program}" ]] || continue
        row_group="${row_group^^}"
        row_status="${row_status^^}"
        validate_process_row "${program}" "${row_group}" "${row_status}" "${remainder}"
        [[ -z "${ALL_PROCESS_STATUS[${row_group}]+present}" ]] || fail "Duplicate INFO ALL rows for ${program} ${row_group}."
        ALL_PROCESS_GROUPS+=("${row_group}")
        ALL_PROCESS_STATUS[${row_group}]="${row_status}"
    done <<< "${ADMIN_OUTPUT}"
    [[ ${#ALL_PROCESS_GROUPS[@]} -gt 0 ]] || fail "No ${program} groups found in deployment ${DEPLOYMENT}."
}

query_process_status() {
    local program="$1" row_program row_status row_group remainder count=0
    PROCESS_STATUS="UNKNOWN"
    run_adminclient_cmd 'info all'
    while read -r row_program row_status row_group remainder; do
        [[ "${row_program^^}" == "${program}" && "${row_group^^}" == "${PROCESS}" ]] || continue
        count=$((count + 1))
        PROCESS_STATUS="${row_status^^}"
        validate_process_row "${program}" "${PROCESS}" "${PROCESS_STATUS}" "${remainder}"
    done <<< "${ADMIN_OUTPUT}"
    [[ ${count} -eq 1 ]] || fail "Expected one ${program} ${PROCESS} row in INFO ALL; found ${count}."
}

change_all_process_states() {
    local operation="$1" program="$2" attempt group verified commands=""
    local desired="STOPPED" attempts="${OGG_STOP_ATTEMPTS}"
    if [[ "${operation}" == "start" ]]; then
        desired="RUNNING"
        attempts="${OGG_START_ATTEMPTS}"
    fi
    query_all_process_statuses "${program}"
    local -a groups=("${ALL_PROCESS_GROUPS[@]}")
    local total=${#groups[@]}
    log INFO "Wildcard selected ${total} ${program} groups in ${DEPLOYMENT}: ${groups[*]}"
    for group in "${groups[@]}"; do
        if [[ "${ALL_PROCESS_STATUS[${group}]}" != "${desired}" ]]; then
            commands+="${operation} ${program,,} ${group}"$'\n'
        fi
    done
    if [[ -z "${commands}" ]]; then
        RESULT="All ${total} ${program} groups already ${desired} (verified)"
        return 0
    fi

    # Expand the validated snapshot, not a server-side wildcard that could act
    # on newly created groups or send redundant requests to healthy processes.
    RESULT="Wildcard request in progress for ${total} ${program} groups"
    run_adminclient_cmd "${commands%$'\n'}"
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        query_all_process_statuses "${program}"
        [[ ${#ALL_PROCESS_GROUPS[@]} -eq ${total} ]] || fail "${program} inventory changed during wildcard verification; retry after reviewing the deployment."
        verified=0
        for group in "${groups[@]}"; do
            [[ -n "${ALL_PROCESS_STATUS[${group}]+present}" ]] || fail "${program} ${group} disappeared during wildcard verification; inventory changed."
            if [[ "${ALL_PROCESS_STATUS[${group}]}" == "${desired}" ]]; then
                verified=$((verified + 1))
            else
                log INFO "${program} ${group}: ${ALL_PROCESS_STATUS[${group}]} (waiting for ${desired})."
            fi
        done
        RESULT="${program} wildcard: ${verified}/${total} ${desired} (verified)"
        if [[ ${verified} -eq ${total} ]]; then
            return 0
        fi
        [[ ${attempt} -eq ${attempts} ]] || sleep "${OGG_POLL_INTERVAL}"
    done
    fail "Not all ${program} groups reached ${desired}: ${verified}/${total}; see log for individual statuses."
}

change_process_state() {
    local operation="$1" program="$2" attempt
    if [[ "${PROCESS}" == '*' ]]; then
        change_all_process_states "${operation}" "${program}"
        return 0
    fi
    local desired="STOPPED" attempts="${OGG_STOP_ATTEMPTS}"
    if [[ "${operation}" == "start" ]]; then
        desired="RUNNING"
        attempts="${OGG_START_ATTEMPTS}"
    fi
    query_process_status "${program}"
    if [[ "${PROCESS_STATUS}" == "${desired}" ]]; then
        RESULT="${program} ${PROCESS} already ${desired} (verified)"
        return 0
    fi
    log INFO "Requesting ${operation} for ${program} ${PROCESS} in deployment ${DEPLOYMENT}."
    run_adminclient_cmd "${operation} ${program,,} ${PROCESS}"
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        query_process_status "${program}"
        if [[ "${PROCESS_STATUS}" == "${desired}" ]]; then
            RESULT="${program} ${PROCESS} ${desired} (verified)"
            return 0
        fi
        [[ ${attempt} -eq ${attempts} ]] || sleep "${OGG_POLL_INTERVAL}"
    done
    fail "${program} ${PROCESS} did not reach ${desired}; last status: ${PROCESS_STATUS}."
}

stop_service_manager() {
    local stop_script="${OGG_STOP_SM_SCRIPT:-${SM_HOME}/bin/stopSM.sh}" output rc=0
    [[ -x "${stop_script}" ]] || fail "Native ServiceManager stop script is not executable: ${stop_script}"
    log INFO "Invoking native ServiceManager shutdown: ${stop_script}"
    output=$(timeout --foreground "${OGG_COMMAND_TIMEOUT}s" "${stop_script}" 2>&1) || rc=$?
    write_safe_output "${output}"
    [[ ${rc} -eq 0 ]] || fail "Native ServiceManager stop script failed (exit ${rc})."
    RESULT="Native stop script completed; ServiceManager state not independently verified"
}

start_service_manager() {
    local start_script="${OGG_START_SM_SCRIPT:-${SM_HOME}/bin/startSM.sh}"
    local start_log="${LOG_FILE%.log}_servicemanager_start.log" launcher_pid rc=0
    [[ -x "${start_script}" ]] || fail "Native ServiceManager start script is not executable: ${start_script}"
    command -v nohup >/dev/null 2>&1 || fail 'nohup is required for native ServiceManager startup.'
    : >> "${start_log}"
    log INFO "Launching native ServiceManager startup: ${start_script}"
    log INFO "ServiceManager launcher output: ${start_log}"

    # Match the reference startup script: detach daemon handles, not a timed
    # foreground capture that could terminate a long-running ServiceManager.
    nohup "${start_script}" </dev/null >> "${start_log}" 2>&1 &
    launcher_pid=$!
    sleep "${OGG_SM_START_GRACE}"
    if kill -0 "${launcher_pid}" 2>/dev/null; then
        disown "${launcher_pid}" 2>/dev/null || true
        RESULT="Native start launch requested (PID ${launcher_pid}); ServiceManager state not independently verified"
    else
        wait "${launcher_pid}" || rc=$?
        write_safe_output "$(< "${start_log}")"
        [[ ${rc} -eq 0 ]] || fail "Native ServiceManager start script failed (exit ${rc}); launcher log: ${start_log}"
        RESULT="Native start script completed; ServiceManager state not independently verified"
    fi
}

# ------------------------------------------------------------------------------
# 2. MAIN EXECUTION FLOW
# ------------------------------------------------------------------------------
main() {
    validate_arguments "$@"
    trap 'finalize "$?"' EXIT
    trap 'FAILURE_REASON="Interrupted by SIGINT."; exit 130' INT
    trap 'FAILURE_REASON="Interrupted by SIGTERM."; exit 143' TERM

    [[ "${OGG_COMMAND_TIMEOUT}" =~ ^[1-9][0-9]{0,5}$ ]] || fail 'OGG_COMMAND_TIMEOUT must be a positive integer (seconds).'
    [[ "${OGG_STOP_ATTEMPTS}" =~ ^[1-9][0-9]{0,5}$ ]] || fail 'OGG_STOP_ATTEMPTS must be a positive integer.'
    [[ "${OGG_START_ATTEMPTS}" =~ ^[1-9][0-9]{0,5}$ ]] || fail 'OGG_START_ATTEMPTS must be a positive integer.'
    [[ "${OGG_POLL_INTERVAL}" =~ ^(0|[1-9][0-9]{0,5})$ ]] || fail 'OGG_POLL_INTERVAL must be a non-negative integer (seconds).'
    [[ "${OGG_SM_START_GRACE}" =~ ^(0|[1-9][0-9]{0,5})$ ]] || fail 'OGG_SM_START_GRACE must be a non-negative integer (seconds).'
    command -v timeout >/dev/null 2>&1 || fail 'GNU timeout is required.'

    mkdir -p -- "${LOG_DIR}" "$(dirname -- "${LOCK_DIR}")"
    LOG_FILE="${LOG_DIR}/ogg_${ACTION}_$(date +'%Y%m%d_%H%M%S')_$$.log"
    : >> "${LOG_FILE}"
    LOG_READY=true
    # Atomic acquisition; never remove a lock whose ownership is uncertain.
    if ! mkdir -- "${LOCK_DIR}" 2>/dev/null; then
        fail "Cannot acquire action lock: ${LOCK_DIR}. Check for another invocation or a stale lock."
    fi
    LOCK_OWNED=true
    log INFO "OGG action ${ACTION}; deployment=${DEPLOYMENT:-N/A}; process=${PROCESS:-N/A}."

    local operation="${ACTION%%_*}"
    case "${ACTION}" in
        start_sm) start_service_manager ;;
        stop_sm) stop_service_manager ;;
        *)
            configure_adminclient
            case "${ACTION}" in
                start_ext|stop_ext) change_process_state "${operation}" EXTRACT ;;
                start_rep|stop_rep) change_process_state "${operation}" REPLICAT ;;
                start_depl|stop_depl)
                    log INFO "Requesting ${operation} for deployment ${DEPLOYMENT} through ServiceManager."
                    run_adminclient_cmd "${operation} deployment ${DEPLOYMENT}"
                    RESULT="Deployment ${operation} command completed; deployment state not independently verified"
                    ;;
            esac
            ;;
    esac
    ACTION_COMPLETED=true
}

# Sourcing exposes helpers without running operational actions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
