# Oracle GoldenGate (OGG) Operational Actions Script Specification

## 1. Overview
This document specifies the operational design and execution structure for `op_ogg_actions.sh`. The script standardizes management actions for Oracle GoldenGate MicroServices Architecture (MA) deployments, processes (Extracts and Replicats), and the Service Manager.

---

## 2. Action Hierarchy & Mapping

The operational tasks follow a hierarchical structure where broader infrastructure actions host finer-grained process actions.

| Hierarchy Level | Action Key | Target Object | Parent Context | Description |
| :--- | :--- | :--- | :--- | :--- |
| **Level 1** | `stop_sm` | Service Manager | Root System | Gracefully stops the entire OGG Service Manager instance. |
| **Level 1** | `stop_depl` | Deployment | Service Manager | Stops a specific OGG deployment instance. |
| **Level 2** | `stop_ext` | Extract Process | Deployment | Connects to a specific deployment and stops a target Extract process. |
| **Level 2** | `stop_rep` | Replicat Process | Deployment | Connects to a specific deployment and stops a target Replicat process. |

---

## 3. Command Syntax & Arguments

### General Usage
```bash
sh op_ogg_actions.sh <action> <deployment_name> [process_name]
```

### Argument Matrix

| Parameter | Required / Optional | Valid Values | Description |
| :--- | :--- | :--- | :--- |
| `<action>` | Required | `stop_ext`, `stop_rep`, `stop_depl`, `stop_sm` | Operational action to execute. |
| `<deployment_name>` | Required for process/depl actions | e.g., `ogg_oracle03` | Target OGG deployment name. |
| `[process_name]` | Required for `stop_ext` / `stop_rep` | e.g., `EXT24P`, `REP01` | Name of the Extract or Replicat process. |

---

## 4. Execution Examples & Underlying Commands

### 4.1 Stop Extract (`stop_ext`)
Stops a specific Extract process within a designated deployment.

* **Execution Command:**
  ```bash
  sh op_ogg_actions.sh stop_ext ogg_oracle03 EXT24P
  ```
* **Internal Action:**
  Connects to AdminClient and runs:
  ```sql
  connect https://localhost:7801 deployment ogg_oracle03 as oggadmin password oracle_4U;
  stop extract EXT24P;
  ```

---

### 4.2 Stop Replicat (`stop_rep`)
Stops a specific Replicat process within a designated deployment.

* **Execution Command:**
  ```bash
  sh op_ogg_actions.sh stop_rep ogg_oracle03 REP24P
  ```
* **Internal Action:**
  Connects to AdminClient and runs:
  ```sql
  connect https://localhost:7801 deployment ogg_oracle03 as oggadmin password oracle_4U;
  stop replicat REP24P;
  ```

---

### 4.3 Stop Deployment (`stop_depl`)
Stops an entire target deployment.

* **Execution Command:**
  ```bash
  sh op_ogg_actions.sh stop_depl ogg_oracle03
  ```
* **Internal Action:**
  Executes deployment shutdown via Service Manager CLI/API or AdminClient:
  ```sql
  stop deployment ogg_oracle03
  ```

---

### 4.4 Stop Service Manager (`stop_sm`)
Stops the OGG Service Manager process.

* **Execution Command:**
  ```bash
  sh op_ogg_actions.sh stop_sm
  ```
* **Internal Action:**
  Uses the native `${SM_HOME}/bin/stopSM.sh` script. `OGG_STOP_SM_SCRIPT` can override the native script path. No alternative script names are probed.

---

## 5. Script Workflow Logic

This workflow reflects the current start/stop interface from **New update 2**. The deployment name comes **before** the credential alias.

### 5.1 Input Validation

| Action Type | Actions | Required Arguments After Action |
| :--- | :--- | :--- |
| Extract | `start_ext`, `stop_ext` | `<deployment_name> <credential_name> <process_name>` |
| Replicat | `start_rep`, `stop_rep` | `<deployment_name> <credential_name> <process_name>` |
| Deployment | `start_depl`, `stop_depl` | `<deployment_name> <credential_name>` |
| ServiceManager | `start_sm`, `stop_sm` | None |

The script validates the action, argument count, required names, and timeout/polling settings. A literal `*` is accepted as the process name for Extract/Replicat actions, or as the deployment name for deployment actions. Process actions still require one explicit deployment name, and credential aliases cannot be wildcards. Empty names, partial patterns such as `EXT*`, and command separators are rejected. Invalid input exits without executing an operational command. Always quote `'*'` or escape it as `\*` to prevent shell filename expansion.

### 5.2 Execution Flow

```text
[Validate input and configuration settings]
                    |
[Initialize logging and acquire the action lock]
                    |
[Route the requested action]
   |
   +-- ServiceManager actions (no AdminClient connection)
   |     |
   |     +-- start_sm
   |     |     -> Launch ${SM_HOME}/bin/startSM.sh using nohup
   |     |     -> Detach stdin/stdout/stderr; use a separate launcher log
   |     |     -> Check early launcher exit during OGG_SM_START_GRACE
   |     |
   |     +-- stop_sm
   |           -> Run ${SM_HOME}/bin/stopSM.sh with a command timeout
   |           -> Check the native script's exit status
   |
   +-- Deployment actions: start_depl / stop_depl
   |     -> Select AdminClient for the requested deployment
   |     -> CONNECT to ServiceManager AS <credential_name>
   |     -> Run START/STOP DEPLOYMENT <deployment_name>
   |     -> Check command exit status and error diagnostics
   |
   +-- Process actions: start_ext / stop_ext / start_rep / stop_rep
         -> Select AdminClient for the requested deployment
         -> CONNECT to <deployment_name> AS <credential_name>
         -> Query INFO ALL: select one named group, or snapshot all of the type for '*'
         -> Validate every selected process row before issuing commands
         -> Already at the desired state? Skip that group's start/stop command
         -> Otherwise, run explicit START/STOP commands for the selected groups
         -> Poll INFO ALL until every selected group reaches the desired state
         -> Fail on errors, inventory changes, or exhausted verification attempts
                    |
[Release the owned lock and report the cached result]
                    |
[Final summary: action, target, result, PASS/FAIL, exit code, log path]
```

**AdminClient selection and authentication:**
- An explicit `ADMINCLIENT_BIN` overrides automatic selection.
- Otherwise, a deployment matching `DAA_DEPLOYMENT` uses `ADMINCLIENT_DAA`; other deployments use `ADMINCLIENT_DB`.
- CONNECT uses `OGG_ENDPOINT` and an existing credential alias. No username/password is read or embedded by the script.
- CONNECT runs non-interactively. TLS verification is enabled by default; `OGG_INSECURE_TLS=true` appends `!` only when explicitly configured for an approved endpoint.

**Native ServiceManager scripts:** `OGG_START_SM_SCRIPT` and `OGG_STOP_SM_SCRIPT` can override the default paths above. The selected script must be executable; no alternative script names are probed. These actions do not run the full `start_ogg_services.sh` cleanup/startup procedure.

### 5.3 Process State Verification

| Actions | Desired State | Polling Limit |
| :--- | :--- | :--- |
| `start_ext`, `start_rep` | `RUNNING` | `OGG_START_ATTEMPTS` |
| `stop_ext`, `stop_rep` | `STOPPED` | `OGG_STOP_ATTEMPTS` |

- A named target must return exactly one valid INFO ALL row for its program type and process name. A wildcard target snapshots all groups of the requested type; no matches is an error. Duplicate, malformed, unsafe-name, or unrecognized rows fail the action before any start/stop command is issued.
- Groups already at the desired state are skipped. If all selected groups are already at the desired state, the action passes without issuing start/stop commands.
- For a wildcard, the script expands the validated snapshot into explicit per-group commands in one AdminClient request. It does not send a raw process wildcard, so already-correct groups and newly created groups do not receive unintended commands.
- After issuing commands, the script verifies every selected group. `OGG_POLL_INTERVAL` controls the delay between unsuccessful verification attempts. A wildcard request fails if the set of groups changes during verification; it does not silently add or discard targets.
- Query/command errors or failure to reach the desired state within the configured attempts produce a nonzero exit status. No force-kill or automatic recovery is attempted.

### 5.4 Result Handling

| Action Type | Meaning of PASS |
| :--- | :--- |
| Extract / Replicat | The named process, or every process in the wildcard snapshot, was verified at the desired `RUNNING` or `STOPPED` state. |
| Deployment | AdminClient completed the start/stop request without detected errors; deployment state is not independently verified. |
| ServiceManager start | The native launcher remained active after the grace period or completed with exit code zero; ServiceManager health is not independently verified. |
| ServiceManager stop | The native stop script completed with exit code zero; ServiceManager state is not independently verified. |

Runtime failures produce a FAIL summary where possible. Cleanup releases only a lock acquired by the current invocation; it never removes another invocation's lock. Exit/signal handlers report cached observations and do not query, start, or stop services. Bulk operations are not transactional: some targets may have changed before a failure, and no automatic rollback is attempted.

### 5.5 Wildcard Examples

```bash
# All Extracts in one deployment.
sh op_ogg_actions.sh start_ext ogg_oracle03 OGGHUB_CORELIVE '*'
sh op_ogg_actions.sh stop_ext ogg_oracle03 OGGHUB_CORELIVE '*'

# All Replicats in one deployment.
sh op_ogg_actions.sh start_rep ogg_daa03 DAAC '*'
sh op_ogg_actions.sh stop_rep ogg_daa03 DAAC '*'

# All deployments managed by the connected ServiceManager.
sh op_ogg_actions.sh start_depl '*' OGGHUB_CORELIVE
sh op_ogg_actions.sh stop_depl '*' OGGHUB_CORELIVE
```

For deployment wildcards, AdminClient receives `start deployment *` or `stop deployment *` through the ServiceManager connection. The default binary is `ADMINCLIENT_DB`, unless `ADMINCLIENT_BIN` is explicitly configured. The credential alias must have the required ServiceManager permissions. Deployment wildcards affect all matching deployments, not just the DB or DAA deployment, and report command completion rather than independently verified deployment state.

Do not use an unquoted `*`: the shell may replace it with local filenames before the script can validate the arguments. Process actions do not support a wildcard deployment or partial process patterns.

---

## 6. Prerequisites & Configuration

1. **Environment Variables:**
   - `OGG_HOME` or `OGG_ETC_HOME` must be set.
   - `PATH` must include `$OGG_HOME/bin` for `adminclient`.
2. **Credentials & Endpoint:**
   - Endpoint: `https://localhost:7801` (or configured via environment parameter).
   - Administrative User: `oggadmin`
   - Password management: Recommend using a secure store / wallet instead of plain text passwords where applicable.


# New update 1:
We should avoid to use hardcode password in script, so we will change to user alias to connect to deployment.

## 1.1. General Usage
```bash
sh op_ogg_actions.sh <action> <credential_name> <deployment_name> [process_name]
```

### Argument Matrix

| Parameter | Required / Optional | Valid Values | Description |
| :--- | :--- | :--- | :--- |
| `<action>` | Required | `stop_ext`, `stop_rep`, `stop_depl`, `stop_sm` | Operational action to execute. |
| `<deployment_name>` | Required for process/depl actions | e.g., `ogg_oracle03` | Target OGG deployment name. |
| `<credential_name>` | Required for process/depl actions | e.g., `OGGHUB_CORELIVE` | Credential name. |
| `[process_name]` | Required for `stop_ext` / `stop_rep` | e.g., `EXT24P`, `REP01` | Name of the Extract or Replicat process. |

---

## 1.2. Execution Examples & Underlying Commands

### Stop Extract (`stop_ext`)
Stops a specific Extract process within a designated deployment.

* **Execution Command:**
  ```bash
  sh op_ogg_actions.sh stop_ext OGGHUB_CORELIVE ogg_oracle03 EXT24P
  ```
* **Internal Action:**
  Connects to AdminClient and runs:
  ```sql
  connect https://localhost:7801 deployment ogg_oracle03 as OGGHUB_CORELIVE;
  ```


# New update 2:
You miss my action -.-. In the script currently just have stop actions, I need start actions also. I will update the `Argument Matrix`.

Other one, I will input `credential_name` after `deployment_name` in `General Usage` (review 1.1 - General Usage)

This update supersedes the argument order and action list in the earlier sections. Both `start_sm` and `stop_sm` take only the action argument; they use the native ServiceManager scripts and do not require a deployment or credential alias.

## 1.1. General Usage
```bash
sh op_ogg_actions.sh <action> <deployment_name> <credential_name> [process_name]
```

### Argument Matrix

| Parameter | Required / Optional | Valid Values | Description |
| :--- | :--- | :--- | :--- |
| `<action>` | Required | `stop_ext`, `stop_rep`, `stop_depl`, `stop_sm`, `start_ext`, `start_rep`, `start_depl`, `start_sm` | Operational action to execute. |
| `<deployment_name>` | Required for process/depl actions | e.g., `ogg_oracle03` | Target OGG deployment name. |
| `<credential_name>` | Required for process/depl actions | e.g., `OGGHUB_CORELIVE` | Existing AdminClient credential alias. |
| `[process_name]` | Required for `start_ext` / `stop_ext` / `start_rep` / `stop_rep` | e.g., `EXT24P`, `REP01` | Name of the Extract or Replicat process. |

---

## 1.2. Execution Examples & Underlying Commands

### Start Extract (`start_ext`)
Starts a specific Extract process within a designated deployment.

* **Execution Command:**
  ```bash
  sh op_ogg_actions.sh start_ext ogg_oracle03 OGGHUB_CORELIVE EXT24P
  ```
* **Internal Action:**
  ```sql
  connect https://localhost:7801 deployment ogg_oracle03 as OGGHUB_CORELIVE
  start extract EXT24P
  ```

### Start Replicat (`start_rep`)
Starts a specific Replicat process within a designated deployment.

* **Execution Command:**
  ```bash
  sh op_ogg_actions.sh start_rep ogg_daa03 OGGHUB_CORELIVE RKKPL01
  ```
* **Internal Action:**
  ```sql
  connect https://localhost:7801 deployment ogg_daa03 as OGGHUB_CORELIVE
  start replicat RKKPL01
  ```

### Start Deployment (`start_depl`)
Starts an entire target deployment.

* **Execution Command:**
  ```bash
  sh op_ogg_actions.sh start_depl ogg_oracle03 OGGHUB_CORELIVE
  ```
* **Internal Action:**
  Connects to ServiceManager and starts the target deployment:
  ```sql
  connect https://localhost:7801 deployment ServiceManager as OGGHUB_CORELIVE
  start deployment ogg_oracle03
  ```

---

### Start Service Manager (`start_sm`)
Starts the OGG Service Manager process.

* **Execution Command:**
  ```bash
  sh op_ogg_actions.sh start_sm
  ```
* **Internal Action:**
  Uses the native `${SM_HOME}/bin/startSM.sh` script, falling back to `${SM_HOME}/bin/start_sm.sh`. `OGG_START_SM_SCRIPT` can override the native script path. Startup uses `nohup` with detached input/output, following `start_ogg_services.sh`; it does not run that full startup/cleanup script. The summary reports launch acceptance or native script completion, not independently verified ServiceManager health.

---