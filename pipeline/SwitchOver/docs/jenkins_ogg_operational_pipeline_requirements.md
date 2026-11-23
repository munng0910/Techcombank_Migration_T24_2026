# Jenkins Pipeline Specification: OGG Operational Tasks

## 1. Scope and maintained sources

The maintained pipeline is [Jenkinsfile_ogg_operational.groovy](../jenkins/Jenkinsfile_ogg_operational.groovy). It runs one action from [op_ogg_actions.sh](../scripts/op_ogg_actions.sh) on one selected **DC** or **DR** host per build. See the [script specification](ogg_operational_actions_script_specification.md) and [operational runbook](report_ogg_operational_switchover.html).

This module remains part of its parent repository; the SCM root is not a separate SwitchOver repository. Generated workspace files use `pipeline/SwitchOver` as their working directory after checkout.

Historical startup workflows, versioned Jenkinsfiles, prompts, report instructions, DOCX reports and original documents are retained only in ignored `local/originals/`. They are stale references, not maintained deployment instructions. Legacy add/start helper scripts are not production-qualified; this operational pipeline specification does not implement or certify their separate feature contracts. Offline checks for the maintained action script do not establish production readiness or successful live Jenkins/OGG execution.

## 2. Selection workflow and eight actions

Require explicit valid `ENVIRONMENT`, `TARGET_SITE` (`DC` or `DR`), `OGG_ENV_PROFILE` and `OGG_ACTION` selections. Profile selects the approved Oracle or DAA environment on the selected host. A profile or site selection does not itself change database roles or fence another site.

| Action | Deployment | Credential alias | Process input |
| :--- | :--- | :--- | :--- |
| `start_ext`, `stop_ext` | One explicit deployment | Required | `EXTRACT`: one group or literal `*` |
| `start_rep`, `stop_rep` | One explicit deployment | Required | `REPLICAT`: one group or literal `*` |
| `start_depl`, `stop_depl` | One deployment or literal `*` | Required | None |
| `start_sm`, `stop_sm` | None | None | None |

The current interface passes deployment **before** the alias. Earlier requirements allowed named start-process selection without an explicit deployment; an implementation may resolve a unique deployment from its declared mapping, but it must reject ambiguity and display the resolved deployment before confirmation. The script always receives an explicit deployment for a process action.

Maintain environment/site-scoped lists of deployments, Extracts, Replicats and existing AdminClient credential aliases. Example entity names such as `ogg_oracle03`, `EXT24P`, `REP24P` and `OGG_EXAMPLE_ALIAS` are illustrative, not proof that any deployment exists or is approved for execution. Backend validation must enforce valid combinations independently of UI visibility.

### Dynamic dropdown visibility

- Process actions: show deployment, alias and the matching Extract or Replicat selector.
- Deployment actions: hide Extract and Replicat selectors; keep deployment and alias.
- ServiceManager actions: hide deployment, alias, Extract and Replicat selectors; keep environment/site/profile/action.
- Ignore irrelevant hidden inputs rather than turning stale UI selections into operational arguments.

## 3. Inventory provisioning and workspace paths

Real inventories must **not** be committed. Provision each environment's inventory as a Jenkins **secret-file credential** using the final ID:

```text
ogg-inventory-<tier>-<environment>
```

For example, the credential ID for tier `dev` and environment `pt` is `ogg-inventory-dev-pt`. Tier comes from the configured Jenkins controller classification; it is not inferred from an arbitrary environment label or an independently selectable production override.

After SCM checkout, bind only the selected tier/environment's secret-file credential and copy its file at runtime into the module-relative path:

```text
local/inventory/<tier>/<environment>.ini
```

The workspace working directory for that copy, generated playbooks, variables files and Ansible execution is **`pipeline/SwitchOver`**. Thus the parent-workspace path is `pipeline/SwitchOver/local/inventory/<tier>/<environment>.ini`, not an inventory path relative to the SCM root. Restrict access to the copied file, keep it out of source control and build artifacts, and clean up generated files according to the pipeline's lifecycle policy. Do not print the inventory contents or credential file path supplied by Jenkins into evidence.

Validate the selected inventory and site group before any remote operation:

| Selection | Required group | Target |
| :--- | :--- | :--- |
| DC | `ogg_DC` | Exactly one approved host |
| DR | `ogg_DR` | Exactly one approved host |

The selected host must use the approved SSH account (`localpwm`), then sudo/become `oracle` and verify `id -un`. Inventory must supply the actual address, SSH port and approved host-key policy. Retrieve only the chosen site's SSH/sudo secret through the pipeline's configured secret integration; do not fall back to the opposite site or credential.

[config/examples/pt.ini](../config/examples/pt.ini) is a non-routable example only. Its `.invalid` hostnames and environment password lookups are not production connection settings, not a fallback inventory, and not evidence that a runtime host has been resolved. Supply real inventory through the Jenkins credential above.

## 4. Authentication, remote prerequisites and TLS

- `CREDENTIAL_NAME` is an **existing AdminClient credential-store alias**, not a Jenkins credential ID and not a username/password. Its store must be available to the actual `oracle` execution context.
- Deploy the maintained script to the approved remote location before running the job. Jenkins invokes it; this operational job does not implicitly upload scripts or provision aliases.
- Source the approved OGG profile and invoke the script using **Bash in the same session**. Validate the profile, AdminClient binary, ServiceManager native scripts and permissions on the selected host.
- Keep `OGG_INSECURE_TLS=false` by default. Export the trusted CA path in the execution session when verified TLS requires it. The CA path below is illustrative.

```bash
export OGG_INSECURE_TLS=false
export OGG_CLIENT_TLS_CAPATH=/path/to/approved-ca.pem
bash /home/oracle/profile/op_ogg_actions.sh start_rep ogg_oracle03 OGG_EXAMPLE_ALIAS REP24P
```

`OGG_INSECURE_TLS=true` removes the need to provide a CA solely for that bypass, but disables certificate verification. Permit it only for an explicitly approved endpoint and change; do not use it as an automatic response to a TLS failure. Example endpoints must use localhost or non-routable `.invalid` names, never real internal URLs in maintained documentation.

## 5. Literal wildcard handling

Allow a literal `*` only as a process selector for Extract/Replicat actions in one explicit deployment, or as a deployment selector for deployment actions. Do not allow alias wildcards, wildcard deployment for process actions or partial patterns such as `EXT*`.

```bash
# Independent examples, not a sequence to execute.
bash /home/oracle/profile/op_ogg_actions.sh stop_rep ogg_oracle03 OGG_EXAMPLE_ALIAS '*'
bash /home/oracle/profile/op_ogg_actions.sh start_depl '*' OGG_EXAMPLE_ALIAS
```

The pipeline must pass `*` as **one literal shell argument**, not allow filesystem expansion or include the quote characters in the process name. Confirm the full blast radius before execution: a deployment wildcard affects every deployment managed by the connected ServiceManager, not just declared dropdown values. Process wildcard behavior and validation are defined in the script specification.

## 6. Approval, execution and acceptance

Validate and resolve selections, display the site/profile/host scope and exact action arguments, require explicit approval, then execute only the selected site's action. Runtime inventory/secret checks must still pass even when approval occurs earlier. Missing inventory credentials, invalid groups, unavailable secrets or mismatched execution user must fail closed.

Use job-level concurrency protection plus the action script's lock; neither provides cross-job/cross-site fencing. Preserve nonzero exit codes and do not automatically retry operational commands. On failure or timeout, assess actual host/process state before a new run.

Accept the result only with its documented limits:

- Extract/Replicat PASS: every selected process was verified at the desired state.
- Deployment PASS: request completion, not independent deployment health verification.
- ServiceManager PASS: native script/launcher acceptance, not independent ServiceManager health verification.
- No result alone proves replication consistency, database role transition or completed switchover.

Record revision, non-sensitive inputs, approval, summary/exit code, controlled log locations and independent post-checks in the approved internal change system. Never publish passwords, tokens, secret-file content, private endpoints or historical internal evidence URLs. No automatic rollback is implied by this specification.
