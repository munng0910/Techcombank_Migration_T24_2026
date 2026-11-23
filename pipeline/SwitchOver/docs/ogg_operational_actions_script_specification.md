# Oracle GoldenGate Operational Actions Script Specification

## 1. Maintained interface and scope

The maintained implementation is [op_ogg_actions.sh](../scripts/op_ogg_actions.sh), invoked by [Jenkinsfile_ogg_operational.groovy](../jenkins/Jenkinsfile_ogg_operational.groovy). See the [pipeline requirements](jenkins_ogg_operational_pipeline_requirements.md) and [operational runbook](report_ogg_operational_switchover.html).

This specification consolidates the original updates: all eight start/stop actions are supported, deployment precedes credential alias, and ServiceManager actions accept no extra arguments. Historical examples with missing aliases or reversed argument order are superseded. Unmodified originals are retained only in ignored `local/originals/` as stale reference material, not active documentation.

The maintained action script has offline test coverage; that is not live OGG/Jenkins validation. Legacy add/start helper scripts are separate, not production-qualified, and are not an implementation of any missing add-script feature contract. Native ServiceManager actions do not invoke the legacy full cleanup/startup helper.

## 2. Hierarchy and argument matrix

ServiceManager manages deployments; a deployment provides the context for its Extract and Replicat processes. Broad infrastructure actions have a wider impact than process actions.

```text
bash op_ogg_actions.sh <start_ext|stop_ext|start_rep|stop_rep> <deployment> <credential_alias> <process>
bash op_ogg_actions.sh <start_depl|stop_depl> <deployment> <credential_alias>
bash op_ogg_actions.sh <start_sm|stop_sm>
```

| Action | Target | Arguments after action |
| :--- | :--- | :--- |
| `start_ext`, `stop_ext` | Extract | `<deployment> <credential_alias> <process>` |
| `start_rep`, `stop_rep` | Replicat | `<deployment> <credential_alias> <process>` |
| `start_depl`, `stop_depl` | Deployment | `<deployment> <credential_alias>` |
| `start_sm`, `stop_sm` | ServiceManager | None |

Use Bash explicitly, not `sh`. Angle-bracket syntax is descriptive, not a directly runnable command. The alias must already exist in the AdminClient credential store of the execution user. It is not a password or Jenkins credential ID.

### Input validation

Validate the action, exact argument count, required names and timeout/polling settings before executing operational commands. Accept literal `*` only for a process in one explicit deployment, or for the deployment of a deployment action. Reject empty or unsafe names, separators, partial patterns such as `EXT*`, wildcard credential aliases and wildcard deployments for process actions. Always quote `'*'` or escape it as `\*` to prevent shell filename expansion.

## 3. Independent execution examples

These are lookup examples, **not a batch or approved execution plan**. Entity names and aliases are illustrative. Choose only the action approved for the verified site and scope.

```bash
bash op_ogg_actions.sh start_ext ogg_oracle03 OGG_EXAMPLE_ALIAS EXT24P
bash op_ogg_actions.sh stop_ext ogg_oracle03 OGG_EXAMPLE_ALIAS EXT24P
bash op_ogg_actions.sh start_rep ogg_oracle03 OGG_EXAMPLE_ALIAS REP24P
bash op_ogg_actions.sh stop_rep ogg_oracle03 OGG_EXAMPLE_ALIAS REP24P
bash op_ogg_actions.sh start_depl ogg_oracle03 OGG_EXAMPLE_ALIAS
bash op_ogg_actions.sh stop_depl ogg_oracle03 OGG_EXAMPLE_ALIAS
bash op_ogg_actions.sh start_sm
bash op_ogg_actions.sh stop_sm
```

### Credential-alias AdminClient examples

The entire historical password-based CONNECT examples have been replaced. Authentication uses only an existing alias; never put passwords in commands, logs or documentation.

```text
CONNECT https://localhost:7801 DEPLOYMENT ogg_oracle03 AS OGG_EXAMPLE_ALIAS
STOP EXTRACT EXT24P
```

```text
CONNECT https://localhost:7801 DEPLOYMENT ogg_oracle03 AS OGG_EXAMPLE_ALIAS
STOP REPLICAT REP24P
```

```text
CONNECT https://localhost:7801 DEPLOYMENT ogg_oracle03 AS OGG_EXAMPLE_ALIAS
START EXTRACT EXT24P
```

```text
CONNECT https://localhost:7801 DEPLOYMENT ogg_oracle03 AS OGG_EXAMPLE_ALIAS
START REPLICAT REP24P
```

Deployment actions connect to ServiceManager rather than the target deployment:

```text
CONNECT https://localhost:7801 DEPLOYMENT ServiceManager AS OGG_EXAMPLE_ALIAS
START DEPLOYMENT ogg_oracle03
```

Use `STOP DEPLOYMENT ogg_oracle03` for the corresponding stop action. `localhost` is an example local endpoint, not a statement that it is correct for every deployment.

## 4. Execution workflow

```text
Validate inputs and configuration
  -> Initialize logging and acquire the action lock
  -> Route the selected action
     ServiceManager:
       start_sm -> launch native startSM.sh with nohup and detached I/O
                   -> check early launcher exit during OGG_SM_START_GRACE
       stop_sm  -> run native stopSM.sh with a command timeout
                   -> check native exit status
     Deployment:
       select AdminClient -> CONNECT to ServiceManager using alias
       -> START/STOP DEPLOYMENT -> check status and diagnostics
     Extract/Replicat:
       select AdminClient -> CONNECT to the explicit deployment using alias
       -> INFO ALL -> validate named target or snapshot of requested process type
       -> skip processes already at desired state
       -> issue explicit commands for remaining selected groups
       -> poll INFO ALL until all selected groups reach desired state
       -> fail on diagnostics, inventory changes or exhausted attempts
  -> Release only the owned lock and report cached observations
  -> Final summary: action, target, result, PASS/FAIL, exit code, log path
```

### AdminClient selection, authentication and TLS

- An explicit `ADMINCLIENT_BIN` overrides automatic selection.
- Otherwise a deployment matching `DAA_DEPLOYMENT` uses `ADMINCLIENT_DAA`; other deployments use `ADMINCLIENT_DB`.
- CONNECT uses `OGG_ENDPOINT` and an existing alias, non-interactively. No username/password is read or embedded by this script.
- TLS verification is enabled by default. Set the trusted CA using `OGG_CLIENT_TLS_CAPATH` in the same sourced-profile session when required. CA paths in examples must be replaced with an approved readable path.
- `OGG_INSECURE_TLS=true` appends `!` only when explicitly configured for an approved endpoint. It is not an automatic fallback for certificate failures.

```bash
export OGG_INSECURE_TLS=false
export OGG_CLIENT_TLS_CAPATH=/path/to/approved-ca.pem
bash op_ogg_actions.sh start_rep ogg_oracle03 OGG_EXAMPLE_ALIAS REP24P
```

### Native ServiceManager scripts

Defaults are `${SM_HOME}/bin/startSM.sh` and `${SM_HOME}/bin/stopSM.sh`. `OGG_START_SM_SCRIPT` and `OGG_STOP_SM_SCRIPT` may override the selected native paths. The script must be executable; **no alternative script names are probed**. The historical claim of a `start_sm.sh` fallback is obsolete.

Start uses `nohup`, detached stdin/stdout/stderr and a separate launcher log. Stop uses the command timeout and native exit status. Neither action runs the full legacy `start_ogg_services.sh` cleanup/startup procedure, verifies ServiceManager health independently, performs fencing or switches database roles.

## 5. Process state verification

| Actions | Desired state | Verification limit |
| :--- | :--- | :--- |
| `start_ext`, `start_rep` | `RUNNING` | `OGG_START_ATTEMPTS` |
| `stop_ext`, `stop_rep` | `STOPPED` | `OGG_STOP_ATTEMPTS` |

- A named target must return exactly one valid INFO ALL row for the expected program type and name.
- A wildcard snapshots all groups of the requested type. No matches, duplicate rows, malformed rows, unsafe names or unrecognized states fail before issuing process commands.
- Skip each group already at the desired state. If every selected group is already correct, pass without issuing start/stop commands.
- Expand a validated wildcard snapshot to explicit per-group commands in one AdminClient request. Do not send a raw process wildcard: already-correct groups and newly created groups must not receive unintended commands.
- After commands, verify every selected group. `OGG_POLL_INTERVAL` controls the delay between unsuccessful attempts. A change in the wildcard group set fails verification; do not silently add or discard targets.
- Query/command errors or failure to reach the state within the configured attempts produce nonzero status. No force-kill or automatic recovery is attempted.

## 6. Wildcard behavior and blast radius

```bash
# Independent examples: all Extracts in one deployment.
bash op_ogg_actions.sh start_ext ogg_oracle03 OGG_EXAMPLE_ALIAS '*'
bash op_ogg_actions.sh stop_ext ogg_oracle03 OGG_EXAMPLE_ALIAS '*'

# Independent examples: all Replicats in one deployment.
bash op_ogg_actions.sh start_rep ogg_daa03 OGG_EXAMPLE_ALIAS '*'
bash op_ogg_actions.sh stop_rep ogg_daa03 OGG_EXAMPLE_ALIAS '*'

# Independent examples: ALL deployments under the connected ServiceManager.
bash op_ogg_actions.sh start_depl '*' OGG_EXAMPLE_ALIAS
bash op_ogg_actions.sh stop_depl '*' OGG_EXAMPLE_ALIAS
```

For deployment wildcards, AdminClient receives `START DEPLOYMENT *` or `STOP DEPLOYMENT *` through the ServiceManager connection. The default binary is `ADMINCLIENT_DB` unless `ADMINCLIENT_BIN` overrides it. The alias needs ServiceManager permissions. Scope includes all deployments under that ServiceManager, not just Oracle/DAA deployments or Jenkins dropdown values. PASS reports request completion, not independently verified deployment state.

Bulk operations are not transactional: some targets may have changed before failure. Do not use an unquoted `*`, assume rollback, or automatically run the inverse wildcard on failure.

## 7. Configuration and prerequisites

Source the approved remote profile before invoking Bash. Confirm `SM_HOME`, OGG home/variable directories, the selected AdminClient binary, endpoint, alias and native script permissions. When selecting `adminclient` through PATH, include the approved OGG binary directory. Explicit binary settings take precedence as described above.

| Setting | Reference default / purpose |
| :--- | :--- |
| `OGG_ENDPOINT` | `https://localhost:7801`; configure the approved endpoint |
| `OGG_INSECURE_TLS` | `false` |
| `OGG_COMMAND_TIMEOUT` | `60` seconds per command |
| `OGG_START_ATTEMPTS`, `OGG_STOP_ATTEMPTS` | `15` each |
| `OGG_POLL_INTERVAL` | `2` seconds |
| `OGG_SM_START_GRACE` | `1` second; launcher check, not health verification |
| `LOG_DIR` | Normally `${OGG_VAR_HOME}/log`; approved profile may override |

These values are reference defaults, not an overall SLA. Confirm actual deployed script/profile settings. Logs normally follow `ogg_<action>_<YYYYmmdd_HHMMSS>_<PID>.log`; use the summary's actual path. ServiceManager start has an additional launcher log.

Real Jenkins inventory is provisioned by secret-file credential `ogg-inventory-<tier>-<environment>`, copied at runtime to module-local `local/inventory/<tier>/<environment>.ini` with `pipeline/SwitchOver` as the workspace working directory. This is separate from the AdminClient alias. See pipeline requirements for provisioning, target validation and example-only inventory policy.

## 8. Result handling and safety limits

| Action type | Meaning of PASS |
| :--- | :--- |
| Extract / Replicat | Named process or every process in the wildcard snapshot verified at desired `RUNNING`/`STOPPED` state |
| Deployment | AdminClient completed the request without detected errors; state not independently verified |
| ServiceManager start | Launcher remained active after grace period or completed with code zero; health not independently verified |
| ServiceManager stop | Native stop script completed with code zero; state not independently verified |

Runtime failures produce a FAIL summary where possible. Early validation may fail before logging is initialized. Cleanup releases only a lock owned by this invocation; never remove another invocation's lock. Exit/signal handlers report cached observations and do not query, start or stop services.

There is no automatic retry, rollback, cross-site fencing, database role switch or replication consistency guarantee. Assess actual process/deployment/service state after failures, timeouts or interruption. Store execution evidence only in approved internal systems after redaction; historical internal evidence links and actual endpoint addresses are deliberately absent from maintained documentation.
