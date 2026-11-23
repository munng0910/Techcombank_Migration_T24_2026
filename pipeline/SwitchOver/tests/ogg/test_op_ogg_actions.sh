#!/usr/bin/env bash
# Offline contract tests. All operational executables and state live under mktemp.
# Run: bash /absolute/path/to/tests/ogg/test_op_ogg_actions.sh
set -euo pipefail
shopt -s nullglob

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$(cd -- "${TEST_DIR}/../.." && pwd)/scripts/op_ogg_actions.sh
BASH_BIN=$(command -v bash)
SH_BIN=$(command -v sh)
command -v timeout >/dev/null || { printf 'GNU timeout is required.\n' >&2; exit 1; }
[[ -f "${SCRIPT}" ]] || { printf 'Missing implementation: %s\n' "${SCRIPT}" >&2; exit 1; }
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ogg-actions-tests.XXXXXX")
trap 'rm -rf -- "${TMP_ROOT}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PASSED=0
FAILED=0
CASE_NUMBER=0
CREDENTIAL_ALIAS=OGGHUB_CORELIVE

fail_test() {
    printf '    %s\n' "$*" >&2
    if [[ -f "${CASE_DIR}/output" ]]; then
        printf '    Captured action output:\n' >&2
        cat -- "${CASE_DIR}/output" >&2
    fi
    exit 1
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail_test "Expected '$2' in $1"
}

assert_absent() {
    if grep -Fq -- "$2" "$1"; then
        fail_test "Unexpected '$2' in $1"
    fi
}

assert_rc() {
    [[ "${ACTUAL_RC}" -eq "$1" ]] || fail_test "Expected exit $1, got ${ACTUAL_RC}"
}

assert_calls() {
    local files=("${CASE_DIR}/admin/"*.input)
    [[ ${#files[@]} -eq "$1" ]] || fail_test "Expected $1 AdminClient calls, got ${#files[@]}"
}

assert_alias_connect() {
    local context="$1" alias="${2:-${CREDENTIAL_ALIAS}}" suffix="${3:-}" file first_line
    for file in "${CASE_DIR}/admin/"*.input; do
        IFS= read -r first_line < "${file}"
        [[ "${first_line}" == "connect https://offline.invalid:7801 deployment ${context} as ${alias}${suffix}" ]] ||
            fail_test "Unexpected CONNECT syntax in ${file}"
        if grep -qi -- 'password' "${file}"; then
            fail_test "CONNECT includes a password token in ${file}"
        fi
    done
}

assert_no_native() {
    [[ ! -e "${CASE_DIR}/native.calls" ]] || fail_test 'Unexpected native stop invocation'
}

assert_lock_released() {
    [[ ! -e "${CASE_DIR}/run/action.lock" ]] || fail_test 'Action lock was not released'
}

assert_no_side_effects() {
    assert_calls 0
    assert_no_native
    [[ ! -e "${CASE_DIR}/log output" && ! -e "${CASE_DIR}/run" ]] ||
        fail_test 'Validation/help created log or lock directories'
    [[ ! -e "${CASE_DIR}/injected" ]] || fail_test 'An injected command ran'
}

assert_pass() {
    assert_rc 0
    assert_contains "${CASE_DIR}/output" 'VERDICT: PASS'
    assert_contains "${CASE_DIR}/output" 'Exit code: 0'
    assert_lock_released
    local line log_file=''
    while IFS= read -r line; do
        case "${line}" in 'Log file: '*) log_file="${line#Log file: }" ;; esac
    done < "${CASE_DIR}/output"
    [[ -f "${log_file}" ]] || fail_test 'Missing action log'
    assert_contains "${log_file}" 'VERDICT: PASS'
}

assert_failure() {
    [[ "${ACTUAL_RC}" -ne 0 ]] || fail_test 'Action unexpectedly succeeded'
    assert_contains "${CASE_DIR}/output" 'VERDICT: FAIL'
    assert_absent "${CASE_DIR}/output" 'VERDICT: PASS'
    assert_lock_released
}

setup_case() {
    mkdir -p -- "${CASE_DIR}/admin" "${CASE_DIR}/sm/bin" "${CASE_DIR}/ogg/bin" \
        "${CASE_DIR}/daa/bin" "${CASE_DIR}/override/bin"
    # Each fake records complete stdin, including CONNECT, in this private sandbox.
    # Never print these fixture captures as part of a passing test run.
    cat > "${CASE_DIR}/fake-adminclient" <<'FAKE_ADMIN'
#!/usr/bin/env bash
set -euo pipefail
n=0
[[ ! -f "${FAKE_STATE}/admin/count" ]] || read -r n < "${FAKE_STATE}/admin/count"
n=$((n + 1))
printf '%s\n' "${n}" > "${FAKE_STATE}/admin/count"
printf -v stem '%s/admin/%03d' "${FAKE_STATE}" "${n}"
printf '%s\n' "$0" > "${stem}.binary"
lines=()
while IFS= read -r line; do
    lines+=("${line}")
    printf '%s\n' "${line}" >> "${stem}.input"
done
if [[ "${FAKE_ECHO_CONNECT:-false}" == true ]]; then
    printf 'OGG (not connected) 1> %s\n' "${lines[0]}"
    printf 'PASSWORD diagnostic must be hidden\n'
    printf 'ordinary diagnostic retained\n'
fi
case "${FAKE_MODE}" in
    error_zero) printf 'ERROR: simulated command rejection\n'; exit 0 ;;
    error_timestamp) printf '2026-01-02 03:04:05 ERROR simulated failure\n'; exit 0 ;;
    not_connected) printf 'OGG (not connected) 2> info all\n'; exit 0 ;;
    nonzero) printf 'simulated transport failure\n'; exit 17 ;;
    empty) exit 0 ;;
    timeout) exec sleep 5 ;;
esac
case "${lines[1]:-}" in
    'info all')
        status=RUNNING
        if [[ "${FAKE_MODE}" == already_stopped ]]; then
            status=STOPPED
        elif [[ "${FAKE_MODE}" == start_* ]]; then
            status=STOPPED
            if [[ "${FAKE_MODE}" == start_already_running ]]; then
                status=RUNNING
            elif [[ -f "${FAKE_STATE}/start.requested" ]]; then
                status=RUNNING
                if [[ "${FAKE_MODE}" == start_never_running ]] ||
                    [[ "${FAKE_MODE}" == start_delayed && ! -e "${FAKE_STATE}/seen.starting" ]]; then
                    status=STARTING
                    : > "${FAKE_STATE}/seen.starting"
                fi
            fi
        elif [[ -f "${FAKE_STATE}/stop.requested" && "${FAKE_MODE}" != never_stops ]]; then
            status=STOPPED
            if [[ "${FAKE_MODE}" == delayed && ! -e "${FAKE_STATE}/seen.stopping" ]]; then
                status=STOPPING
                : > "${FAKE_STATE}/seen.stopping"
            fi
        fi
        printf 'Program Status Group Lag at Chkpt Time Since Chkpt\n'
        printf 'EXTRACT RUNNING UNRELATED_EXT 00:00:00 00:00:00\n'
        printf 'REPLICAT RUNNING UNRELATED_REP 00:00:00 00:00:00\n'
        case "${FAKE_MODE}" in
            missing) exit 0 ;;
            duplicate) printf '%s %s %s 00:00:00 00:00:00\n' "${FAKE_PROGRAM}" "${status}" "${FAKE_GROUP}" ;;
            unknown_status) status=BOGUS ;;
            malformed)
                printf '%s STOPPED %s\n' "${FAKE_PROGRAM}" "${FAKE_GROUP}"
                exit 0
                ;;
            malformed_time)
                printf '%s STOPPED %s 00:00:00 not-a-time\n' "${FAKE_PROGRAM}" "${FAKE_GROUP}"
                exit 0
                ;;
            typed)
                printf '%s %s %s INTEGRATED 00:00:00 00:00:00\n' "${FAKE_PROGRAM}" "${status}" "${FAKE_GROUP}"
                exit 0
                ;;
        esac
        printf '%s %s %s 00:00:00 00:00:00\n' "${FAKE_PROGRAM}" "${status}" "${FAKE_GROUP}"
        ;;
    'stop extract '*|'stop replicat '*)
        : > "${FAKE_STATE}/stop.requested"
        printf 'Stop request accepted\n'
        ;;
    'start extract '*|'start replicat '*)
        : > "${FAKE_STATE}/start.requested"
        printf 'Start request accepted\n'
        ;;
    'stop deployment '*) printf 'Deployment stop request accepted\n' ;;
    'start deployment '*) printf 'Deployment start request accepted\n' ;;
    *) printf 'ERROR unexpected fixture command\n'; exit 9 ;;
esac
FAKE_ADMIN
    cat > "${CASE_DIR}/fake-stop" <<'FAKE_STOP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s argc=%s\n' "$0" "$#" >> "${FAKE_STATE}/native.calls"
printf 'SM_HOME=%s\nOGG_HOME=%s\nOGG_VAR_HOME=%s\nOGG_ETC_HOME=%s\nOGG_CONF_HOME=%s\n' \
    "${SM_HOME:?}" "${OGG_HOME:?}" "${OGG_VAR_HOME:?}" "${OGG_ETC_HOME:?}" "${OGG_CONF_HOME:?}" \
    > "${FAKE_STATE}/native.env"
case "${FAKE_MODE}" in
    native_fail) printf 'simulated native failure\n'; exit 19 ;;
    native_timeout) exec sleep 5 ;;
esac
printf 'Native stop fixture completed\n'
FAKE_STOP
    cat > "${CASE_DIR}/fake-start" <<'FAKE_START'
#!/usr/bin/env bash
set -euo pipefail
printf '%s argc=%s\n' "$0" "$#" >> "${FAKE_STATE}/native.calls"
printf 'SM_HOME=%s\nOGG_HOME=%s\nOGG_VAR_HOME=%s\nOGG_ETC_HOME=%s\nOGG_CONF_HOME=%s\n' \
    "${SM_HOME:?}" "${OGG_HOME:?}" "${OGG_VAR_HOME:?}" "${OGG_ETC_HOME:?}" "${OGG_CONF_HOME:?}" \
    > "${FAKE_STATE}/native.env"
if IFS= read -r line; then
    printf 'Unexpected launcher stdin: %s\n' "${line}"
    exit 23
fi
printf 'Native start fixture stdin is empty\n'
if [[ "${FAKE_MODE}" == native_fail ]]; then
    printf 'simulated native start failure\n'
    exit 19
fi
if [[ "${FAKE_MODE}" == native_running ]]; then
    # A finite fake launcher, never a real daemon. Outlive the default grace.
    sleep 2
fi
printf 'Native start fixture completed\n'
FAKE_START
    printf 'must not reach native launcher\n' > "${CASE_DIR}/launcher-input"
    cp -- "${CASE_DIR}/fake-adminclient" "${CASE_DIR}/ogg/bin/adminclient"
    cp -- "${CASE_DIR}/fake-adminclient" "${CASE_DIR}/daa/bin/adminclient"
    cp -- "${CASE_DIR}/fake-adminclient" "${CASE_DIR}/override/bin/adminclient"
    cp -- "${CASE_DIR}/fake-stop" "${CASE_DIR}/sm/bin/stopSM.sh"
    cp -- "${CASE_DIR}/fake-stop" "${CASE_DIR}/explicit-stop.sh"
    cp -- "${CASE_DIR}/fake-start" "${CASE_DIR}/sm/bin/startSM.sh"
    cp -- "${CASE_DIR}/fake-start" "${CASE_DIR}/explicit-start.sh"
    chmod +x "${CASE_DIR}/ogg/bin/adminclient" "${CASE_DIR}/daa/bin/adminclient" \
        "${CASE_DIR}/override/bin/adminclient" "${CASE_DIR}/sm/bin/"*.sh \
        "${CASE_DIR}/explicit-stop.sh" "${CASE_DIR}/explicit-start.sh"
    EXTRA_ENV=()
    FAKE_MODE=normal
    FAKE_PROGRAM=EXTRACT
    FAKE_GROUP=EXT24P
    SHELL_BIN="${BASH_BIN}"
}

run_action() {
    # env -i excludes production credentials, shell startup files, and ambient OGG
    # settings. Every binary/native path is either a sandbox fake or nonexistent.
    if env -i PATH="${PATH}" HOME="${CASE_DIR}" TMPDIR="${TMP_ROOT}" \
        SYSTEMROOT="${SYSTEMROOT:-${SystemRoot:-}}" \
        SM_HOME="${CASE_DIR}/sm" OGG_HOME="${CASE_DIR}/ogg" \
        ADMINCLIENT_DB="${CASE_DIR}/ogg/bin/adminclient" \
        ADMINCLIENT_DAA="${CASE_DIR}/daa/bin/adminclient" \
        OGG_ENDPOINT='https://offline.invalid:7801' OGG_INSECURE_TLS=false \
        OGG_COMMAND_TIMEOUT=3 OGG_STOP_ATTEMPTS=2 OGG_START_ATTEMPTS=2 OGG_POLL_INTERVAL=0 \
        LOG_DIR="${CASE_DIR}/log output" OGG_ACTION_LOCK_DIR="${CASE_DIR}/run/action.lock" \
        FAKE_STATE="${CASE_DIR}" FAKE_MODE="${FAKE_MODE}" \
        FAKE_PROGRAM="${FAKE_PROGRAM}" FAKE_GROUP="${FAKE_GROUP}" \
        "${EXTRA_ENV[@]}" "${SHELL_BIN}" "${SCRIPT}" "$@" \
        < "${CASE_DIR}/launcher-input" > "${CASE_DIR}/output" 2>&1; then
        ACTUAL_RC=0
    else
        ACTUAL_RC=$?
    fi
}

case_arities() {
    run_action; assert_rc 2; assert_no_side_effects
    run_action unknown; assert_rc 2; assert_no_side_effects
    local action
    for action in stop_ext stop_rep start_ext start_rep; do
        run_action "${action}"; assert_rc 2; assert_no_side_effects
        run_action "${action}" ogg_oracle03; assert_rc 2; assert_no_side_effects
        run_action "${action}" ogg_oracle03 "${CREDENTIAL_ALIAS}"; assert_rc 2; assert_no_side_effects
        run_action "${action}" ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P extra
        assert_rc 2; assert_no_side_effects
        # Reject the former CLI lacking a credential alias.
        run_action "${action}" ogg_oracle03 EXT24P; assert_rc 2; assert_no_side_effects
    done
    for action in stop_depl start_depl; do
        run_action "${action}"; assert_rc 2; assert_no_side_effects
        run_action "${action}" ogg_oracle03; assert_rc 2; assert_no_side_effects
        run_action "${action}" ogg_oracle03 "${CREDENTIAL_ALIAS}" extra
        assert_rc 2; assert_no_side_effects
    done
    for action in stop_sm start_sm; do
        run_action "${action}" extra; assert_rc 2; assert_no_side_effects
        run_action "${action}" ogg_oracle03 "${CREDENTIAL_ALIAS}"
        assert_rc 2; assert_no_side_effects
    done
}

case_empty_names() {
    local action
    for action in stop_ext stop_rep start_ext start_rep; do
        run_action "${action}" '' "${CREDENTIAL_ALIAS}" EXT24P
        [[ ${ACTUAL_RC} -ne 0 ]] || fail_test 'Accepted empty deployment'
        assert_no_side_effects
        run_action "${action}" ogg_oracle03 "${CREDENTIAL_ALIAS}" ''
        [[ ${ACTUAL_RC} -ne 0 ]] || fail_test 'Accepted empty process'
        assert_no_side_effects
    done
    for action in stop_depl start_depl; do
        run_action "${action}" '' "${CREDENTIAL_ALIAS}"
        [[ ${ACTUAL_RC} -ne 0 ]] || fail_test 'Accepted empty deployment target'
        assert_no_side_effects
    done
}

case_injection() {
    local action value
    for action in stop_ext stop_rep start_ext start_rep stop_depl start_depl; do
        for value in '*' 'ogg*' '?' 'ogg[1]' 'ogg name' 'ogg; exit' $'ogg\nexit' '../ogg' '-ogg' \
            "ogg; touch ${CASE_DIR}/injected" "\$(touch ${CASE_DIR}/injected)"; do
            # A literal '*' is allowed only for deployment-wide actions, not
            # for the deployment context of a process action.
            [[ "${action}" != *_depl || "${value}" != '*' ]] || continue
            if [[ "${action}" == *_depl ]]; then
                run_action "${action}" "${value}" "${CREDENTIAL_ALIAS}"
            else
                run_action "${action}" "${value}" "${CREDENTIAL_ALIAS}" EXT24P
            fi
            [[ ${ACTUAL_RC} -ne 0 ]] || fail_test "Accepted deployment: ${value}"
            assert_no_side_effects
        done
    done
    for action in stop_ext stop_rep start_ext start_rep; do
        for value in 'EXT*' '?' 'EXT[12]' 'EXT REP' 'EXT; exit' $'EXT\nexit' 'EXT-1' 'EXT.1' \
            "EXT; touch ${CASE_DIR}/injected" "\$(touch ${CASE_DIR}/injected)"; do
            run_action "${action}" ogg_oracle03 "${CREDENTIAL_ALIAS}" "${value}"
            [[ ${ACTUAL_RC} -ne 0 ]] || fail_test "Accepted process: ${value}"
            assert_no_side_effects
        done
    done
    for action in stop_depl start_depl; do
        run_action "${action}" sErViCeMaNaGeR "${CREDENTIAL_ALIAS}"
        [[ ${ACTUAL_RC} -ne 0 ]] || fail_test 'Accepted ServiceManager as deployment'
        assert_no_side_effects
    done
}

case_help() {
    local option
    for option in -h --help; do
        run_action "${option}"; assert_rc 0
        assert_contains "${CASE_DIR}/output" 'Usage:'
        local action
        for action in stop_ext stop_rep stop_depl stop_sm start_ext start_rep start_depl start_sm; do
            assert_contains "${CASE_DIR}/output" "${action}"
        done
        assert_contains "${CASE_DIR}/output" '<deployment_name> <credential_name>'
        assert_contains "${CASE_DIR}/output" 'existing AdminClient credential alias'
        assert_contains "${CASE_DIR}/output" 'OS account'
        assert_absent "${CASE_DIR}/output" 'OGG_PASSWORD'
        assert_absent "${CASE_DIR}/output" 'FINAL OGG ACTION SUMMARY'
        assert_no_side_effects
    done
}

case_extract_db() {
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" ext24p
    assert_pass; assert_calls 3; assert_no_native
    assert_contains "${CASE_DIR}/admin/001.binary" "${CASE_DIR}/ogg/bin/adminclient"
    assert_alias_connect ogg_oracle03
    assert_contains "${CASE_DIR}/admin/001.input" 'info all'
    assert_contains "${CASE_DIR}/admin/002.input" 'stop extract EXT24P'
    assert_contains "${CASE_DIR}/admin/003.input" 'info all'
    assert_contains "${CASE_DIR}/output" 'EXTRACT EXT24P STOPPED (verified)'
    assert_absent "${CASE_DIR}/admin/001.input" ' !'
}

case_replicat_daa() {
    FAKE_PROGRAM=REPLICAT; FAKE_GROUP=RKKPL01
    run_action stop_rep ogg_daa03 "${CREDENTIAL_ALIAS}" rkkpl01
    assert_pass; assert_calls 3; assert_no_native
    assert_contains "${CASE_DIR}/admin/001.binary" "${CASE_DIR}/daa/bin/adminclient"
    assert_alias_connect ogg_daa03
    assert_contains "${CASE_DIR}/admin/002.input" 'stop replicat RKKPL01'
    assert_contains "${CASE_DIR}/output" 'REPLICAT RKKPL01 STOPPED (verified)'
}

case_start_process() {
    local action="$1" mode="$2" kind binary file
    if [[ "${action}" == start_ext ]]; then
        kind=extract; binary=ogg
        FAKE_PROGRAM=EXTRACT; FAKE_GROUP=EXT24P
    else
        kind=replicat; binary=daa
        FAKE_PROGRAM=REPLICAT; FAKE_GROUP=RKKPL01
    fi
    FAKE_MODE="${mode}"
    local deployment=ogg_oracle03
    [[ "${action}" != start_rep ]] || deployment=ogg_daa03
    run_action "${action}" "${deployment}" "${CREDENTIAL_ALIAS}" "${FAKE_GROUP,,}"
    assert_no_native
    assert_contains "${CASE_DIR}/admin/001.binary" "${CASE_DIR}/${binary}/bin/adminclient"
    assert_alias_connect "${deployment}"
    assert_contains "${CASE_DIR}/admin/001.input" 'info all'
    case "${mode}" in
        start_already_running)
            assert_pass; assert_calls 1
            assert_contains "${CASE_DIR}/output" 'already RUNNING (verified)'
            [[ ! -e "${CASE_DIR}/start.requested" ]] || fail_test 'Started an already RUNNING process'
            ;;
        start_never_running)
            assert_failure; assert_calls 4
            assert_contains "${CASE_DIR}/output" 'did not reach RUNNING; last status: STARTING'
            ;;
        start_delayed)
            assert_pass; assert_calls 4
            assert_contains "${CASE_DIR}/output" "${FAKE_PROGRAM} STARTING ${FAKE_GROUP}"
            assert_contains "${CASE_DIR}/output" "${FAKE_PROGRAM} ${FAKE_GROUP} RUNNING (verified)"
            ;;
        start_normal)
            assert_pass; assert_calls 3
            assert_contains "${CASE_DIR}/output" "${FAKE_PROGRAM} ${FAKE_GROUP} RUNNING (verified)"
            ;;
        *) fail_test 'Unknown start fixture mode' ;;
    esac
    if [[ "${mode}" != start_already_running ]]; then
        assert_contains "${CASE_DIR}/admin/002.input" "start ${kind} ${FAKE_GROUP}"
        assert_contains "${CASE_DIR}/admin/003.input" 'info all'
    fi
    for file in "${CASE_DIR}/admin/"*.input; do
        assert_absent "${file}" 'stop '
        assert_absent "${file}" 'deployment start'
    done
}

case_poll_attempts_independent() {
    if [[ "$1" == start ]]; then
        FAKE_MODE=start_never_running
        EXTRA_ENV=('OGG_START_ATTEMPTS=3' 'OGG_STOP_ATTEMPTS=1')
        run_action start_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
        assert_contains "${CASE_DIR}/output" 'did not reach RUNNING'
    else
        FAKE_MODE=never_stops
        EXTRA_ENV=('OGG_START_ATTEMPTS=1' 'OGG_STOP_ATTEMPTS=3')
        run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
        assert_contains "${CASE_DIR}/output" 'did not reach STOPPED'
    fi
    assert_failure; assert_calls 5; assert_no_native
}

case_unknown_deployment_db() {
    run_action stop_ext other-deployment.01 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass
    assert_contains "${CASE_DIR}/admin/001.binary" "${CASE_DIR}/ogg/bin/adminclient"
    assert_contains "${CASE_DIR}/admin/001.input" 'deployment other-deployment.01'
}

case_explicit_binary() {
    EXTRA_ENV=("ADMINCLIENT_BIN=${CASE_DIR}/override/bin/adminclient" "ADMINCLIENT_DB=${CASE_DIR}/missing-db" "ADMINCLIENT_DAA=${CASE_DIR}/missing-daa")
    run_action stop_ext custom01 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass; assert_calls 3
    assert_contains "${CASE_DIR}/admin/001.binary" "${CASE_DIR}/override/bin/adminclient"
}

case_sh_invocation() {
    SHELL_BIN="${SH_BIN}"
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass; assert_calls 3
    assert_contains "${CASE_DIR}/admin/002.input" 'stop extract EXT24P'
}

case_idempotent() {
    FAKE_MODE=already_stopped
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass; assert_calls 1
    assert_contains "${CASE_DIR}/output" 'already STOPPED (verified)'
    [[ ! -e "${CASE_DIR}/stop.requested" ]] || fail_test 'Stopped an already stopped process'
}

case_delayed_stop() {
    FAKE_MODE=delayed
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass; assert_calls 4
    assert_contains "${CASE_DIR}/output" 'EXTRACT STOPPING EXT24P'
    assert_contains "${CASE_DIR}/output" 'STOPPED (verified)'
}

case_typed_status() {
    FAKE_MODE=typed
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass; assert_calls 3
    assert_contains "${CASE_DIR}/output" 'EXTRACT STOPPED EXT24P INTEGRATED 00:00:00 00:00:00'
}

case_status_failure() {
    FAKE_MODE="$1"
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_failure; assert_calls 1
    [[ ! -e "${CASE_DIR}/stop.requested" ]] || fail_test 'Stopped a group with ambiguous/missing status'
    assert_contains "${CASE_DIR}/output" "$2"
}

case_never_stops() {
    FAKE_MODE=never_stops
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_failure; assert_calls 4
    assert_contains "${CASE_DIR}/output" 'did not reach STOPPED; last status: RUNNING'
}

case_admin_failure() {
    FAKE_MODE="$1"
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_failure; assert_calls 1; assert_no_native
    assert_contains "${CASE_DIR}/output" "$2"
}

case_alias_rejection() {
    local action value
    for action in stop_ext stop_rep start_ext start_rep stop_depl start_depl; do
        for value in '' '*' 'alias*' '?' 'alias[12]' 'bad alias' 'alias; exit' $'alias\nexit' '../alias' '-alias' \
            'alias"quoted' 'alias\backslash' "alias; touch ${CASE_DIR}/injected" \
            "\$(touch ${CASE_DIR}/injected)"; do
            if [[ "${action}" == *_depl ]]; then
                run_action "${action}" ogg_oracle03 "${value}"
            else
                run_action "${action}" ogg_oracle03 "${value}" EXT24P
            fi
            [[ ${ACTUAL_RC} -ne 0 ]] || fail_test "Accepted invalid alias: ${value}"
            assert_no_side_effects
        done
    done
}

case_alias_case_preserved() {
    local alias='oGgHuB_Core.Live$#-01'
    run_action stop_ext ogg_oracle03 "${alias}" EXT24P
    assert_pass; assert_calls 3
    assert_alias_connect ogg_oracle03 "${alias}"
}

case_legacy_auth_ignored() {
    local file="${CASE_DIR}/unused-password" log
    if [[ "$1" == missing_file ]]; then
        file="${CASE_DIR}/does-not-exist"
    else
        # If read as a password this value would fail the former restrictions.
        printf 'unused_file_marker"\\\\\nsecond-line\n' > "${file}"
    fi
    EXTRA_ENV=('OGG_USER=ignored user; invalid' 'OGG_PASSWORD=unused_env_marker"\' \
        "OGG_PASSWORD_FILE=${file}")
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass; assert_calls 3
    assert_alias_connect ogg_oracle03
    for log in "${CASE_DIR}/admin/"*.input "${CASE_DIR}/output" "${CASE_DIR}/log output/"*.log; do
        assert_absent "${log}" 'unused_file_marker'
        assert_absent "${log}" 'unused_env_marker'
        assert_absent "${log}" 'ignored user'
    done
}

case_connect_output_filtering() {
    local log
    EXTRA_ENV=('FAKE_ECHO_CONNECT=true' 'OGG_INSECURE_TLS=true')
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass; assert_calls 3
    assert_alias_connect ogg_oracle03 "${CREDENTIAL_ALIAS}" ' !'
    for log in "${CASE_DIR}/output" "${CASE_DIR}/log output/"*.log; do
        assert_absent "${log}" 'PASSWORD diagnostic'
        assert_absent "${log}" 'connect https://'
        assert_contains "${log}" 'ordinary diagnostic retained'
    done
}

case_deployment() {
    local action="${1:-stop_depl}" deployment="${2:-ogg_daa03}" binary=daa
    [[ "${deployment}" == ogg_daa03 ]] || binary=ogg
    run_action "${action}" "${deployment}" "${CREDENTIAL_ALIAS}"
    assert_pass; assert_calls 1; assert_no_native
    assert_contains "${CASE_DIR}/admin/001.binary" "${CASE_DIR}/${binary}/bin/adminclient"
    assert_alias_connect ServiceManager
    assert_contains "${CASE_DIR}/admin/001.input" "${action%_depl} deployment ${deployment}"
    assert_absent "${CASE_DIR}/admin/001.input" 'info all'
    assert_absent "${CASE_DIR}/admin/001.input" 'stop extract'
    assert_absent "${CASE_DIR}/admin/001.input" 'stop replicat'
    assert_absent "${CASE_DIR}/admin/001.input" 'start extract'
    assert_absent "${CASE_DIR}/admin/001.input" 'start replicat'
    assert_contains "${CASE_DIR}/output" 'deployment state not independently verified'
}

case_native() {
    local selection="$1" expected
    EXTRA_ENV=("ADMINCLIENT_BIN=${CASE_DIR}/must-not-run")
    case "${selection}" in
        preferred) expected="${CASE_DIR}/sm/bin/stopSM.sh" ;;
        override)
            expected="${CASE_DIR}/explicit-stop.sh"
            EXTRA_ENV+=("OGG_STOP_SM_SCRIPT=${expected}")
            ;;
    esac
    run_action stop_sm
    assert_pass; assert_calls 0
    assert_contains "${CASE_DIR}/native.calls" "${expected} argc=0"
    local calls
    calls=$(wc -l < "${CASE_DIR}/native.calls")
    [[ ${calls} -eq 1 ]] || fail_test 'Native script ran more than once'
    assert_contains "${CASE_DIR}/native.env" "SM_HOME=${CASE_DIR}/sm"
    assert_contains "${CASE_DIR}/native.env" "OGG_HOME=${CASE_DIR}/ogg"
    assert_contains "${CASE_DIR}/native.env" "OGG_VAR_HOME=${CASE_DIR}/sm/var"
    assert_contains "${CASE_DIR}/native.env" "OGG_ETC_HOME=${CASE_DIR}/sm/etc"
    assert_contains "${CASE_DIR}/native.env" "OGG_CONF_HOME=${CASE_DIR}/sm/etc/conf"
    assert_contains "${CASE_DIR}/output" 'ServiceManager state not independently verified'
}

case_native_failure() {
    FAKE_MODE=native_fail
    run_action stop_sm
    assert_failure; assert_calls 0
    assert_contains "${CASE_DIR}/output" 'Native ServiceManager stop script failed (exit 19)'
}

case_native_default_missing() {
    local operation="$1" script="${CASE_DIR}/sm/bin/${1}SM.sh"
    rm -- "${script}"
    run_action "${operation}_sm"
    assert_failure; assert_calls 0; assert_no_native
    assert_contains "${CASE_DIR}/output" "not executable: ${script}"
    local files=("${CASE_DIR}/log output/"*_servicemanager_start.log)
    [[ ${#files[@]} -eq 0 ]] || fail_test 'Missing native script created a launcher log'
}

case_native_missing() {
    # An invalid explicit override must fail, not use the default native script.
    EXTRA_ENV=("OGG_STOP_SM_SCRIPT=${CASE_DIR}/absent-stop.sh")
    run_action stop_sm
    assert_failure; assert_calls 0; assert_no_native
    assert_contains "${CASE_DIR}/output" 'not executable'
}

assert_launcher_log() {
    local files=("${CASE_DIR}/log output/"*_servicemanager_start.log)
    [[ ${#files[@]} -eq 1 ]] || fail_test 'Expected one per-invocation native launcher log'
    LAUNCHER_LOG="${files[0]}"
    assert_contains "${CASE_DIR}/output" "ServiceManager launcher output: ${LAUNCHER_LOG}"
    assert_contains "${LAUNCHER_LOG}" 'Native start fixture stdin is empty'
    assert_absent "${LAUNCHER_LOG}" 'must not reach native launcher'
}

case_native_start() {
    local selection="$1" expected calls
    EXTRA_ENV=("ADMINCLIENT_BIN=${CASE_DIR}/must-not-run")
    case "${selection}" in
        preferred) expected="${CASE_DIR}/sm/bin/startSM.sh" ;;
        override)
            expected="${CASE_DIR}/explicit-start.sh"
            EXTRA_ENV+=("OGG_START_SM_SCRIPT=${expected}")
            ;;
    esac
    run_action start_sm
    assert_pass; assert_calls 0
    assert_contains "${CASE_DIR}/native.calls" "${expected} argc=0"
    calls=$(wc -l < "${CASE_DIR}/native.calls")
    [[ ${calls} -eq 1 ]] || fail_test 'Native start script ran more than once'
    assert_contains "${CASE_DIR}/native.env" "SM_HOME=${CASE_DIR}/sm"
    assert_contains "${CASE_DIR}/native.env" "OGG_HOME=${CASE_DIR}/ogg"
    assert_contains "${CASE_DIR}/native.env" "OGG_VAR_HOME=${CASE_DIR}/sm/var"
    assert_contains "${CASE_DIR}/native.env" "OGG_ETC_HOME=${CASE_DIR}/sm/etc"
    assert_contains "${CASE_DIR}/native.env" "OGG_CONF_HOME=${CASE_DIR}/sm/etc/conf"
    assert_launcher_log
    assert_contains "${LAUNCHER_LOG}" 'Native start fixture completed'
    assert_contains "${CASE_DIR}/output" 'Native start script completed; ServiceManager state not independently verified'
    assert_absent "${CASE_DIR}/output" 'RUNNING (verified)'
}

case_native_start_failure() {
    FAKE_MODE=native_fail
    run_action start_sm
    assert_failure; assert_calls 0
    assert_launcher_log
    assert_contains "${LAUNCHER_LOG}" 'simulated native start failure'
    assert_contains "${CASE_DIR}/output" 'Native ServiceManager start script failed (exit 19)'
}

case_native_start_missing() {
    EXTRA_ENV=("OGG_START_SM_SCRIPT=${CASE_DIR}/absent-start.sh")
    run_action start_sm
    assert_failure; assert_calls 0; assert_no_native
    assert_contains "${CASE_DIR}/output" 'not executable'
    local files=("${CASE_DIR}/log output/"*_servicemanager_start.log)
    [[ ${#files[@]} -eq 0 ]] || fail_test 'Invalid explicit start override fell back to a launcher'
}

case_native_start_running() {
    FAKE_MODE=native_running
    EXTRA_ENV=('OGG_COMMAND_TIMEOUT=1')
    run_action start_sm
    assert_pass; assert_calls 0
    assert_launcher_log
    assert_contains "${CASE_DIR}/output" 'Native start launch requested (PID '
    assert_contains "${CASE_DIR}/output" 'ServiceManager state not independently verified'
    assert_absent "${CASE_DIR}/output" 'Native start script completed'
    assert_absent "${CASE_DIR}/output" 'RUNNING (verified)'
    # Let this finite mock finish before fixture cleanup; it is not a daemon.
    timeout 5 "${BASH_BIN}" -c \
        'until grep -Fq "Native start fixture completed" "$1"; do sleep 0.05; done' \
        -- "${LAUNCHER_LOG}" || fail_test 'Detached finite launcher did not complete'
}

case_native_start_logs() {
    run_action start_sm
    assert_pass; assert_calls 0
    assert_launcher_log
    local first_log="${LAUNCHER_LOG}"
    run_action start_sm
    assert_pass; assert_calls 0
    local files=("${CASE_DIR}/log output/"*_servicemanager_start.log) file
    [[ ${#files[@]} -eq 2 ]] || fail_test 'Native start reused a previous invocation launcher log'
    for file in "${files[@]}"; do
        assert_contains "${file}" 'Native start fixture completed'
        if [[ "${file}" != "${first_log}" ]]; then
            assert_contains "${CASE_DIR}/output" "ServiceManager launcher output: ${file}"
        fi
    done
}

case_start_settings_validation() {
    local name value
    for name in OGG_START_ATTEMPTS OGG_SM_START_GRACE; do
        for value in -1 1.5 invalid; do
            EXTRA_ENV=("${name}=${value}")
            run_action start_sm
            assert_failure; assert_calls 0; assert_no_native
            assert_contains "${CASE_DIR}/output" "${name} must be"
            [[ ! -e "${CASE_DIR}/log output" ]] || fail_test 'Invalid startup settings created logs'
        done
    done
    EXTRA_ENV=('OGG_START_ATTEMPTS=0')
    run_action start_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_failure; assert_calls 0; assert_no_native
    assert_contains "${CASE_DIR}/output" 'OGG_START_ATTEMPTS must be a positive integer'
}

case_lock_conflict() {
    mkdir -p -- "${CASE_DIR}/run/action.lock"
    printf 'owned by another invocation\n' > "${CASE_DIR}/run/action.lock/owner"
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    [[ ${ACTUAL_RC} -ne 0 ]] || fail_test 'Ignored existing lock'
    assert_contains "${CASE_DIR}/output" 'Cannot acquire action lock'
    assert_contains "${CASE_DIR}/output" 'VERDICT: FAIL'
    assert_contains "${CASE_DIR}/run/action.lock/owner" 'owned by another invocation'
    assert_calls 0; assert_no_native
}

case_retry_after_failure() {
    FAKE_MODE=nonzero
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_failure; assert_calls 1
    FAKE_MODE=normal
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass; assert_calls 4
}

case_timeout_validation() {
    local value
    for value in 0 -1 1.5 invalid; do
        EXTRA_ENV=("OGG_COMMAND_TIMEOUT=${value}")
        run_action stop_sm
        assert_failure; assert_calls 0; assert_no_native
        assert_contains "${CASE_DIR}/output" 'OGG_COMMAND_TIMEOUT must be a positive integer'
        [[ ! -e "${CASE_DIR}/log output" ]] || fail_test 'Invalid timeout created logs'
    done
}

case_timeout_success() {
    EXTRA_ENV=('OGG_COMMAND_TIMEOUT=1')
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_pass; assert_calls 3
}

case_admin_timeout() {
    FAKE_MODE=timeout
    EXTRA_ENV=('OGG_COMMAND_TIMEOUT=1')
    run_action stop_ext ogg_oracle03 "${CREDENTIAL_ALIAS}" EXT24P
    assert_failure; assert_calls 1
    assert_contains "${CASE_DIR}/output" 'exit 124'
}

case_native_timeout() {
    FAKE_MODE=native_timeout
    EXTRA_ENV=('OGG_COMMAND_TIMEOUT=1')
    run_action stop_sm
    assert_failure; assert_calls 0
    assert_contains "${CASE_DIR}/output" 'Native ServiceManager stop script failed (exit 124)'
}

run_test() {
    local label="$1" rc
    shift
    CASE_NUMBER=$((CASE_NUMBER + 1))
    CASE_DIR="${TMP_ROOT}/case-${CASE_NUMBER}"
    # Do not put this subshell in an if/|| condition: that disables errexit in
    # test functions and can silently ignore a failed fixture/setup command.
    set +e
    (set -e; setup_case; "$@")
    rc=$?
    set -e
    if [[ ${rc} -eq 0 ]]; then
        PASSED=$((PASSED + 1))
        printf 'PASS %s\n' "${label}"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n' "${label}"
    fi
}

run_test 'argument arities have no side effects' case_arities
run_test 'empty required names fail without side effects' case_empty_names
run_test 'deployment/process injection rejection has no side effects' case_injection
run_test 'help has no side effects' case_help
run_test 'Extract uses DB binary, normalizes name, and verifies STOPPED' case_extract_db
run_test 'Replicat uses DAA binary and verifies STOPPED' case_replicat_daa
for action in start_ext start_rep; do
    run_test "${action} routes correctly, normalizes the name, and verifies RUNNING" case_start_process "${action}" start_normal
    run_test "${action} already RUNNING is idempotent" case_start_process "${action}" start_already_running
    run_test "${action} polls through STARTING until RUNNING" case_start_process "${action}" start_delayed
    run_test "${action} fails when RUNNING is never reached" case_start_process "${action}" start_never_running
done
run_test 'start polling uses START attempts independently of STOP attempts' case_poll_attempts_independent start
run_test 'stop polling uses STOP attempts independently of START attempts' case_poll_attempts_independent stop
run_test 'other deployments default to DB binary' case_unknown_deployment_db
run_test 'ADMINCLIENT_BIN overrides DB/DAA selection' case_explicit_binary
run_test 'sh invocation supports operational action' case_sh_invocation
run_test 'already STOPPED is idempotent' case_idempotent
run_test 'polling waits through STOPPING until STOPPED' case_delayed_stop
run_test 'INFO ALL accepts optional process Type column' case_typed_status
run_test 'malformed STOPPED row without time columns fails' case_status_failure malformed 'Malformed INFO ALL row'
run_test 'malformed STOPPED row with invalid time fails' case_status_failure malformed_time 'Malformed INFO ALL row'
run_test 'missing status row fails without stopping' case_status_failure missing 'found 0'
run_test 'duplicate status rows fail without stopping' case_status_failure duplicate 'found 2'
run_test 'unrecognized status fails without stopping' case_status_failure unknown_status 'Unrecognized status'
run_test 'accepted stop never reaching STOPPED fails' case_never_stops
run_test 'zero exit with ERROR fails' case_admin_failure error_zero 'despite a zero exit status'
run_test 'timestamped ERROR with zero exit fails' case_admin_failure error_timestamp 'despite a zero exit status'
run_test 'not-connected AdminClient prompt fails' case_admin_failure not_connected 'despite a zero exit status'
run_test 'nonzero AdminClient exit fails' case_admin_failure nonzero 'AdminClient failed (exit 17'
run_test 'empty AdminClient output fails' case_admin_failure empty 'returned no output'
run_test 'empty/injected aliases fail before side effects' case_alias_rejection
run_test 'mixed-case alias and permitted punctuation are preserved exactly' case_alias_case_preserved
run_test 'legacy username/password and nonexistent password file are ignored' case_legacy_auth_ignored missing_file
run_test 'legacy password file contents are not consumed or rendered' case_legacy_auth_ignored existing_file
run_test 'echoed alias CONNECT and password-containing output are filtered' case_connect_output_filtering
run_test 'deployment shutdown connects to ServiceManager' case_deployment
run_test 'start_depl uses DAA binary, ServiceManager context, and no process commands' case_deployment start_depl ogg_daa03
run_test 'start_depl uses DB binary, ServiceManager context, and no process commands' case_deployment start_depl ogg_oracle03
run_test 'start_sm prefers startSM.sh with exported env, null stdin, and launcher log' case_native_start preferred
run_test 'missing default startSM.sh fails without invoking another script' case_native_default_missing start
run_test 'start_sm honors explicit native override' case_native_start override
run_test 'native start early nonzero exit fails and releases lock' case_native_start_failure
run_test 'missing explicit native start fails without fallback' case_native_start_missing
run_test 'native start detaches a still-running finite launcher without a state claim' case_native_start_running
run_test 'native start creates separate launcher logs on repeated invocations' case_native_start_logs
run_test 'invalid START attempts and native startup grace fail before side effects' case_start_settings_validation
run_test 'stop_sm prefers stopSM.sh with exported env and no credentials' case_native preferred
run_test 'missing default stopSM.sh fails without invoking another script' case_native_default_missing stop
run_test 'stop_sm honors explicit native override' case_native override
run_test 'native stop nonzero exit fails and releases lock' case_native_failure
run_test 'missing explicit native stop fails without fallback' case_native_missing
run_test 'existing lock prevents actions and is not removed' case_lock_conflict
run_test 'failed action releases lock for a subsequent invocation' case_retry_after_failure
run_test 'zero/negative/noninteger timeouts fail before side effects' case_timeout_validation
run_test 'positive one-second timeout permits fast action' case_timeout_success
run_test 'AdminClient timeout fails and releases lock' case_admin_timeout
run_test 'native timeout fails and releases lock' case_native_timeout

printf '\nOffline OGG tests: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
[[ ${FAILED} -eq 0 ]]
