// ============================================================================
// Environment configuration, following Jenkinsfile_t24_dba_new.groovy
// ============================================================================
def NODE_PROD = 'drp-2022'
def VAULT_ADDR_PROD = 'https://vault.techcombank.com.vn/'
def VAULT_APPROLE_PROD = 'ito-dso-vault-prod-approle'

def NODE_DEV = 'ansible'
def VAULT_ADDR_DEV = 'https://vault-dev.techcombank.com.vn/'
def VAULT_APPROLE_DEV = 'ito-dso-vault-dev-approle'

def SYSTEM_NAME = 't24'
def PLAYBOOK_FILE = 'start_ogg_services.yml'

// All site-specific settings are defined before creating the Ansible pod.
// Hosts and SSH user localpwm are read by Ansible from the selected inventory.
// Replace the scriptPath placeholders with the paths already deployed on the VMs.
def SITES = [
    DC: [group: 'ogg_DC', scriptPath: '/path/to/file/start_ogg_services.sh', vaultKey: 'oggnode1_ansible_password'],
    DR: [group: 'ogg_DR', scriptPath: '/path/to/file/start_ogg_services.sh', vaultKey: 'oggnode2_ansible_password']
]

// ----------------------------------------------------------------------------
// Resolve environment from JENKINS_URL, using the same prod/dev workflow.
// ----------------------------------------------------------------------------
def ONNODE
def VAULT_ADDR
def VAULT_APPROLE
def ENV
def ENV_TIER_OPTS
def CLUSTERS

if ((env.JENKINS_URL ?: '') =~ /jenkins\.techcombank\.com\.vn/) {
    ONNODE = NODE_PROD
    VAULT_ADDR = VAULT_ADDR_PROD
    VAULT_APPROLE = VAULT_APPROLE_PROD
    ENV = 'prod'
    ENV_TIER_OPTS = '"corelive1a:selected","corelive1b"'
    CLUSTERS = ['corelive1a', 'corelive1b']
} else {
    ONNODE = NODE_DEV
    VAULT_ADDR = VAULT_ADDR_DEV
    VAULT_APPROLE = VAULT_APPROLE_DEV
    ENV = 'dev'
    ENV_TIER_OPTS = '"pt:selected","sit","techupgrade"'
    CLUSTERS = ['pt', 'sit', 'techupgrade']
}

def confirm(jobName) {
    input(id: 'confirm', message: "You confirm run: ${jobName}?", ok: 'Yes')
}

properties([
    disableConcurrentBuilds(),
    parameters([
        [
            $class: 'ChoiceParameter',
            choiceType: 'PT_RADIO',
            name: 'ENVIRONMENT',
            script: [
                $class: 'GroovyScript',
                script: [classpath: [], sandbox: true, script: "return [${ENV_TIER_OPTS}]"]
            ]
        ],
        choice(name: 'TARGET_SITE', choices: ['SELECT_SITE', 'DC', 'DR'], description: 'Select the site on which to start GoldenGate services.')
    ])
])

// ----------------------------------------------------------------------------
// Resolve every runtime setting before provisioning the Ansible pod.
// ----------------------------------------------------------------------------
def ENVIRONMENT = "${params.ENVIRONMENT}".toString()
def TARGET_SITE = "${params.TARGET_SITE}".toString()
def site = SITES[TARGET_SITE] ?: [:]
def VAULT_PATH_OGG = "kv2/ogg/${ENVIRONMENT}/secret".toString()
def ANSIBLE_INVENTORY = "${ENV}/${ENVIRONMENT}.ini".toString()
def configuration = [vaultUrl: VAULT_ADDR, vaultCredentialId: VAULT_APPROLE, engineVersion: 2]
def ctx = [
    environment: ENVIRONMENT,
    targetSite: TARGET_SITE,
    targetGroup: site.group,
    scriptPath: site.scriptPath,
    vaultKey: site.vaultKey,
    inventoryPath: "inventory/database/${SYSTEM_NAME}/${ANSIBLE_INVENTORY}".toString(),
    playbookPath: PLAYBOOK_FILE
]

println "Environment: ${ENVIRONMENT} (${ENV})"
println "Target site: ${TARGET_SITE}; inventory group: ${ctx.targetGroup}"
// ONNODE classifies the controller, as in the reference; execution uses POD_LABEL.
println "Run-ON: ${ONNODE}; pod template: ansible"
println "Inventory: ${ctx.inventoryPath}"
println "Playbook: ${ctx.playbookPath}"
println "VAULT_ADDR: ${VAULT_ADDR}"
println "VAULT_PATH_OGG: ${VAULT_PATH_OGG}"

// Check/build the OGG secret list using the reference pipeline's Vault helper pattern.
def checkVaultExists(configuration, vaultPath, secretKey) {
    try {
        withVault([configuration: configuration, vaultSecrets: [
            [path: vaultPath, engineVersion: 2, secretValues: [[envVar: 'TEST_VAULT', vaultKey: secretKey]]]
        ]]) { return true }
    } catch (InterruptedException e) {
        throw e
    } catch (Exception e) {
        return false
    }
}

// OGG-only equivalent of buildOsSecrets: require the selected node's key.
// Both DC/node1 and DR/node2 bind to PASS_OGG; do not read the unselected key.
def buildOggSecrets(configuration, vaultPathOgg, secretKey) {
    if (!checkVaultExists(configuration, vaultPathOgg, secretKey)) {
        error("Vault key '${secretKey}' at '${vaultPathOgg}' is unavailable. Check the key, path, and Vault permissions.")
    }
    return [[path: vaultPathOgg, engineVersion: 2, secretValues: [[envVar: 'PASS_OGG', vaultKey: secretKey]]]]
}

// ----------------------------------------------------------------------------
// Write the playbook and its variables inside the Ansible pod, then execute it.
// Only lookup expressions are written to temp_vars.yml, never password values.
// ----------------------------------------------------------------------------
def runPlaybook(ctx) {
    stage('Run GoldenGate startup playbook') {
        container('ansible') {
            withEnv([
                "OGG_INVENTORY=${ctx.inventoryPath}",
                "OGG_PLAYBOOK=${ctx.playbookPath}",
                "OGG_TARGET_GROUP=${ctx.targetGroup}",
                "OGG_START_SCRIPT=${ctx.scriptPath}"
            ]) {
                try {
                    writeFile file: ctx.playbookPath, text: '''
                        |---
                        |- name: Validate the selected site inside the Ansible pod
                        |  hosts: localhost
                        |  connection: local
                        |  gather_facts: false
                        |  become: false
                        |  any_errors_fatal: true
                        |  tasks:
                        |    - name: Validate startup inputs
                        |      ansible.builtin.assert:
                        |        that:
                        |          - not ansible_check_mode
                        |          - ogg_target_group in ['ogg_DC', 'ogg_DR']
                        |          - ogg_start_script is match('^/[A-Za-z0-9_./-]+$')
                        |          - not ogg_start_script.startswith('/path/to/')
                        |          - "'..' not in ogg_start_script.split('/')"
                        |        fail_msg: 'Select a valid OGG site and deployed script path; check mode is not supported.'
                        |
                        |    - name: Require exactly one host in the selected inventory group
                        |      ansible.builtin.assert:
                        |        that:
                        |          - groups.get(ogg_target_group, []) | length == 1
                        |        fail_msg: 'The selected OGG inventory group must exist and contain exactly one host.'
                        |
                        |    - name: Require SSH as localpwm
                        |      ansible.builtin.assert:
                        |        that:
                        |          - hostvars[groups[ogg_target_group][0]].ansible_user | default('') == 'localpwm'
                        |          - hostvars[groups[ogg_target_group][0]].ansible_connection | default('ssh') in ['ssh', 'ansible.builtin.ssh']
                        |        fail_msg: 'The selected inventory host must use SSH with user localpwm.'
                        |
                        |- name: Start GoldenGate on the selected site
                        |  hosts: "{{ ogg_target_group }}"
                        |  connection: ssh
                        |  gather_facts: false
                        |  any_errors_fatal: true
                        |  become: true
                        |  become_method: sudo
                        |  become_user: oracle
                        |  become_flags: '-H -S -i'
                        |  tasks:
                        |    - name: Verify effective Oracle identity before starting services
                        |      ansible.builtin.command:
                        |        argv:
                        |          - id
                        |          - '-un'
                        |      register: oracle_identity
                        |      changed_when: false
                        |      failed_when: oracle_identity.rc != 0 or (oracle_identity.stdout | trim) != 'oracle'
                        |
                        |    - name: Run the pre-deployed startup script with Bash
                        |      ansible.builtin.command:
                        |        argv:
                        |          - /bin/bash
                        |          - '--'
                        |          - "{{ ogg_start_script }}"
                        |      register: ogg_startup
                        |
                        |    - name: Show startup output
                        |      ansible.builtin.debug:
                        |        msg: "{{ ogg_startup.stdout_lines | default([]) }}"
                        |
                        |    - name: Show startup error output
                        |      ansible.builtin.debug:
                        |        msg: "{{ ogg_startup.stderr_lines | default([]) }}"
                        |      when: (ogg_startup.stderr | default('') | length) > 0
                    '''.stripMargin()
                    writeFile file: 'temp_vars.yml', text: '''
                        |ogg_target_group: "{{ lookup('env', 'OGG_TARGET_GROUP') }}"
                        |ogg_start_script: "{{ lookup('env', 'OGG_START_SCRIPT') }}"
                        |ogg_ansible_password: "{{ lookup('env', 'PASS_OGG') }}"
                        |ansible_become_password: "{{ ogg_ansible_password }}"
                    '''.stripMargin()
                    sh '''
                        set +x
                        set -eu
                        : "${PASS_OGG:?Vault returned an empty localpwm password}"
                        ANSIBLE_FORCE_COLOR=true ansible-playbook \\
                            -i "${OGG_INVENTORY}" \\
                            -e @temp_vars.yml \\
                            --limit "${OGG_TARGET_GROUP},localhost" \\
                            "${OGG_PLAYBOOK}"
                    '''
                } finally {
                    sh 'rm -f -- temp_vars.yml "${OGG_PLAYBOOK}"'
                }
            }
        }
    }
}

// ----------------------------------------------------------------------------
// Provision the Ansible pod only after all configuration above has been resolved.
// ----------------------------------------------------------------------------
podTemplate(inheritFrom: 'ansible') {
    node(POD_LABEL) {
        ansiColor('xterm') {
            stage('Checkout SCM') {
                cleanWs()
                checkout scm
            }

            stage('Validate selection') {
                if (!(ENVIRONMENT in CLUSTERS)) {
                    error('Select a valid ENVIRONMENT and rerun the job. The first build initializes its parameters.')
                }
                if (!(TARGET_SITE in ['DC', 'DR'])) {
                    error('Select DC or DR in TARGET_SITE before running this job.')
                }
                if (ctx.targetGroup != "ogg_${TARGET_SITE}" || !site.vaultKey?.trim()) {
                    error('Configure the selected site inventory group and Vault password key.')
                }
                if (!ctx.scriptPath || ctx.scriptPath.startsWith('/path/to/')) {
                    error("Replace the scriptPath placeholder for ${TARGET_SITE} with the deployed absolute path.")
                }
                if (!(ctx.scriptPath ==~ '/[A-Za-z0-9_./-]+') || ctx.scriptPath.tokenize('/').contains('..')) {
                    error('scriptPath must be a safe absolute path without parent-directory traversal.')
                }
                if (!fileExists(ctx.inventoryPath)) {
                    error("Required SCM inventory not found: ${ctx.inventoryPath}")
                }
            }

            def secrets = buildOggSecrets(configuration, VAULT_PATH_OGG, ctx.vaultKey)
            withVault([configuration: configuration, vaultSecrets: secrets]) {
                confirm("${ENVIRONMENT} ${TARGET_SITE}: ${ctx.targetGroup}; script ${ctx.scriptPath}")
                runPlaybook(ctx)
            }
        }
    }
}
