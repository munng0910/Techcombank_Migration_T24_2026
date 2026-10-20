# Inventory configuration

The startup pipeline reads inventory relative to the SCM workspace root:

```text
inventory/database/t24/dev/pt.ini
inventory/database/t24/dev/sit.ini
inventory/database/t24/dev/techupgrade.ini
inventory/database/t24/prod/corelive1a.ini
inventory/database/t24/prod/corelive1b.ini
```

Only [a sanitized development example](database/t24/dev/pt.ini.example) is included.
Its RFC 5737 addresses are not operational targets. Actual `*.ini` inventories in
this directory are ignored by Git. The original local inventory is preserved at
`local/pt.ini` and is not a publishable sample.

## Required contract

- `ogg_DC` and `ogg_DR` each contain exactly one distinct host.
- Both hosts use SSH as `localpwm`; set `ansible_user` directly or through a parent group.
- Each selected host uses `ansible_password="{{ ogg_ansible_password }}"`.
- The pipeline binds only the selected node's Vault key to `PASS_OGG` and generates
  the `ogg_ansible_password` lookup. Do not put literal passwords in inventory.
- Configure host-key verification using trusted keys available to the Ansible pod.
  The shared example requires verification; the preserved original disabled it.

## Jenkins provisioning

The pipeline calls `cleanWs()` and `checkout scm`. Creating an ignored inventory
only on a workstation or manually in the Jenkins workspace will **not** make it
available after a clean checkout. Before enabling this job, arrange approved
inventory provisioning **after checkout and before validation**, or merge this
project into a private infrastructure checkout that already supplies these paths.
Such provisioning is environment-specific and is not implemented here. Do not
force-add operational inventories to a public repository to work around this.

Without the selected real inventory, the pipeline intentionally fails before
Vault lookup and service execution. There is no fallback to the example file.
