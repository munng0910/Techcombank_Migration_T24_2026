# Configuration

`examples/pt.ini` documents the inventory shape with deliberately non-operational hostnames. Each `ogg_DC` and `ogg_DR` group must contain exactly one host. The operational Jenkinsfile currently requires SSH as `localpwm`, then sudo as `oracle`.

## Jenkins provisioning

1. Configure the controller hostname matcher, Vault endpoints, Vault AppRole credential IDs, site mappings and profile paths in `../jenkins/Jenkinsfile_ogg_operational.groovy` for the approved environment. Published Vault URLs are placeholders; the job refuses them.
2. Store the reviewed real inventory in Jenkins as a **Secret file** credential named `ogg-inventory-<tier>-<environment>`, for example `ogg-inventory-dev-pt`. Do not store plaintext SSH passwords in the inventory. The pipeline supplies SSH/sudo credentials from Vault through runtime lookup variables.
3. The pipeline checks out the existing repository, enters `pipeline/SwitchOver`, copies the bound inventory into ignored `local/inventory/<tier>/<environment>.ini` with private permissions, and removes that copy in `finally` after the action. Jenkins manages cleanup of its bound secret-file source. Workspace interruption may still require approved workspace cleanup.
4. Provision approved SSH host keys, Kubernetes/pod access, Jenkins plugins and Vault permissions separately. Checkout does not deploy GoldenGate scripts or host profiles.

The previous local PT inventory is preserved at `../local/inventory/dev/pt.ini`. Review it before using it as a credential-file source. It is not loaded automatically by the Jenkins pipeline and is excluded from Git.

The example intentionally omits unrelated database/application nodes; this job targets only the two OGG site groups. Reconcile any site-specific inventory requirements before a live build.
