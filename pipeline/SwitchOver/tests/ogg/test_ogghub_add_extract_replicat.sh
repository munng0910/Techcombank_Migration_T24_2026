#!/usr/bin/env bash
# Offline tests only: all AdminClient calls use a stateful fake in a private directory.
set -euo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$(cd -- "${TEST_DIR}/../.." && pwd)/scripts/OGGHUB_Add-Extract_Add-Replicat.sh
BASH_BIN=$(command -v bash)
[[ -f "${SCRIPT}" ]] || { printf 'Missing implementation: %s\n' "${SCRIPT}" >&2; exit 1; }
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ogghub-add-tests.XXXXXX")
trap 'rm -rf -- "${TMP_ROOT}"' EXIT
PASSED=0
FAILED=0

cat > "${TMP_ROOT}/adminclient" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
lines=()
while IFS= read -r line; do lines+=("${line}"); done
command=''
for line in "${lines[@]}"; do
    case "${line}" in
        connect*|dblogin*|'sh echo '*|exit|'') ;;
        *) command="${line}" ;;
    esac
done
printf '%s\n' "${command}" >> "${FAKE_STATE}/calls"
printf 'OGG (not connected) 1> %s\n' "${lines[0]}"
for line in "${lines[@]}"; do
    if [[ "${line}" == dblogin* ]]; then
        if [[ "${FAKE_MODE}" == login_error ]]; then
            printf 'ERROR OGG-00000 DBLOGIN failed\n'
            exit 0
        fi
        printf 'Successfully logged into database.\n'
    fi
done
if [[ "${command}" == "${FAIL_COMMAND:-__none__}" ]]; then
    case "${FAKE_MODE}" in
        error_zero) printf '2026-10-27T06:18:48Z ERROR OGG-00001 simulated rejection\n' ;;
        warning) printf '2026-10-27T06:18:48Z WARNING OGG-00001 simulated warning\n' ;;
        ora) printf 'ORA-01031: insufficient privileges\n' ;;
        nonzero) printf 'transport failure\n'; exit 17 ;;
        empty) exit 0 ;;
        no_marker) printf '2026-10-27T06:18:48Z INFO OGG-08100 Integrated Extract added.\n'; exit 0 ;;
        timeout) sleep 5; exit 0 ;;
    esac
    printf '__OGGHUB_COMMAND_COMPLETED__\n'
    exit 0
fi
read -r action type name rest <<< "${command}"
case "${command}" in
    'info all')
        if [[ "${FAKE_MODE}" == bad_inventory ]]; then
            printf 'Unrecognized server response\n'
        else
            printf 'Program Status Group Lag at Chkpt Time Since Chkpt\n'
            if [[ "${lines[0]}" == *7801* ]]; then program=EXTRACT; else program=REPLICAT; fi
            for file in "${FAKE_STATE}/${program}."*; do
                [[ -f "${file}" ]] || continue
                read -r status < "${file}"
                group="${file##*.}"
                printf '%s %s %s 00:00:00 00:00:00\n' "${program}" "${status}" "${group}"
            done
        fi
        ;;
    'stop '* )
        [[ "${FAKE_MODE}" == never_stops ]] || printf 'STOPPED\n' > "${FAKE_STATE}/${type^^}.${name}"
        printf 'Stop request accepted.\n'
        ;;
    'delete '* )
        [[ "${FAKE_MODE}" == delete_still_exists ]] || rm -- "${FAKE_STATE}/${type^^}.${name}"
        printf 'Group deleted.\n'
        if [[ "${FAKE_MODE}" == auto_unregister && "${type}" == extract ]]; then
            printf 'INFO OGG-01750 Successfully unregistered Extract group %s from database.\n' "${name}"
        fi
        ;;
    'unregister '* )
        if [[ "${FAKE_MODE}" == unrecognized_unregister ]]; then
            printf 'Unrecognized server response\n'
        else
            printf 'INFO OGG-01750 Successfully unregistered Extract group %s from database.\n' "${name}"
        fi
        ;;
    'add extract '* )
        printf 'STOPPED\n' > "${FAKE_STATE}/EXTRACT.${name}"
        printf '2026-10-27T06:18:48Z INFO OGG-08100 Integrated Extract added.\n'
        ;;
    'add exttrail '* ) printf '2026-10-27T06:18:48Z INFO OGG-08100 EXTTRAIL added.\n' ;;
    'register extract '* ) printf '2026-10-27T06:18:48Z INFO OGG-02003 Extract group %s successfully registered with database at SCN 144162070221.\n' "${name}" ;;
    'add replicat '* )
        printf 'STOPPED\n' > "${FAKE_STATE}/REPLICAT.${name}"
        printf 'INFO OGG-08100 No checkpoint table specified. Using GLOBALS specification ...\n'
        printf 'INFO OGG-08100 Replicat added.\n'
        printf 'INFO OGG-06594 Replicat %s has been altered. Even the start up position might be updated, duplicate suppression remains active in next startup.\n' "${name}"
        ;;
    'info '* )
        case "${name}" in
            R18T24P) trail=R18/hb; seq=800000 ;;
            R18EXT3) trail=R18/ds; seq=11000 ;;
            X18T24P) trail=R18/pc; seq=890000 ;;
            ET24P) trail=R25/hb; seq=800000 ;;
            DS1EXT3) trail=R25/ds; seq=11000 ;;
            EXT24P) trail=R25/pc; seq=890000 ;;
            R18_DL1|R18_DL3) trail=R18/pc; seq=890000 ;;
            R18_DL2) trail=R18/hb; seq=800000 ;;
            RPLDS1|RPLDS3) trail=R25/pc; seq=890000 ;;
            RPLDS2) trail=R25/hb; seq=800000 ;;
            *) printf 'ERROR unknown group\n'; exit 0 ;;
        esac
        status=STOPPED
        [[ "${FAKE_MODE}" != wrong_status ]] || status=RUNNING
        printf '%s %s Initialized 2026-10-27 13:18 Status %s\n' "${type^}" "${name}" "${status}"
        printf 'Error log            /ogghub-data/deployments/corelivedb/var/log/ggserr.log\n'
        if [[ "${type}" == extract ]]; then
            [[ "${FAKE_MODE}" != wrong_seq ]] || seq=1
            printf '%s %s 0 1024 EXTTRAIL\n' "${trail}" "${seq}"
            if [[ "${FAKE_MODE}" != missing_registration ]]; then
                printf 'Integrated Extract outbound server first scn: 33.2428149453 (144162070221)\n'
            fi
            printf 'No Replicat groups found, but some coordinated threads may have been excluded.\n'
        else
            [[ "${FAKE_MODE}" != wrong_checkpoint ]] || seq=1
            printf 'Log Read Checkpoint File /ogghub-data/deployments/corelivedb/var/lib/data/%s%09d\n' "${trail}" "${seq}"
            printf '    First Record RBA 0\n'
            printf 'No Extract groups exist.\n'
        fi
        ;;
    *) printf 'ERROR unexpected fake command: %s\n' "${command}"; exit 9 ;;
esac
printf 'OGG (https://localhost deployment) 9> sh echo __OGGHUB_COMMAND_COMPLETED__\n'
printf '__OGGHUB_COMMAND_COMPLETED__\n'
FAKE
chmod +x "${TMP_ROOT}/adminclient"

fail_test() {
    printf '    %s\n' "$*" >&2
    cat -- "${CASE_DIR}/output" >&2
    exit 1
}
contains() { grep -Eq -- "$2" "$1" || fail_test "Missing pattern: $2"; }
absent() { if grep -Eq -- "$2" "$1"; then fail_test "Unexpected pattern: $2"; fi; }
run_script() {
    local answer="${1:-}" timeout=10
    [[ "${FAKE_MODE}" != timeout ]] || timeout=1
    rc=0
    printf '%s\n' "${answer}" | env -i \
        PATH="${PATH}" HOME="${CASE_DIR}" TMPDIR="${TMP_ROOT}" \
        SYSTEMROOT="${SYSTEMROOT:-${SystemRoot:-}}" \
        FAKE_STATE="${CASE_DIR}" FAKE_MODE="${FAKE_MODE}" FAIL_COMMAND="${FAIL_COMMAND:-}" \
        ADMINCLIENT_DB="${TMP_ROOT}/adminclient" ADMINCLIENT_DAA="${TMP_ROOT}/adminclient" \
        LOG_DIR="${CASE_DIR}/log" OGG_COMMAND_TIMEOUT="${timeout}" OGG_STOP_ATTEMPTS=2 OGG_POLL_INTERVAL=0 \
        "${BASH_BIN}" "${SCRIPT}" > "${CASE_DIR}/output" 2>&1 || rc=$?
}
assert_pass() {
    [[ ${rc} -eq 0 ]] || fail_test "Expected exit 0, got ${rc}"
    contains "${CASE_DIR}/output" '^VERDICT: PASS$'
    [[ $(grep -c 'ADD: PASS$' "${CASE_DIR}/output") -eq 12 ]] || fail_test 'Not all ADD tasks passed.'
    contains "${CASE_DIR}"/log/*.log '^VERDICT: PASS$'
    absent "${CASE_DIR}/calls" '^start '
}
assert_fail() {
    [[ ${rc} -ne 0 ]] || fail_test 'Expected nonzero exit.'
    contains "${CASE_DIR}/output" '^VERDICT: FAIL$'
    absent "${CASE_DIR}/output" '^VERDICT: PASS$'
}
seed() {
    printf '%s\n' "${2:-STOPPED}" > "${CASE_DIR}/$1"
}

fresh() { run_script; assert_pass; absent "${CASE_DIR}/calls" '^(delete|unregister|stop) '; }
confirmed() {
    for group in R18T24P R18EXT3 X18T24P ET24P DS1EXT3 EXT24P; do seed "EXTRACT.${group}" RUNNING; done
    for group in R18_DL1 R18_DL2 R18_DL3 RPLDS1 RPLDS2 RPLDS3; do seed "REPLICAT.${group}" RUNNING; done
    seed EXTRACT.UNRELATED_EXT RUNNING
    seed REPLICAT.UNRELATED_REP RUNNING
    run_script DELETE
    assert_pass
    [[ $(grep -c '^delete ' "${CASE_DIR}/calls") -eq 12 ]] || fail_test 'Expected 12 deletes.'
    [[ $(grep -c '^unregister ' "${CASE_DIR}/calls") -eq 6 ]] || fail_test 'Expected 6 unregisters.'
    [[ $(grep -c '^stop ' "${CASE_DIR}/calls") -eq 12 ]] || fail_test 'Expected 12 stops.'
    [[ $(grep -c 'CLEANUP: PASS' "${CASE_DIR}/output") -eq 12 ]] || fail_test 'Not all cleanup tasks passed.'
    absent "${CASE_DIR}/calls" '^(delete|stop).*UNRELATED'
    awk '/^delete replicat/ {rep++} /^delete extract/ && rep != 6 {exit 1}' "${CASE_DIR}/calls" || fail_test 'Extract deleted before all Replicats.'
    awk '/^delete extract/ {split($0,a," "); pending=a[3]} /^unregister extract/ {if ($3 != pending) exit 1; pending=""} END {if (pending != "") exit 1}' "${CASE_DIR}/calls" || fail_test 'Wrong unregister order.'
}
cancelled() {
    seed EXTRACT.R18T24P
    run_script no
    assert_fail
    absent "${CASE_DIR}/calls" '^(add|delete|stop|unregister) '
}
eof_confirmation() {
    seed REPLICAT.R18_DL1
    run_script ''
    assert_fail
    absent "${CASE_DIR}/calls" '^(add|delete|stop|unregister) '
}
failed_command() {
    FAIL_COMMAND='add extract R18T24P integrated tranlog begin now'
    run_script
    assert_fail
    contains "${CASE_DIR}/output" 'R18T24P +CLEANUP: ABSENT +ADD: FAIL'
    absent "${CASE_DIR}/calls" '^(add exttrail|register|add replicat|add extract R18EXT3) '
}
failed_trail() {
    FAIL_COMMAND='add exttrail R18/hb extract R18T24P megabytes 1024 seqno 800000'
    run_script
    assert_fail
    absent "${CASE_DIR}/calls" '^register '
}
failed_register() {
    FAIL_COMMAND='register extract R18T24P database'
    run_script
    assert_fail
    absent "${CASE_DIR}/calls" '^add extract R18EXT3 '
}
failed_inventory() {
    run_script
    assert_fail
    absent "${CASE_DIR}/calls" '^(add|delete|stop|unregister) '
}
stuck_stop() {
    seed EXTRACT.R18T24P RUNNING
    run_script DELETE
    assert_fail
    absent "${CASE_DIR}/calls" '^(delete|unregister|add) '
}
stuck_delete() {
    seed EXTRACT.R18T24P
    run_script DELETE
    assert_fail
    absent "${CASE_DIR}/calls" '^(unregister|add) '
}
failed_unregister() {
    seed EXTRACT.R18T24P
    FAIL_COMMAND='unregister extract R18T24P database'
    run_script DELETE
    assert_fail
    contains "${CASE_DIR}/output" 'R18T24P +CLEANUP: FAIL +ADD: SKIPPED'
    absent "${CASE_DIR}/calls" '^add '
}
automatic_unregister() {
    seed EXTRACT.R18T24P
    # Deliberately stop at the first ADD acknowledgement, after checking cleanup.
    FAIL_COMMAND='add extract R18T24P integrated tranlog begin now'
    run_script DELETE
    assert_fail
    contains "${CASE_DIR}/output" 'R18T24P +CLEANUP: PASS +ADD: FAIL'
    contains "${CASE_DIR}/calls" '^delete extract R18T24P !$'
    absent "${CASE_DIR}/calls" '^unregister '
}
login_before_cleanup() {
    seed REPLICAT.R18_DL1 RUNNING
    run_script DELETE
    assert_fail
    absent "${CASE_DIR}/calls" '^(stop|delete|unregister|add) '
}
failed_verification() { run_script; assert_fail; }
failed_replicat() {
    FAIL_COMMAND='add replicat R18_DL1 exttrail /ogghub-data/deployments/corelivedb/var/lib/data/R18/pc extseqno 890000 extrba 0'
    run_script
    assert_fail
    contains "${CASE_DIR}/output" 'R18_DL1 +CLEANUP: ABSENT +ADD: FAIL'
    absent "${CASE_DIR}/calls" '^add replicat R18_DL2 '
}

run_test() {
    local name="$1" mode="$2" function="$3"
    [[ -z "${TEST_FILTER:-}" || "${name}" =~ ${TEST_FILTER} ]] || return 0
    CASE_DIR="${TMP_ROOT}/${name}"
    mkdir -- "${CASE_DIR}"
    FAKE_MODE="${mode}"
    FAIL_COMMAND=''
    if ("${function}"); then
        printf 'PASS %s\n' "${name}"
        PASSED=$((PASSED + 1))
    else
        printf 'FAIL %s\n' "${name}"
        FAILED=$((FAILED + 1))
    fi
}
run_test fresh fresh fresh
run_test confirmed_cleanup fresh confirmed
run_test reject_cleanup fresh cancelled
run_test no_confirmation fresh eof_confirmation
for mode in error_zero warning ora nonzero empty no_marker timeout; do
    run_test "add_${mode}" "${mode}" failed_command
done
run_test exttrail_error error_zero failed_trail
run_test register_error error_zero failed_register
run_test unrecognized_inventory bad_inventory failed_inventory
run_test login_failure login_error failed_verification
run_test stop_timeout never_stops stuck_stop
run_test delete_not_effective delete_still_exists stuck_delete
run_test unregister_error error_zero failed_unregister
run_test unregister_unrecognized unrecognized_unregister failed_unregister
run_test auto_unregister auto_unregister automatic_unregister
run_test login_before_cleanup login_error login_before_cleanup
run_test wrong_status wrong_status failed_verification
run_test wrong_sequence wrong_seq failed_verification
run_test no_registration missing_registration failed_verification
run_test wrong_checkpoint wrong_checkpoint failed_verification
run_test replicat_error error_zero failed_replicat
printf '\nTests: %s PASS, %s FAIL\n' "${PASSED}" "${FAILED}"
[[ ${FAILED} -eq 0 ]]
