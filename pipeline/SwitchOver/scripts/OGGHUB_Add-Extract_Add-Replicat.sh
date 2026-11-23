#!/bin/bash
# OGGHUB_Add-Extract_Add-Replicat.sh
# Description: Idempotent setup for 6 Extracts & 6 Replicats (R18 & R25) with safe cleanup and status verdict.

set -euo pipefail

# 1. Variables for sequence numbers
hb_seqno=800000
ds_seqno=11000
pc_seqno=890000

# 2. Binary paths & Environment Setup
ADMINCLIENT_DB="${ADMINCLIENT_DB:-/u01/app/OracleGoldenGate/ogg_oracle/bin/adminclient}"
ADMINCLIENT_DAA="${ADMINCLIENT_DAA:-/u01/app/OracleGoldenGate/ogg_daa/bin/adminclient}"

LOG_DIR="${LOG_DIR:-/home/oracle/REHscript/log}"
LOG_FILE="${LOG_DIR}/OGGHUB_Add_Setup_$(date +%Y%m%d_%H%M%S).log"
TMP_OUT="${LOG_DIR}/ogghub_add_setup_$$.out"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Redirect stdout and stderr to both console and log file
exec > >(tee -a "${LOG_FILE}") 2>&1
trap 'rm -f "${TMP_OUT}"' EXIT

# Check if binaries exist and are executable
for bin in "${ADMINCLIENT_DB}" "${ADMINCLIENT_DAA}"; do
    if [ ! -x "${bin}" ]; then
        echo "Error: adminclient not found or not executable at ${bin}" >&2
        exit 1
    fi
done

echo "======================================================================"
echo " Starting OGGHUB Add Extract & Replicat Execution at $(date)"
echo " Log file: ${LOG_FILE}"
echo "======================================================================"

# ===================================================================
# PHASE 1: AUTOMATIC EXISTENCE CHECK & USER CONFIRMATION
# ===================================================================
echo -e "\n---> Phase 1: Checking for existing target processes on deployments..."

# Check existing Extracts on OGGHUB_CORELIVEDB
"${ADMINCLIENT_DB}" > "${TMP_OUT}" 2>&1 << 'EOF' || true
connect https://localhost:7801 as OGGHUB_CORELIVEDB
info all
exit
EOF

EXISTING_EXTS=$(awk '$1 ~ /EXTRACT|REPLICAT/ && $3 ~ /^(R18T24P|R18EXT3|X18T24P|ET24P|DS1EXT3|EXT24P)$/ {print $3}' "${TMP_OUT}" || true)

# Check existing Replicats on OGGHUB_DAA
"${ADMINCLIENT_DAA}" > "${TMP_OUT}" 2>&1 << 'EOF' || true
connect https://localhost:7901 as OGGHUB_DAA
info all
exit
EOF

EXISTING_REPS=$(awk '$1 ~ /EXTRACT|REPLICAT/ && $3 ~ /^(R18_DL1|R18_DL2|R18_DL3|RPLDS1|RPLDS2|RPLDS3)$/ {print $3}' "${TMP_OUT}" || true)

ALL_EXISTING=$(echo "${EXISTING_EXTS} ${EXISTING_REPS}" | xargs)

DO_CLEANUP="n"

if [ -n "${ALL_EXISTING}" ]; then
    echo -e "\n[WARNING] Detected existing target process(es): ${ALL_EXISTING}"
    read -p "Do you want to cleanup (stop & delete) these existing processes before adding? [y/N]: " USER_CONFIRM
    USER_CONFIRM=$(echo "${USER_CONFIRM:-n}" | tr '[:upper:]' '[:lower:]')
    if [ "${USER_CONFIRM}" = "y" ]; then
        DO_CLEANUP="y"
    fi
else
    echo "[INFO] No existing target processes detected. Skipping cleanup phase."
fi

# ===================================================================
# PHASE 2: CENTRALIZED CLEANUP (SAFE EXECUTION WITH || TRUE)
# ===================================================================
if [ "${DO_CLEANUP}" = "y" ]; then
    echo -e "\n============================ PHASE 2: CENTRALIZED CLEANUP ============================"
    
    echo "--- Cleaning up R18 & R25 Extracts on OGGHUB_CORELIVEDB ---"
    "${ADMINCLIENT_DB}" << EOF || true
connect https://localhost:7801 as OGGHUB_CORELIVEDB

-- Cleanup R18 Extracts
dblogin useridalias UNMASK19C
stop extract R18T24P !
delete extract R18T24P !
delete exttrail R18/hb !
stop extract R18EXT3 !
delete extract R18EXT3 !
delete exttrail R18/ds !
stop extract X18T24P !
delete extract X18T24P !
delete exttrail R18/pc !

-- Cleanup R25 Extracts
dblogin useridalias CORELIVE_DB
stop extract ET24P !
delete extract ET24P !
delete exttrail R25/hb !
stop extract DS1EXT3 !
delete extract DS1EXT3 !
delete exttrail R25/ds !
stop extract EXT24P !
delete extract EXT24P !
delete exttrail R25/pc !
exit
EOF

    echo "--- Cleaning up R18 & R25 Replicats on OGGHUB_DAA ---"
    "${ADMINCLIENT_DAA}" << EOF || true
connect https://localhost:7901 as OGGHUB_DAA

-- Cleanup R18 Replicats
stop replicat R18_DL1 !
delete replicat R18_DL1 !
stop replicat R18_DL2 !
delete replicat R18_DL2 !
stop replicat R18_DL3 !
delete replicat R18_DL3 !

-- Cleanup R25 Replicats
stop replicat RPLDS1 !
delete replicat RPLDS1 !
stop replicat RPLDS2 !
delete replicat RPLDS2 !
stop replicat RPLDS3 !
delete replicat RPLDS3 !
exit
EOF

# Centralized Cleanup completed.
    echo "[INFO] Centralized cleanup phase completed."
    sh sleep 2   # 2 seconds delay for Database/OGG to release all metadata
fi

# ===================================================================
# PHASE 3: ADD EXTRACTS & REPLICATS
# ===================================================================
echo -e "\n============================ PHASE 3: ADD PROCESSES ============================"

echo -e "\n--- Step 3.1: Adding Extracts for R18 (OGGHUB_CORELIVEDB) ---"
"${ADMINCLIENT_DB}" << EOF
connect https://localhost:7801 as OGGHUB_CORELIVEDB
dblogin useridalias UNMASK19C

sh echo "--- Adding Extract R18T24P (Trail: hb) ---"
add extract R18T24P integrated tranlog begin now
add exttrail R18/hb extract R18T24P megabytes 1024 seqno ${hb_seqno}
register extract R18T24P database

sh echo "--- Adding Extract R18EXT3 (Trail: ds) ---"
add extract R18EXT3 integrated tranlog begin now
add exttrail R18/ds extract R18EXT3 megabytes 1024 seqno ${ds_seqno}
register extract R18EXT3 database

sh echo "--- Adding Extract X18T24P (Trail: pc) ---"
add extract X18T24P integrated tranlog begin now
add exttrail R18/pc extract X18T24P megabytes 1024 seqno ${pc_seqno}
register extract X18T24P database

sh sleep 3
info all
exit
EOF

echo -e "\n--- Step 3.2: Adding Extracts for R25 (OGGHUB_CORELIVEDB) ---"
"${ADMINCLIENT_DB}" << EOF
connect https://localhost:7801 as OGGHUB_CORELIVEDB
dblogin useridalias CORELIVE_DB

sh echo "--- Adding Extract ET24P (Trail: hb) ---"
add extract ET24P integrated tranlog begin now
add exttrail R25/hb extract ET24P megabytes 1024 seqno ${hb_seqno}
register extract ET24P database

sh echo "--- Adding Extract DS1EXT3 (Trail: ds) ---"
add extract DS1EXT3 integrated tranlog begin now
add exttrail R25/ds extract DS1EXT3 megabytes 1024 seqno ${ds_seqno}
register extract DS1EXT3 database

sh echo "--- Adding Extract EXT24P (Trail: pc) ---"
add extract EXT24P integrated tranlog begin now
add exttrail R25/pc extract EXT24P megabytes 1024 seqno ${pc_seqno}
register extract EXT24P database

sh sleep 3
info all
exit
EOF

echo -e "\n--- Step 3.3: Adding Replicats for DAA R18 (OGGHUB_DAA) ---"
"${ADMINCLIENT_DAA}" << EOF
connect https://localhost:7901 as OGGHUB_DAA

sh echo "--- Adding Replicat R18_DL1 (Trail: pc, Seqno: ${pc_seqno}) ---"
add replicat R18_DL1 exttrail /ogghub-data/deployments/corelivedb/var/lib/data/R18/pc extseqno ${pc_seqno} extrba 0

sh echo "--- Adding Replicat R18_DL2 (Trail: hb, Seqno: ${hb_seqno}) ---"
add replicat R18_DL2 exttrail /ogghub-data/deployments/corelivedb/var/lib/data/R18/hb extseqno ${hb_seqno} extrba 0

sh echo "--- Adding Replicat R18_DL3 (Trail: pc, Seqno: ${pc_seqno}) ---"
add replicat R18_DL3 exttrail /ogghub-data/deployments/corelivedb/var/lib/data/R18/pc extseqno ${pc_seqno} extrba 0

sh sleep 3
info all
exit
EOF

echo -e "\n--- Step 3.4: Adding Replicats for DAA R25 (OGGHUB_DAA) ---"
"${ADMINCLIENT_DAA}" << EOF
connect https://localhost:7901 as OGGHUB_DAA

sh echo "--- Adding Replicat RPLDS1 (Trail: pc, Seqno: ${pc_seqno}) ---"
add replicat RPLDS1 exttrail /ogghub-data/deployments/corelivedb/var/lib/data/R25/pc extseqno ${pc_seqno} extrba 0

sh echo "--- Adding Replicat RPLDS2 (Trail: hb, Seqno: ${hb_seqno}) ---"
add replicat RPLDS2 exttrail /ogghub-data/deployments/corelivedb/var/lib/data/R25/hb extseqno ${hb_seqno} extrba 0

sh echo "--- Adding Replicat RPLDS3 (Trail: pc, Seqno: ${pc_seqno}) ---"
add replicat RPLDS3 exttrail /ogghub-data/deployments/corelivedb/var/lib/data/R25/pc extseqno ${pc_seqno} extrba 0

sh sleep 3
info all
exit
EOF

# ===================================================================
# PHASE 4: VERIFY PROCESS CREATION & OUTPUT VERDICT
# ===================================================================
echo ""
echo "======================================================================"
echo " PHASE 4: VERIFYING PROCESS STATUS"
echo "======================================================================"

{
    echo "=== OGGHUB_CORELIVEDB Status ==="
    "${ADMINCLIENT_DB}" << EOF
connect https://localhost:7801 as OGGHUB_CORELIVEDB
info all
exit
EOF

    echo -e "\n=== OGGHUB_DAA Status ==="
    "${ADMINCLIENT_DAA}" << EOF
connect https://localhost:7901 as OGGHUB_DAA
info all
exit
EOF
} > "${TMP_OUT}" 2>&1

# Highlight status keywords
awk '
    /Program +Status +Group/ { show=1 }
    show {
        gsub(/STOPPED|ABENDED/, "\033[1;31m&\033[0m");
        gsub(/RUNNING/, "\033[1;32m&\033[0m");
        print;
    }
' "${TMP_OUT}"

# Count added target processes (6 Extracts + 6 Replicats = 12 total created)
EXT_CREATED=$(awk '$1 == "EXTRACT" && ($2 == "STOPPED" || $2 == "RUNNING") && $3 ~ /^(R18T24P|R18EXT3|X18T24P|ET24P|DS1EXT3|EXT24P)$/ { count++ } END { print count + 0 }' "${TMP_OUT}")
REP_CREATED=$(awk '$1 == "REPLICAT" && ($2 == "STOPPED" || $2 == "RUNNING") && $3 ~ /^(R18_DL1|R18_DL2|R18_DL3|RPLDS1|RPLDS2|RPLDS3)$/ { count++ } END { print count + 0 }' "${TMP_OUT}")
TOTAL_CREATED=$((EXT_CREATED + REP_CREATED))

EXPECTED_COUNT=12

echo "----------------------------------------------------------------------"
if [ "${TOTAL_CREATED}" -eq "${EXPECTED_COUNT}" ]; then
    echo -e "\033[1;32m[VERDICT: PASS]\033[0m All ${EXPECTED_COUNT} target processes (6 Extracts & 6 Replicats) have been successfully added."
    exit 0
else
    echo -e "\033[1;31m[VERDICT: FAIL]\033[0m Creation verification failed! Found ${TOTAL_CREATED}/${EXPECTED_COUNT} added processes (Extracts: ${EXT_CREATED}/6, Replicats: ${REP_CREATED}/6)."
    exit 1
fi