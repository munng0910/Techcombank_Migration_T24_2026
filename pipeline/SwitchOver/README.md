# GoldenGate operational actions — SwitchOver

Targeted Oracle GoldenGate Microservices operations for a selected environment and DC/DR host. This module belongs to the existing migration repository at `pipeline/SwitchOver`; it is not a separate Git repository.

**Scope:** start/stop an Extract, Replicat, deployment or ServiceManager. This is not a complete application/database switchover, failover, fencing or rollback workflow. Wildcards can affect objects beyond the Jenkins allowlist; review the selected scope before approving a build.

## Layout

```text
SwitchOver/
├── README.md
├── .gitignore
├── .gitattributes
├── jenkins/                 # Canonical operational pipeline template
├── scripts/                 # Operational actions and legacy setup/start helpers
├── config/
│   └── examples/pt.ini      # Sanitized, deliberately non-operational inventory
├── tests/
│   ├── ogg/                # Offline Bash harnesses with fake executables
│   └── test_publication.py  # Offline publication-boundary checks
├── docs/                    # Sanitized specifications and HTML operational guide
├── archive/                 # Policy for historical references
└── local/                   # IGNORED: real inventory and unmodified originals
```

## Maintained entry points

- [Operational Jenkinsfile](jenkins/Jenkinsfile_ogg_operational.groovy): validates and approves one selected action, sources the chosen host profile and runs the pre-deployed script through Ansible. It does not deploy scripts or provision AdminClient aliases.
- [Operational action script](scripts/op_ogg_actions.sh): supports `start_ext`, `stop_ext`, `start_rep`, `stop_rep`, `start_depl`, `stop_depl`, `start_sm` and `stop_sm`. Process actions verify the requested RUNNING/STOPPED state. Deployment actions report command completion, not independently verified deployment health; native ServiceManager actions report script/launcher completion, not independently verified service health.
- [Configuration contract](config/README.md): private inventory provisioning and example shape.
- [Pipeline requirements](docs/jenkins_ogg_operational_pipeline_requirements.md), [script specification](docs/ogg_operational_actions_script_specification.md), and [HTML guide](docs/report_ogg_operational_switchover.html).

The action script was renamed from `OGGHUB_operation_actions.sh` to `op_ogg_actions.sh` so its source and deployed basenames agree. The configured remote destination remains `/home/oracle/profile/op_ogg_actions.sh`; no remote files were changed by the workspace cleanup.

## Jenkins setup

1. Use **Pipeline script from SCM** with Script Path `pipeline/SwitchOver/jenkins/Jenkinsfile_ogg_operational.groovy` and the existing repository/branch. The pipeline enters `pipeline/SwitchOver` after checkout; generated playbooks and local inventory paths are relative to this module.
2. Replace the publication-template controller hostname matcher, node/Vault endpoints and AppRole credential IDs with approved environment values. Review site groups, Vault keys, deployment/process mappings, host profile paths and the required SSH account. The example Vault endpoints fail validation deliberately.
3. Provide a Jenkins **Secret file** credential named `ogg-inventory-<tier>-<environment>`, such as `ogg-inventory-dev-pt`, containing the approved real inventory. See [configuration](config/README.md). The former `jenkins/pt.ini` is preserved locally at `local/inventory/dev/pt.ini`, not committed or automatically consumed.
4. Configure the inherited `ansible` Kubernetes pod/container, Jenkins Kubernetes, Vault, Credentials Binding, ANSI Color, Workspace Cleanup and Active Choices integrations, plus normal script approvals. Do not relax controller security policy to enable UI decoration. Provision SSH host keys and Vault access separately.
5. Through the approved deployment process, install `scripts/op_ogg_actions.sh` at the configured remote path and provision readable Oracle/DAA profiles. Run it as the intended OS account with existing AdminClient aliases, GoldenGate access, Bash 4+ and GNU `timeout`. The build must be able to SSH as `localpwm` and sudo as `oracle`.
6. Initialize/refresh the job parameters, select the environment/site/profile/action and targets, then review the explicit confirmation. No live validation was performed as part of this directory cleanup.

For local, non-operational usage help only:

```bash
bash scripts/op_ogg_actions.sh --help
```

## Offline validation

Run from this module using Git Bash on Windows or Bash on Linux, with GNU `timeout` and standard Unix utilities available:

```bash
for script in scripts/*.sh tests/ogg/*.sh; do bash -n "$script" || exit; done
python -I tests/test_publication.py
bash tests/ogg/test_op_ogg_actions.sh
bash tests/ogg/test_op_ogg_wildcards.sh
```

Cleanup validation on Git Bash: **60 operational action tests passed** and **73 wildcard tests passed**, with zero failures in those suites. Shell syntax checks passed for all six script/harness files. This does not validate the Jenkinsfile on a real controller.

The operational harnesses create private temporary fixtures, clear ambient configuration and substitute fake AdminClient/native scripts. They do not connect to GoldenGate, Jenkins, Vault or Ansible hosts. On some Windows/Git Bash installations, native-launch/timeout behavior may differ from Linux; review failures rather than treating syntax checks as runtime qualification.

### Legacy helpers and known failing suite

`OGGHUB_Add-Extract_Add-Replicat.sh` and `OGGHUB_Start-Extract.sh` retain environment-specific topology and paths. They are not invoked by the maintained operational Jenkinsfile and are **not production-qualified by this cleanup**. The add helper can stop/delete/recreate configured processes after confirmation; the start helper starts its fixed Extract set. Never run either against live installations merely to validate directory moves.

The add helper now honors explicit AdminClient and log-directory overrides, and its harness clears inherited environment settings so it can run with sandbox fakes:

```bash
bash tests/ogg/test_ogghub_add_extract_replicat.sh
```

The existing add/setup contract does not match the implementation: the fake expects per-command calls while the script sends batches, and confirmation, detailed verification and summary expectations also differ. The isolated cleanup validation reported **0 passed, 26 failed** (exit 1). This is a known blocker, not a passing suite or a production qualification. Resolving it requires a separate, reviewed operational change rather than weakening the tests during workspace reorganization.

## Private originals and publication boundary

- Unmodified scripts, Jenkinsfiles, tests, historical workflow notes, authoring prompts, captured output and original report files are preserved under `local/originals/`. The real PT inventory is under `local/inventory/dev/`.
- Published documentation is a sanitized copy. Password-bearing examples were removed/replaced with credential-alias usage; original documents remain private. If any original values were real credentials and were previously exposed, follow the approved rotation process. Sanitizing this working tree does not revoke credentials or clean any external copies.
- `.gitignore` excludes `local/`, real INI files outside `config/examples/`, runtime output, generated operational playbooks/vars and report exports. `.gitattributes` enforces LF for shell, Groovy and maintained text files.
- Publication checks are a limited safeguard, not a security audit. Review topology, aliases and organizational identifiers before making any repository public. Ignored files are still present on disk; ignore rules are not encryption or access controls.
- Review and stage only this module's explicit file list. Do not use a repository-wide `git add .`: unrelated sibling materials and the duplicate workspace are outside this cleanup's scope.
