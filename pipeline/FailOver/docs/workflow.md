# GoldenGate startup workflow

The entry point is [the startup Jenkinsfile](../jenkins/Jenkinsfile_run_start_service.groovy).
The host-side implementation is [the Bash script](../scripts/start_ogg_services.sh).
It must be deployed separately; checkout does not install it on either VM.

The historical DBA reference is retained only at ignored
`local/Jenkinsfile_t24_dba_new.groovy`. It is not a dependency of this job.

## 1. Resolve configuration before creating the pod

The Jenkinsfile defines controller classification, Vault URLs and AppRole IDs,
cluster choices, and the `SITES` mapping before calling `podTemplate`.

The published values are examples. Configure the production-controller matcher,
Vault settings, and script paths before enabling this job. The controller branch
selects `prod` or `dev`; the job parameters select an allowed `ENVIRONMENT` and an
explicit `TARGET_SITE` of DC or DR. Other controllers currently follow the dev
branch, as in the original workflow; this is not a controller allowlist.

Inventory is resolved relative to the SCM root:

```text
inventory/database/t24/<prod|dev>/<ENVIRONMENT>.ini
```

| Site | Inventory group | Selected Vault field |
| --- | --- | --- |
| DC | `ogg_DC` | `oggnode1_ansible_password` |
| DR | `ogg_DR` | `oggnode2_ansible_password` |

The Vault path is `kv2/ogg/<ENVIRONMENT>/secret`. Only the selected site's key is
probed and read. Missing selected credentials fail the job; there is no fallback
to the other site, and the other site's key is not required.

## 2. Execute the Jenkins workflow

1. `podTemplate(inheritFrom: 'ansible')`, then `node(POD_LABEL)` and ANSI color.
2. Clean the workspace and `checkout scm`.
3. Validate environment/site, the deployed absolute script path, and inventory
   presence. `/path/to/...` placeholders are rejected.
4. Build the selected secret binding using `checkVaultExists`/`buildOggSecrets`.
   Interruptions are propagated rather than treated as missing credentials.
5. Bind the selected password as `PASS_OGG` using KV-v2 `withVault`.
6. Ask the operator to confirm the chosen environment, site, and remote script.
7. Inside `container('ansible')`, generate `start_ogg_services.yml` and
   `temp_vars.yml`, run Ansible, and remove both files in `finally`.

The first build may initialize job parameters and stop until valid selections are
provided. `ONNODE` is a classification/logging value; execution uses the inherited
pod, not a separate `node(ONNODE)` allocation.

See [inventory provisioning](../inventory/README.md): a clean SCM checkout does
not contain ignored workstation inventories. Supply the real inventory through
an approved private integration before validation; this template does not
implement that environment-specific provisioning step.

## 3. Validate locally, then target exactly one site

The generated playbook has two plays:

- **Pod-local validation:** reject check mode and invalid inputs; require the
  selected group to contain exactly one host; require SSH as `localpwm`.
- **Remote execution:** connect only to that group, become `oracle` via sudo
  with `-H -S -i`, check `id -un`, and execute
  `/bin/bash -- <deployed-absolute-script-path>`. Report output and preserve
  nonzero failure status.

The generated invocation is equivalent to:

```sh
ansible-playbook -i <canonical-inventory> -e @temp_vars.yml \
  --limit '<selected-OGG-group>,localhost' start_ogg_services.yml
```

`localhost` is only the pod-local validation play. Neither database hosts nor the
unselected OGG site is targeted. Empty/missing groups fail rather than reporting a
successful no-op. Do not use a real Ansible invocation, even with `--check`, as an
offline layout test; the playbook rejects check mode.

## 4. Credentials and prerequisites

Generated variables contain lookup expressions, not literal passwords:

```yaml
ogg_ansible_password: "{{ lookup('env', 'PASS_OGG') }}"
ansible_become_password: "{{ ogg_ansible_password }}"
```

The selected inventory host uses that alias for the `localpwm` SSH password. If
sudo prompts, the same password is supplied; NOPASSWD also works. No separate
Oracle OS password or GoldenGate application password is fetched by Jenkins.

The shareable Bash script no longer contains an application password. Before
deployment, arrange for `OGG_ADMIN_PASSWORD` (required) and `OGG_ADMIN_USER`
(optional; defaults to `oggadmin`) to be exported in the remote `oracle` execution
environment. Verify this with your login/sudo policy; a secret in the Jenkins pod
is not automatically available remotely. The script rejects a missing/empty
password before startup, without a hard-coded fallback, and disables shell tracing
before building connection strings. Use credentials compatible with the existing
Admin Client connection syntax; quoting/escaping behavior was not redesigned.

Required infrastructure:

- Jenkins Kubernetes pod/container template named `ansible`, plus Active Choices,
  HashiCorp Vault, Workspace Cleanup, and ANSI Color support.
- Ansible, its SSH transport dependencies, and trusted SSH host keys in the pod.
  The shared inventory example requires host-key checking. The preserved original
  inventory disabled it; that policy is not silently copied into the example.
- Linux targets with Bash 4+, compatible Python for Ansible, sudo, and permission
  for `localpwm` to become `oracle`. A rule permitting only literal `sudo su - oracle`
  may not authorize Ansible's become invocation.
- GoldenGate paths, ports, deployments, and required process groups reviewed in
  the script. Environment/site choices do not rewrite that host configuration.

## 5. Operational boundaries

The script stops existing services before restarting and verifying them. Operators
must handle the opposite site's shutdown/fencing separately. This job provides
no automatic failover, cross-job lock, fencing, or automatic retry.
`disableConcurrentBuilds()` prevents overlap only within this Jenkins job.

The GitHub-oriented changes move the script into `scripts/`, replace embedded
application credentials with environment inputs, and replace internal Jenkins/
Vault connection settings with examples. The startup and health-check sequence
is otherwise retained. Pre-change operational copies are preserved under ignored
`local/`; treat them as sensitive, not as deployable public examples.

## 6. Offline checks

From the repository root:

```sh
python -m pip install -r requirements-dev.txt
python -I -B tests/ogg/test_start_ogg_contract.py -v
python -I -B tests/ogg/test_startup_credentials.py -v
groovy tests/ogg/validate_start_service.groovy
bash -n scripts/start_ogg_services.sh
```

The Python contract suite evaluates generated YAML/Jinja and guards. The credential
suite executes only the isolated credential-definition block with dummy values,
never the startup script. The Groovy harness mocks the workflow, success cases,
and failures without real pods, SCM, Vault, approvals, Ansible, SSH, or services.
Full Jenkins/Ansible integration and operational startup validation remain separate.
