#!/usr/bin/env bash
# Offline wildcard contracts; all AdminClient binaries, inventory and state are
# private sandbox fixtures. Run with Bash; no production services are contacted.
set -euo pipefail
shopt -s nullglob

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$(cd -- "${TEST_DIR}/../.." && pwd)/op_ogg_actions.sh
BASH_BIN=$(command -v bash)
command -v timeout >/dev/null || { printf 'GNU timeout is required.\n' >&2; exit 1; }
[[ -f "${SCRIPT}" ]] || { printf 'Missing implementation: %s\n' "${SCRIPT}" >&2; exit 1; }
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ogg-wildcard-tests.XXXXXX")
trap 'rm -rf -- "${TMP_ROOT}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PASSED=0
FAILED=0
CASE_NUMBER=0
ALIAS='oGgHub_Core.Live$#-01'

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

assert_calls() {
    local files=("${CASE_DIR}/admin/"*.input)
    [[ ${#files[@]} -eq "$1" ]] || fail_test "Expected $1 AdminClient calls, got ${#files[@]}"
}

assert_lock_released() {
    [[ ! -e "${CASE_DIR}/run/action.lock" ]] || fail_test 'Action lock was not released'
}

assert_pass() {
    [[ ${ACTUAL_RC} -eq 0 ]] || fail_test "Expected success, got ${ACTUAL_RC}"
    assert_contains "${CASE_DIR}/output" 'VERDICT: PASS'
    assert_contains "${CASE_DIR}/output" 'Exit code: 0'
    assert_lock_released
}

assert_failure() {
    [[ ${ACTUAL_RC} -ne 0 ]] || fail_test 'Wildcard action unexpectedly succeeded'
    assert_contains "${CASE_DIR}/output" 'VERDICT: FAIL'
    assert_absent "${CASE_DIR}/output" 'VERDICT: PASS'
    assert_lock_released
}

assert_no_mutation() {
    [[ ! -e "${CASE_DIR}/mutations" ]] || fail_test 'Mutation occurred before inventory validation completed'
}

assert_no_side_effects() {
    assert_calls 0
    assert_no_mutation
    [[ ! -e "${CASE_DIR}/log output" && ! -e "${CASE_DIR}/run" ]] ||
        fail_test 'Invalid arguments created log/lock directories'
    [[ ! -e "${CASE_DIR}/injected" ]] || fail_test 'An injected command ran'
}

assert_context() {
    local context="$1" binary="$2" file first_line
    for file in "${CASE_DIR}/admin/"*.input; do
        IFS= read -r first_line < "${file}"
        [[ "${first_line}" == "connect https://offline.invalid:7801 deployment ${context} as ${ALIAS}" ]] ||
            fail_test "Wrong deployment/alias order or CONNECT context in ${file}"
        assert_contains "${file%.input}.binary" "${CASE_DIR}/${binary}/bin/adminclient"
        assert_absent "${file}" 'password'
    done
}

# Assert an exact batch (not one invocation per group), ignoring group ordering.
# Explicit commands must target only the selected type and non-desired groups.
assert_batch() {
    local input="${CASE_DIR}/admin/002.input" line count=0 group
    local expected=("$@")
    while IFS= read -r line; do
        case "${line}" in
            connect\ *|exit) continue ;;
        esac
        count=$((count + 1))
        local found=false
        for group in "${expected[@]}"; do
            if [[ "${line}" == "${OPERATION} ${PROGRAM,,} ${group}" ]]; then
                found=true
                break
            fi
        done
        [[ "${found}" == true ]] || fail_test "Unexpected batch command: ${line}"
    done < "${input}"
    [[ ${count} -eq ${#expected[@]} ]] || fail_test "Expected ${#expected[@]} explicit batch commands, got ${count}"
    for group in "${expected[@]}"; do
        count=$(grep -Fxc -- "${OPERATION} ${PROGRAM,,} ${group}" "${input}" || true)
        [[ ${count} -eq 1 ]] || fail_test "Group ${group} was not commanded exactly once"
    done
    local file
    for file in "${CASE_DIR}/admin/"*.input; do
        assert_absent "${file}" "${OPERATION} ${PROGRAM,,} *"
        assert_absent "${file}" "${OPERATION} ${OTHER_PROGRAM,,} "
    done
}

assert_queries() {
    local expected="$1" actual=0 file
    for file in "${CASE_DIR}/admin/"*.input; do
        if grep -Fxq -- 'info all' "${file}"; then
            actual=$((actual + 1))
        fi
    done
    [[ ${actual} -eq ${expected} ]] || fail_test "Expected ${expected} inventory queries, got ${actual}"
}

setup_case() {
    mkdir -p -- "${CASE_DIR}/admin" "${CASE_DIR}/inventory" "${CASE_DIR}/ogg/bin" \
        "${CASE_DIR}/daa/bin" "${CASE_DIR}/override/bin" "${CASE_DIR}/sm"
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
case "${lines[1]:-}" in
    'info all')
        q=0
        [[ ! -f "${FAKE_STATE}/query.count" ]] || read -r q < "${FAKE_STATE}/query.count"
        q=$((q + 1))
        printf '%s\n' "${q}" > "${FAKE_STATE}/query.count"
        case "${FAKE_MODE}" in
            query_nonzero) printf 'simulated inventory transport failure\n'; exit 17 ;;
            query_error) printf 'ERROR: simulated inventory rejection\n'; exit 0 ;;
            query_empty) exit 0 ;;
        esac
        [[ -f "${FAKE_STATE}/inventory/${q}.txt" ]] || {
            printf 'ERROR: unexpected extra inventory query\n'; exit 29;
        }
        cat -- "${FAKE_STATE}/inventory/${q}.txt"
        ;;
    'start deployment *'|'stop deployment *')
        [[ ${#lines[@]} -eq 3 && "${lines[2]}" == exit ]] || {
            printf 'ERROR: unexpected deployment batch\n'; exit 29;
        }
        printf '%s\n' "${lines[1]}" >> "${FAKE_STATE}/mutations"
        case "${FAKE_MODE}" in
            deployment_nonzero) printf 'simulated deployment failure\n'; exit 17 ;;
            deployment_error) printf 'ERROR: simulated deployment rejection\n'; exit 0 ;;
        esac
        printf 'Deployment command completed\n'
        ;;
    *)
        applied=0
        for line in "${lines[@]:1}"; do
            [[ "${line}" != exit ]] || continue
            [[ "${line}" =~ ^(start|stop)[[:space:]](extract|replicat)[[:space:]][A-Z0-9_]+$ ]] || {
                printf 'ERROR: unsafe or unexpected process command\n'; exit 29;
            }
            # Fail after the first command has really been accepted. A failed
            # batch must not be treated as success even if one group changed.
            if [[ ${applied} -eq 1 ]]; then
                case "${FAKE_MODE}" in
                    batch_nonzero) printf 'simulated second-command failure\n'; exit 17 ;;
                    batch_error) printf '2026-01-02 03:04:05 ERROR: second command rejected\n'; exit 0 ;;
                esac
            fi
            printf '%s\n' "${line}" >> "${FAKE_STATE}/mutations"
            applied=$((applied + 1))
            printf 'Command accepted: %s\n' "${line}"
        done
        [[ ${applied} -gt 0 ]] || { printf 'ERROR: empty mutation batch\n'; exit 29; }
        ;;
esac
FAKE_ADMIN
    local binary
    for binary in ogg daa override; do
        cp -- "${CASE_DIR}/fake-adminclient" "${CASE_DIR}/${binary}/bin/adminclient"
        chmod +x "${CASE_DIR}/${binary}/bin/adminclient"
    done
    EXTRA_ENV=()
    FAKE_MODE=normal
    select_action stop_ext
}

select_action() {
    ACTION="$1"
    OPERATION="${ACTION%%_*}"
    PROGRAM=EXTRACT
    OTHER_PROGRAM=REPLICAT
    DEPLOYMENT=ogg_oracle03
    BINARY=ogg
    if [[ "${ACTION}" == *_rep ]]; then
        PROGRAM=REPLICAT
        OTHER_PROGRAM=EXTRACT
        DEPLOYMENT=ogg_daa03
        BINARY=daa
    fi
    DESIRED=STOPPED
    INITIAL=RUNNING
    PENDING=STOPPING
    if [[ "${OPERATION}" == start ]]; then
        DESIRED=RUNNING
        INITIAL=STOPPED
        PENDING=STARTING
    fi
}

run_action() {
    # env -i removes ambient OGG settings, credentials and startup-file hooks.
    # All executable paths are sandbox fakes or deliberately nonexistent.
    if env -i PATH="${PATH}" HOME="${CASE_DIR}" TMPDIR="${TMP_ROOT}" \
        SYSTEMROOT="${SYSTEMROOT:-${SystemRoot:-}}" \
        SM_HOME="${CASE_DIR}/sm" OGG_HOME="${CASE_DIR}/ogg" \
        ADMINCLIENT_DB="${CASE_DIR}/ogg/bin/adminclient" \
        ADMINCLIENT_DAA="${CASE_DIR}/daa/bin/adminclient" \
        OGG_START_SM_SCRIPT="${CASE_DIR}/no-native-start" \
        OGG_STOP_SM_SCRIPT="${CASE_DIR}/no-native-stop" \
        OGG_ENDPOINT='https://offline.invalid:7801' OGG_INSECURE_TLS=false \
        OGG_COMMAND_TIMEOUT=3 OGG_START_ATTEMPTS=2 OGG_STOP_ATTEMPTS=2 OGG_POLL_INTERVAL=0 \
        LOG_DIR="${CASE_DIR}/log output" OGG_ACTION_LOCK_DIR="${CASE_DIR}/run/action.lock" \
        FAKE_STATE="${CASE_DIR}" FAKE_MODE="${FAKE_MODE}" \
        "${EXTRA_ENV[@]}" "${BASH_BIN}" "${SCRIPT}" "$@" \
        < /dev/null > "${CASE_DIR}/output" 2>&1; then
        ACTUAL_RC=0
    else
        ACTUAL_RC=$?
    fi
}

row() {
    printf '%s %s %s %s00:00:00 00:00:00\n' "$1" "$2" "$3" "${4:+$4 }"
}

# A valid requested row always precedes a deliberately invalid one. This catches
# implementations that mutate while parsing instead of validating the snapshot.
make_inventory() {
    local number="$1" variant="$2" type=''
    [[ "${variant}" != typed && "${variant}" != typed_desired ]] || type=INTEGRATED
    {
        printf 'Program Status Group %sLag at Chkpt Time Since Chkpt\n' "${type:+Type }"
        row "${OTHER_PROGRAM}" "${INITIAL}" UNRELATED_A
        row "${OTHER_PROGRAM}" ABENDED UNRELATED_B
        case "${variant}" in
            no_matches) ;;
            desired|typed_desired)
                row "${PROGRAM}" "${DESIRED}" A_GRP "${type}"
                row "${PROGRAM}" "${DESIRED}" B_GRP "${type}"
                row "${PROGRAM}" "${DESIRED}" C_GRP "${type}"
                ;;
            pending)
                row "${PROGRAM}" "${DESIRED}" A_GRP
                row "${PROGRAM}" "${DESIRED}" B_GRP
                row "${PROGRAM}" "${PENDING}" C_GRP
                ;;
            oscillating)
                row "${PROGRAM}" "${PENDING}" A_GRP
                row "${PROGRAM}" "${DESIRED}" B_GRP
                row "${PROGRAM}" "${DESIRED}" C_GRP
                ;;
            missing)
                row "${PROGRAM}" "${DESIRED}" A_GRP
                row "${PROGRAM}" "${DESIRED}" B_GRP
                ;;
            new)
                row "${PROGRAM}" "${DESIRED}" A_GRP
                row "${PROGRAM}" "${DESIRED}" B_GRP
                row "${PROGRAM}" "${DESIRED}" C_GRP
                row "${PROGRAM}" "${DESIRED}" NEW_GRP
                ;;
            replaced)
                row "${PROGRAM}" "${DESIRED}" A_GRP
                row "${PROGRAM}" "${DESIRED}" B_GRP
                row "${PROGRAM}" "${DESIRED}" NEW_GRP
                ;;
            *)
                row "${PROGRAM}" "${DESIRED}" A_GRP "${type}"
                row "${PROGRAM}" "${INITIAL}" B_GRP "${type}"
                row "${PROGRAM}" ABENDED C_GRP "${type}"
                case "${variant}" in
                    normal|typed) ;;
                    duplicate) row "${PROGRAM}" "${INITIAL}" B_GRP ;;
                    duplicate_case) row "${PROGRAM}" "${INITIAL}" b_grp ;;
                    malformed) printf '%s %s BAD_ROW\n' "${PROGRAM}" "${INITIAL}" ;;
                    malformed_time) printf '%s %s BAD_ROW 00:00:00 not-a-time\n' "${PROGRAM}" "${INITIAL}" ;;
                    missing_group) printf '%s %s\n' "${PROGRAM}" "${INITIAL}" ;;
                    unknown_status) row "${PROGRAM}" BOGUS BAD_ROW ;;
                    unsafe_glob) row "${PROGRAM}" "${INITIAL}" 'BAD*' ;;
                    unsafe_question) row "${PROGRAM}" "${INITIAL}" 'BAD?' ;;
                    unsafe_bracket) row "${PROGRAM}" "${INITIAL}" 'BAD[1]' ;;
                    unsafe_punctuation) row "${PROGRAM}" "${INITIAL}" 'BAD;exit' ;;
                    unsafe_space) row "${PROGRAM}" "${INITIAL}" 'BAD NAME' ;;
                    unsafe_injection) row "${PROGRAM}" "${INITIAL}" "BAD;touch ${CASE_DIR}/injected" ;;
                    unsafe_hyphen) row "${PROGRAM}" "${INITIAL}" 'BAD-NAME' ;;
                    *) fail_test "Unknown inventory variant: ${variant}" ;;
                esac
                ;;
        esac
    } > "${CASE_DIR}/inventory/${number}.txt"
}

case_process_batch() {
    select_action "$1"
    make_inventory 1 "$2"
    make_inventory 2 "$3"
    run_action "${ACTION}" "${DEPLOYMENT}" "${ALIAS}" '*'
    assert_pass; assert_calls 3; assert_queries 2
    assert_context "${DEPLOYMENT}" "${BINARY}"
    assert_batch B_GRP C_GRP
    local count
    count=$(wc -l < "${CASE_DIR}/mutations")
    [[ ${count} -eq 2 ]] || fail_test 'Expected only two non-desired groups to be mutated'
}

case_already_desired() {
    select_action "$1"
    make_inventory 1 desired
    run_action "${ACTION}" "${DEPLOYMENT}" "${ALIAS}" '*'
    assert_pass; assert_calls 1; assert_queries 1; assert_no_mutation
    assert_context "${DEPLOYMENT}" "${BINARY}"
}

case_poll_all() {
    select_action "$1"
    make_inventory 1 normal
    make_inventory 2 pending
    make_inventory 3 "$2"
    run_action "${ACTION}" "${DEPLOYMENT}" "${ALIAS}" '*'
    if [[ "$2" == desired ]]; then
        assert_pass
    else
        assert_failure
    fi
    assert_calls 4; assert_queries 3
    assert_batch B_GRP C_GRP
}

case_bad_snapshot() {
    select_action "$1"
    make_inventory 1 "$2"
    run_action "${ACTION}" "${DEPLOYMENT}" "${ALIAS}" '*'
    assert_failure; assert_calls 1; assert_queries 1; assert_no_mutation
    [[ ! -e "${CASE_DIR}/injected" ]] || fail_test 'Unsafe inventory group executed a shell command'
}

case_changed_inventory() {
    select_action "$1"
    make_inventory 1 normal
    if [[ "$3" == late ]]; then
        make_inventory 2 pending
        make_inventory 3 "$2"
    else
        make_inventory 2 "$2"
    fi
    run_action "${ACTION}" "${DEPLOYMENT}" "${ALIAS}" '*'
    assert_failure
    if [[ "$3" == late ]]; then
        assert_calls 4; assert_queries 3
    else
        assert_calls 3; assert_queries 2
    fi
    assert_batch B_GRP C_GRP
}

case_partial_failure() {
    select_action "$1"
    FAKE_MODE="$2"
    make_inventory 1 normal
    # A correct implementation stops immediately at the command failure.
    # Any accidental polling could otherwise see all groups in the desired state.
    make_inventory 2 desired
    run_action "${ACTION}" "${DEPLOYMENT}" "${ALIAS}" '*'
    assert_failure; assert_calls 2; assert_queries 1
    assert_batch B_GRP C_GRP
    local count
    count=$(wc -l < "${CASE_DIR}/mutations")
    [[ ${count} -eq 1 ]] || fail_test 'Partial failure fixture did not apply exactly the first command'
}

case_query_failure() {
    FAKE_MODE="$1"
    run_action stop_ext ogg_oracle03 "${ALIAS}" '*'
    assert_failure; assert_calls 1; assert_queries 1; assert_no_mutation
}

case_deployment() {
    local action="$1" selection="$2" mode="$3" binary=ogg
    FAKE_MODE="${mode}"
    if [[ "${selection}" == override ]]; then
        binary=override
        EXTRA_ENV=("ADMINCLIENT_BIN=${CASE_DIR}/override/bin/adminclient" \
            "ADMINCLIENT_DB=${CASE_DIR}/missing-db" "ADMINCLIENT_DAA=${CASE_DIR}/missing-daa")
    fi
    run_action "${action}" '*' "${ALIAS}"
    if [[ "${mode}" == normal ]]; then
        assert_pass
        assert_contains "${CASE_DIR}/output" 'deployment state not independently verified'
        assert_absent "${CASE_DIR}/output" 'RUNNING (verified)'
        assert_absent "${CASE_DIR}/output" 'STOPPED (verified)'
    else
        assert_failure
    fi
    assert_calls 1; assert_queries 0
    assert_context ServiceManager "${binary}"
    local command="${action%_depl} deployment *" line count=0
    while IFS= read -r line; do
        case "${line}" in connect\ *|exit) continue ;; esac
        [[ "${line}" == "${command}" ]] || fail_test "Unexpected deployment command: ${line}"
        count=$((count + 1))
    done < "${CASE_DIR}/admin/001.input"
    [[ ${count} -eq 1 ]] || fail_test 'Expected exactly one literal deployment wildcard command'
    assert_contains "${CASE_DIR}/mutations" "${command}"
}

case_argument_rejection() {
    local action value
    for action in start_ext stop_ext start_rep stop_rep; do
        for value in 'EXT*' '?' 'EXT[12]' 'EXT REP' $'EXT\nREP' 'EXT;exit'; do
            run_action "${action}" ogg_oracle03 "${ALIAS}" "${value}"
            [[ ${ACTUAL_RC} -ne 0 ]] || fail_test "Accepted partial/unsafe wildcard: ${value}"
            assert_no_side_effects
        done
        run_action "${action}" '*' "${ALIAS}" '*'
        [[ ${ACTUAL_RC} -ne 0 ]] || fail_test 'Accepted wildcard deployment context for a process action'
        assert_no_side_effects
        run_action "${action}" ogg_oracle03 '*' '*'
        [[ ${ACTUAL_RC} -ne 0 ]] || fail_test 'Accepted wildcard credential alias'
        assert_no_side_effects
    done
    for action in start_depl stop_depl; do
        for value in 'ogg*' '?' 'ogg[12]' 'ogg name' 'ogg;exit'; do
            run_action "${action}" "${value}" "${ALIAS}"
            [[ ${ACTUAL_RC} -ne 0 ]] || fail_test "Accepted partial/unsafe deployment wildcard: ${value}"
            assert_no_side_effects
        done
        run_action "${action}" '*' '*'
        [[ ${ACTUAL_RC} -ne 0 ]] || fail_test 'Accepted wildcard credential with wildcard deployment'
        assert_no_side_effects
    done
}

case_shell_expansion() {
    # Expand an unquoted wildcard against two real sandbox entries. No dependence
    # on the checkout's filenames or the calling shell's current directory.
    mkdir -p -- "${CASE_DIR}/expanded/FIRST" "${CASE_DIR}/expanded/SECOND"
    local expanded=("${CASE_DIR}/expanded/"*) action
    [[ ${#expanded[@]} -eq 2 ]] || fail_test 'Expansion fixture must contain two entries'
    for action in start_ext stop_ext start_rep stop_rep; do
        run_action "${action}" ogg_oracle03 "${ALIAS}" "${expanded[@]}"
        [[ ${ACTUAL_RC} -eq 2 ]] || fail_test 'Expanded process wildcard did not get usage exit 2'
        assert_contains "${CASE_DIR}/output" 'Usage:'
        grep -Eiq -- 'quot(e|ed|ing)|literal|shell.*expand|expand.*shell' "${CASE_DIR}/output" ||
            fail_test 'Usage lacks a wildcard quoting/shell-expansion hint'
        assert_no_side_effects
    done
    for action in start_depl stop_depl; do
        run_action "${action}" "${expanded[@]}" "${ALIAS}"
        [[ ${ACTUAL_RC} -eq 2 ]] || fail_test 'Expanded deployment wildcard did not get usage exit 2'
        assert_contains "${CASE_DIR}/output" 'Usage:'
        grep -Eiq -- 'quot(e|ed|ing)|literal|shell.*expand|expand.*shell' "${CASE_DIR}/output" ||
            fail_test 'Usage lacks a wildcard quoting/shell-expansion hint'
        assert_no_side_effects
    done
}

run_test() {
    local label="$1" rc
    shift
    CASE_NUMBER=$((CASE_NUMBER + 1))
    CASE_DIR="${TMP_ROOT}/case-${CASE_NUMBER}"
    # Keep the subshell out of if/|| so errexit remains active in test helpers.
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

for action in start_ext stop_ext start_rep stop_rep; do
    run_test "${action}: snapshot batch targets only incorrect states and selected type" case_process_batch "${action}" normal desired
    run_test "${action}: all already desired needs only the initial query" case_already_desired "${action}"
    run_test "${action}: polls every group until the entire snapshot settles" case_poll_all "${action}" desired
    run_test "${action}: one pending group prevents a false PASS" case_poll_all "${action}" pending
    run_test "${action}: a previously good group cannot regress unnoticed" case_poll_all "${action}" oscillating
    for mode in batch_nonzero batch_error; do
        run_test "${action}: partial command failure (${mode}) fails and releases lock" case_partial_failure "${action}" "${mode}"
    done
done
run_test 'optional Type column is accepted in both discovery and verification' case_process_batch start_rep typed typed_desired
for variant in no_matches duplicate duplicate_case malformed malformed_time missing_group unknown_status \
    unsafe_glob unsafe_question unsafe_bracket unsafe_punctuation unsafe_space unsafe_injection unsafe_hyphen; do
    run_test "invalid discovery (${variant}) prevents the entire mutation batch" case_bad_snapshot stop_ext "${variant}"
done
run_test 'Replicat malformed discovery also invalidates its whole batch' case_bad_snapshot start_rep malformed
for action in start_ext stop_rep; do
    for variant in missing new replaced duplicate malformed unknown_status unsafe_glob; do
        run_test "${action}: changed/invalid inventory (${variant}) fails after mutation" case_changed_inventory "${action}" "${variant}" immediate
    done
    run_test "${action}: membership changes on a later poll are still rejected" case_changed_inventory "${action}" new late
done
for mode in query_nonzero query_error query_empty; do
    run_test "inventory query failure (${mode}) fails without mutation and releases lock" case_query_failure "${mode}"
done
for action in start_depl stop_depl; do
    run_test "${action}: literal wildcard uses DB binary and ServiceManager, completion only" case_deployment "${action}" default normal
    run_test "${action}: explicit ADMINCLIENT_BIN overrides DB and DAA for wildcard" case_deployment "${action}" override normal
    for mode in deployment_nonzero deployment_error; do
        run_test "${action}: wildcard command failure (${mode}) fails and releases lock" case_deployment "${action}" default "${mode}"
    done
done
run_test 'partial globs, unsafe tokens and wildcards in forbidden positions have no side effects' case_argument_rejection
run_test 'shell-expanded wildcard argument counts give usage and a quoting hint' case_shell_expansion

printf '\nOffline OGG wildcard tests: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
[[ ${FAILED} -eq 0 ]]
