# Oracle GoldenGate startup orchestration

Operator-triggered startup of Oracle GoldenGate Microservices on one selected DC
or DR node, using Jenkins, Ansible, and a pre-deployed Bash script.

> **Operational warning:** the script stops existing services before starting them.
> This is not automatic failover, site fencing, or a deployment tool. An operator
> must choose the correct site and coordinate any opposite-site shutdown.

## Project layout

```text
.github/workflows/offline-checks.yml      Offline-only CI
scripts/start_ogg_services.sh             Linux startup and health verification
jenkins/Jenkinsfile_run_start_service.groovy
                                         Jenkins entry point
inventory/                               Inventory contract and sanitized example
docs/workflow.md                         Execution flow and setup details
tests/ogg/                               Offline Python and Groovy checks
requirements-dev.txt                     Python test dependencies
local/                                   Ignored operational originals; not shared
```

The startup script's repository location is now `scripts/start_ogg_services.sh`.
Its location on the target VMs is independent: configure the deployed absolute
path for each site in the Jenkinsfile. Jenkins does **not** upload the script.

## How it works

1. Resolve the environment and the explicitly selected DC or DR site.
2. Create the inherited `ansible` pod and check out SCM.
3. Validate the selection, deployed script path, and canonical inventory.
4. Read only the selected node's SSH password from Vault and request confirmation.
5. Validate the selected inventory group locally, connect as `localpwm`, become
   `oracle`, verify the effective identity, and execute the pre-deployed script.
6. Propagate failures and remove the generated playbook/variables files.

See [the workflow](docs/workflow.md) for the exact contracts and limitations.

## Configure before running

This checkout is a shareable template, **not a ready-to-run environment**.

- **Jenkins:** configure the Vault URLs, AppRole credential IDs, production
  controller matcher, cluster choices, and DC/DR `SITES` script paths in the
  [Jenkinsfile](jenkins/Jenkinsfile_run_start_service.groovy). Endpoints and IDs
  were replaced with examples; the original is preserved locally.
- **Inventory:** follow [inventory setup](inventory/README.md). Real inventories
  must be supplied to the Jenkins checkout through an approved private mechanism.
  Ignored files on a workstation are not included in `checkout scm`.
- **Target VMs:** review the script's GoldenGate paths, deployments, ports,
  process groups, and Linux prerequisites, then deploy it independently to both
  approved nodes. A site selection does not rewrite the Bash configuration.
- **Application credentials:** the script now requires `OGG_ADMIN_PASSWORD` in
  the **remote oracle execution environment**. `OGG_ADMIN_USER` defaults to
  `oggadmin`. Provision this through an approved secret mechanism, for example a
  protected Oracle login-environment setup verified with your sudo configuration.
  The Jenkins Vault binding supplies the SSH/sudo password only; it does not
  forward or provision these application credentials. Missing/empty application
  passwords fail before service operations. Do not put passwords in Git,
  command-line arguments, or shell tracing.
- **Jenkins job:** use this repository's root as the workspace and set Script
  Path to `jenkins/Jenkinsfile_run_start_service.groovy`.

No services should be started just to validate this reorganization.

## Offline validation

Requirements: Python 3.10+, PyYAML, Jinja2, Bash 4+, and Groovy with a compatible
JDK. Run from the repository root:

```sh
python -m pip install -r requirements-dev.txt
python -I -B tests/ogg/test_start_ogg_contract.py -v
python -I -B tests/ogg/test_startup_credentials.py -v
groovy tests/ogg/validate_start_service.groovy
bash -n scripts/start_ogg_services.sh
```

On Windows, use Git Bash for the Bash check and credential-block tests. The
credential tests skip their shell cases when Bash is unavailable. Python can
also be run from PowerShell. The Groovy harness accepts an optional workspace
path when invoked outside this directory.

The checks use mocks and isolated credential definitions, not real SSH, Vault,
Ansible, or GoldenGate actions. GitHub Actions runs the same offline checks;
real Jenkins/Ansible integration and service startup require separate validation.

## Preserved local material

Existing operational files were retained under ignored `local/`:

- `originals/`: the pre-reorganization startup script, startup Jenkinsfile, and
  Groovy harness;
- `orig/`: the original backup script and captured output;
- `pt.ini`: original inventory;
- `Jenkinsfile_t24_dba_new.groovy`: historical DBA reference pipeline;
- `prompt.md`: historical requirements, including superseded instructions.

These files may contain credentials, private addresses, or operational details.
They are **not** part of the shareable project. The DBA reference is not imported
by the active startup pipeline and its unrelated playbooks are not included here.
If a separate Jenkins job used its old path, update that job deliberately; the
reference has not been repackaged as a runnable job in this repository.

## Prepare a GitHub push

Before any upload:

1. Confirm that you are authorized to publish the code and retained operational
   identifiers. Use a private repository unless public release is approved.
2. Rotate any real credentials that were embedded in the original scripts, using
   your normal change process. Removing them from this copy does not rotate them.
3. Review `.gitignore`, then inspect exactly what Git would add. Never force-add
   `local/`, credentials, logs, or real inventory.
4. Choose a license only if you have permission to license this code. No license
   was selected automatically.

The local repository can be initialized on `main` without creating a commit. When
ready, use these commands yourself (skip initialization if already initialized):

```sh
git init -b main
git add --dry-run .
git status --short --ignored
# After reviewing every candidate file:
git add .
git diff --cached --stat
git diff --cached
# Continue only after the staged diff has been checked for sensitive data.
git commit -m "Organize GoldenGate startup project"
git remote add origin <your-github-repository-url>
git push -u origin main
```

A new remote repository should be empty to avoid unrelated-history conflicts.
No GitHub repository, commit, remote, or push is created by the reorganization.
