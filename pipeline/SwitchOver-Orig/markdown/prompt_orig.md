you will put the script `start_ogg_services.sh` on both nodes. When someone selects DC or DR in Jenkins, the pipeline will connect only to that site’s node and run the deployed script with Bash. Jenkins does not need to upload it. Neither local shell file nor the orig backup needs changing.

I will put the script on both nodes DC and DR. When administrator detects issue on this node, they will run the pipeline `jenkins/Jenkinsfile_run_start_service.groovy` to start service on the other one. The pipeline will access to that VM (DC or DR) and run the bash script `start_ogg_services.sh` to start service. 

## Recommended implementation
1. Add a Jenkins `TARGET_SITE` choice with `SELECT_SITE`, with two options from `List nodes address` in pipeline `jenkins/Jenkinsfile_run_start_service.groovy`; require an explicit valid selection before accessing secrets or connecting remotely.
2. Replace the single placeholder target with a small DC/DR configuration map containing each node's address, SSH user, absolute deployed script path, Vault secret path, and password key. Use the actual connection values supplied by the user, not invented addresses. Keep the current Vault server/AppRole unless told otherwise.
3. Add a validation stage that resolves only the chosen site, rejects missing settings and unsafe command values, and reports the selected site/host/script without secrets.
4. Retain the existing agent selection unless the user confirms a Kubernetes-specific change is needed. `agent any` can already run on a Kubernetes-provisioned agent; The chosen agent must have `ssh` and `sshpass`.
5. Reuse the current `withVault` KV-v2 integration, selecting only the chosen site's secret path/password key. Do not fetch unrelated database/application credentials.
6. Invoke the already installed script as `bash -- <safely quoted absolute script path>` over SSH, only on the selected node. Use shell-side environment expansion, `set +x`, and `sshpass -e` so the SSH password is not interpolated into Groovy or placed in process arguments. Preserve current host-key handling for this scoped change and note that managed host verification remains an infrastructure concern.
7. Let any SSH/script nonzero exit fail the Jenkins build; do not automatically retry. Add `disableConcurrentBuilds()` to prevent overlapping runs of this job (not cross-job locking or site fencing).

## Files and reusable references
- **Modify:** `jenkins/Jenkinsfile_run_start_service.groovy` only; reuse its AppRole/KV-v2 `withVault` pattern.
- **Read-only workflow:** `work_flow.txt`, whose DC and DR sections are alternative routes, not a request to run both.
- **Read-only script:** `start_ogg_services.sh`; preserve its internal startup/verification sequence and exit-code behavior. It requires Bash and contains PT-specific configuration; choosing a site does not rewrite that configuration.
- **Backup:** `OGG_Failover_TCB-PT-orig.sh` remains completely untouched.

## Completion gates
- Obtain the actual site addresses and deployed script path(s) before filling in production connection settings; the user has said they will supply them.
- Baseline Groovy syntax check already passed, with compilation only and no pipeline execution.
- After implementation, run offline mocked DC/DR, invalid-selection, incomplete-config, and remote-failure checks. Verify each valid choice reaches only its own configured target/secret and no real SSH/Vault actions occur.
- Real Jenkins Declarative validation and a service-start run require the user's Jenkins environment. Do not claim these passed locally; do not execute service actions without a separate explicit request.






# New update 1
- we still have to use ansible as `jenkins/Jenkins_t24_dba_new.groovy`
- we MUST use user `localpwm`, then su to user oracle and run the script