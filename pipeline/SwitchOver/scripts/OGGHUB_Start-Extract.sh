#!/bin/bash
# OGGHUB_Start_Extract.sh - Start and verify R18 & R25 Extracts on OGGHUB_CORELIVEDB
set -euo pipefail

# 1. Environment & Paths Setup
ADMINCLIENT_DB="/u01/app/OracleGoldenGate/ogg_oracle/bin/adminclient"

LOG_DIR="/home/oracle/REHscript/log"
LOG_FILE="${LOG_DIR}/OGGHUB_Start_Extract_$(date +%Y%m%d_%H%M%S).log"
TMP_OUT="${LOG_DIR}/OGGHUB_Start_Extract_$$.out"

# Redirect stdout and stderr to both console and log file
exec > >(tee -a "${LOG_FILE}") 2>&1
trap 'rm -f "${TMP_OUT}"' EXIT

# 2. Check binary existence and execution permissions
if [ ! -x "${ADMINCLIENT_DB}" ]; then
    echo "Error: adminclient not found or not executable at ${ADMINCLIENT_DB}" >&2
    exit 1
fi

echo "======================================================================"
echo " Starting OGGHUB_Start_Extract.sh execution at $(date)"
echo " Log file: ${LOG_FILE}"
echo "======================================================================"

# ===================================================================
# 3. Start Extracts for R18 & R25 Streams (Single Connection)
# ===================================================================
echo "============================ START EXTRACTS (R18 & R25) ============================"
"${ADMINCLIENT_DB}" << 'EOF'
connect https://localhost:7801 as OGGHUB_CORELIVEDB

-- R18 Extracts
dblogin useridalias T24_RHS_19
sh echo "--- Starting Extract R18T24P (Trail: hb) ---"
start extract R18T24P !
sh echo "--- Starting Extract R18EXT3 (Trail: ds) ---"
start extract R18EXT3 !
sh echo "--- Starting Extract X18T24P (Trail: pc) ---"
start extract X18T24P !

-- R25 Extracts
dblogin useridalias T24_RHS_26
sh echo "--- Starting Extract ET24P (Trail: hb) ---"
start extract ET24P !
sh echo "--- Starting Extract DS1EXT3 (Trail: ds) ---"
start extract DS1EXT3 !
sh echo "--- Starting Extract EXT24P (Trail: pc) ---"
start extract EXT24P !

sh sleep 10
info all
exit
EOF

# ===================================================================
# 4. Check Status and Output Verdict
# ===================================================================
echo ""
echo "======================================================================"
echo " VERIFYING PROCESS STATUS"
echo "======================================================================"

# Query process status into TMP_OUT
"${ADMINCLIENT_DB}" > "${TMP_OUT}" 2>&1 << 'EOF'
connect https://localhost:7801 as OGGHUB_CORELIVEDB
info all
exit
EOF

# Display formatted status output with colored status keywords
awk '
    /Program +Status +Group/ { show=1 }
    show {
        gsub(/STOPPED|ABENDED/, "\033[1;31m&\033[0m");
        gsub(/RUNNING/, "\033[1;32m&\033[0m");
        print;
    }
' "${TMP_OUT}"

# Count unique RUNNING target Extracts
EXT_RUNNING=$(awk '
    $1 == "EXTRACT" &&
    $2 == "RUNNING" &&
    (
        $3 == "R18T24P" ||
        $3 == "R18EXT3" ||
        $3 == "X18T24P" ||
        $3 == "ET24P"   ||
        $3 == "DS1EXT3" ||
        $3 == "EXT24P"
    ) {
        running[$3] = 1
    }
    END {
        for (name in running) count++
        print count + 0
    }
' "${TMP_OUT}")

EXPECTED_COUNT=6

echo "----------------------------------------------------------------------"
printf 'Expected Extracts: R18T24P, R18EXT3, X18T24P, ET24P, DS1EXT3, EXT24P | RUNNING: %s/%s\n' \
    "${EXT_RUNNING}" "${EXPECTED_COUNT}"

if [ "${EXT_RUNNING}" -eq "${EXPECTED_COUNT}" ]; then
    printf '\033[1;32m[VERDICT: PASS]\033[0m All %s expected OGGHUB Extracts are RUNNING.\n' \
        "${EXPECTED_COUNT}"
    exit 0
else
    printf '\033[1;31m[VERDICT: FAIL]\033[0m Expected %s RUNNING processes, found %s.\n' \
        "${EXPECTED_COUNT}" "${EXT_RUNNING}"
    exit 1
fi
