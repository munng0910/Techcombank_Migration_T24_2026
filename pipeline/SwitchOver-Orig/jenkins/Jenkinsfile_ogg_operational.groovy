// ============================================================================
// OGG operational actions, based on Jenkinsfile_run_start_service.groovy.
// This is a separate job; it never invokes the full startup/cleanup script.
// ============================================================================
def NODE_PROD = 'drp-2022'
def VAULT_ADDR_PROD = 'https://vault.techcombank.com.vn/'
def VAULT_APPROLE_PROD = 'ito-dso-vault-prod-approle'

def NODE_DEV = 'ansible'
def VAULT_ADDR_DEV = 'https://vault-dev.techcombank.com.vn/'
def VAULT_APPROLE_DEV = 'ito-dso-vault-dev-approle'

def SYSTEM_NAME = 't24'
def PLAYBOOK_FILE = 'ogg_operational_actions.yml'

// The script must already exist on the selected VM; this job does not deploy it.
// Hosts and SSH user localpwm are read from the selected environment inventory.
def SITES = [
    DC: [group: 'ogg_DC', scriptPath: '/home/oracle/profile/op_ogg_actions.sh', vaultKey: 'oggnode1_ansible_password'],
    DR: [group: 'ogg_DR', scriptPath: '/home/oracle/profile/op_ogg_actions.sh', vaultKey: 'oggnode2_ansible_password']
]

// Assumed profile paths; deploy readable profiles exporting OGG settings on each host.
// Source the selected profile as oracle in the same Bash invocation as the action.
def OGG_ENV_PROFILES = [
    'OGG for Oracle': '/home/oracle/profile/ogg26_oracle_test',
    'OGG for DAA': '/home/oracle/profile/ogg26_daa_test'
]

def OGG_ACTIONS = [
    'stop_ext', 'stop_rep', 'stop_depl', 'stop_sm',
    'start_ext', 'start_rep', 'start_depl', 'start_sm'
]

// ----------------------------------------------------------------------------
// Declared entity lists (requirements section 4). Keep these synchronized with
// the environment/site assignments below; they populate the build dropdowns.
// A literal '*' in a deployment/process list is a wildcard selection, not a
// mapped object. It is passed unchanged to op_ogg_actions.sh, never expanded here.
// Credentials are existing AdminClient aliases for oracle, NEVER passwords or
// Jenkins/Vault credential IDs. ServiceManager actions need none of these inputs.
// ----------------------------------------------------------------------------
def DEPLOYMENTS_LIST = [
    'ogg_oracle03',
    'ogg_daa03',
    '*'
]

def EXTRACTS_LIST = [
    'EXT24P',
    'ET24P',
    'DS1EXT3',
    '*'
]

def REPLICATS_LIST = [
    'RPLDS1',
    'RPLDS2',
    'RPLDS3',
    'RKKPL01',
    'RKKPL02',
    '*'
]

def CREDENTIALS_LIST = [
    'OGGHUB_CORELIVE'
]

def ENTITY_LISTS = [
    deployments: DEPLOYMENTS_LIST,
    extracts: EXTRACTS_LIST,
    replicats: REPLICATS_LIST,
    credentials: CREDENTIALS_LIST
]

// Scope the declared targets: environment -> site -> deployment -> processes.
// Named selections must be assigned here for the chosen environment and site.
// Wildcard selections are passed to the script and can cover actual objects
// outside this mapping. Do not add '*' as a mapping key or process name here.
// Credentials are selected in the CREDENTIAL_NAME build-parameter dropdown.
// Empty maps prohibit named targets; deployment '*' uses ServiceManager scope.
// Omit extracts/replicats when that deployment has none; omission means [].
// Named start processes can infer a unique parent; process '*' cannot.
def OGG_DEPLOYMENTS = [
    pt: [
        DC: [
            ogg_oracle03: [
                extracts: ['EXT24P', 'ET24P', 'DS1EXT3']
            ],
            ogg_daa03: [
                replicats: ['RPLDS1', 'RPLDS2', 'RPLDS3', 'RKKPL01', 'RKKPL02']
            ]
        ],
        DR: [
            ogg_oracle03: [
                extracts: ['EXT24P', 'ET24P', 'DS1EXT3']
            ],
            ogg_daa03: [
                replicats: ['RPLDS1', 'RPLDS2', 'RPLDS3', 'RKKPL01', 'RKKPL02']
            ]
        ]
    ],
    sit:         [DC: [:], DR: [:]],
    techupgrade: [DC: [:], DR: [:]],
    corelive1a:  [DC: [:], DR: [:]],
    corelive1b:  [DC: [:], DR: [:]]
]

// ----------------------------------------------------------------------------
// Resolve the prod/dev tier as in the startup reference, retaining ENVIRONMENT.
// ----------------------------------------------------------------------------
def ONNODE
def VAULT_ADDR
def VAULT_APPROLE
def ENV
def CLUSTERS

if ((env.JENKINS_URL ?: '') =~ /jenkins\.techcombank\.com\.vn/) {
    ONNODE = NODE_PROD
    VAULT_ADDR = VAULT_ADDR_PROD
    VAULT_APPROLE = VAULT_APPROLE_PROD
    ENV = 'prod'
    CLUSTERS = ['corelive1a', 'corelive1b']
} else {
    ONNODE = NODE_DEV
    VAULT_ADDR = VAULT_ADDR_DEV
    VAULT_APPROLE = VAULT_APPROLE_DEV
    ENV = 'dev'
    CLUSTERS = ['pt', 'sit', 'techupgrade']
}

// Active Choices Reactive Reference updates CSS when OGG_ACTION changes.
// Requires the Active Choices plugin and normal administrator approval for this
// non-sandboxed HTML script: sandboxed output may remove the required style tag.
// Uses modern classic Jenkins form rows and a browser supporting CSS :has().
// Inline styles must be allowed by the controller policy; do not relax global
// CSP or Script Security to enable this. No custom JavaScript is injected.
// The four common parameters stay visible; backend validation remains decisive.
def OGG_VISIBILITY_SCRIPT = '''
    def allTargets = ['DEPLOYMENT', 'CREDENTIAL_NAME', 'EXTRACT', 'REPLICAT']
    def hiddenByAction = [
        'start_ext': ['REPLICAT'],
        'stop_ext': ['REPLICAT'],
        'start_rep': ['EXTRACT'],
        'stop_rep': ['EXTRACT'],
        'start_depl': ['EXTRACT', 'REPLICAT'],
        'stop_depl': ['EXTRACT', 'REPLICAT'],
        'start_sm': ['DEPLOYMENT', 'CREDENTIAL_NAME', 'EXTRACT', 'REPLICAT'],
        'stop_sm': ['DEPLOYMENT', 'CREDENTIAL_NAME', 'EXTRACT', 'REPLICAT']
    ]
    def action = binding.hasVariable('OGG_ACTION') ? String.valueOf(OGG_ACTION) : ''
    def hidden = hiddenByAction.containsKey(action) ? hiddenByAction[action] : allTargets
    def selectors = hidden.collect { parameter ->
        '.jenkins-form-item:has(> .setting-main > div[name="parameter"] > input[name="name"][value="' + parameter + '"])'
    }
    return '<style id="ogg-parameter-visibility">' + selectors.join(', ') + ' { display: none !important; }</style>'
'''.stripIndent()

// Run this Jenkinsfile once after an update to install/refresh job parameters.
properties([
    disableConcurrentBuilds(),
    parameters([
        choice(name: 'ENVIRONMENT', choices: CLUSTERS, description: 'Select the environment inventory and Vault path.'),
        choice(name: 'TARGET_SITE', choices: ['SELECT_SITE', 'DC', 'DR'], description: 'Select exactly one OGG site/host.'),
        choice(name: 'OGG_ENV_PROFILE', choices: ['SELECT_PROFILE'] + OGG_ENV_PROFILES.keySet().toList(), description: 'Required for every action. Select the Oracle or DAA environment profile to source as oracle on the selected host before running the script.'),
        choice(name: 'OGG_ACTION', choices: ['SELECT_ACTION'] + OGG_ACTIONS, description: 'Select one targeted OGG action. Relevant target fields are shown automatically; environment, site and profile stay visible.'),
        choice(name: 'DEPLOYMENT', choices: ['SELECT_DEPLOYMENT'] + DEPLOYMENTS_LIST, description: 'Use * only for start_depl/stop_depl. Process actions require one concrete deployment; a named start process can infer a unique parent if left at the default. Process * always requires an explicit deployment.'),
        choice(name: 'CREDENTIAL_NAME', choices: ['SELECT_CREDENTIAL'] + CREDENTIALS_LIST, description: 'Required for deployment/process actions. Select an existing AdminClient alias, not a password. Unused for start_sm/stop_sm.'),
        choice(name: 'EXTRACT', choices: ['SELECT_EXTRACT'] + EXTRACTS_LIST, description: 'Required only for start_ext/stop_ext. Select one declared Extract or * for ALL actual Extracts in the selected deployment, including groups outside the Jenkins mapping.'),
        choice(name: 'REPLICAT', choices: ['SELECT_REPLICAT'] + REPLICATS_LIST, description: 'Required only for start_rep/stop_rep. Select one declared Replicat or * for ALL actual Replicats in the selected deployment, including groups outside the Jenkins mapping.'),
        [
            $class: 'DynamicReferenceParameter',
            name: 'OGG_PARAMETER_VISIBILITY',
            description: 'UI-only visibility rules; not an operational input.',
            randomName: 'choice-parameter-ogg-visibility',
            choiceType: 'ET_FORMATTED_HIDDEN_HTML',
            referencedParameters: 'OGG_ACTION',
            omitValueField: true,
            script: [
                $class: 'GroovyScript',
                script: [classpath: [], sandbox: false, script: OGG_VISIBILITY_SCRIPT],
                // Script fallback returns no styles, keeping all fields visible.
                // UI visibility never replaces server-side input validation.
                fallbackScript: [classpath: [], sandbox: true, script: "return ''"]
            ]
        ]
    ])
])

// ----------------------------------------------------------------------------
// Validate build-parameter selections before approval or remote execution.
// ----------------------------------------------------------------------------

def validateEntityLists(entityLists) {
    def definitions = [
        deployments: [name: 'DEPLOYMENTS_LIST', pattern: '[A-Za-z0-9_][A-Za-z0-9_.-]*'],
        extracts: [name: 'EXTRACTS_LIST', pattern: '[A-Z0-9_]+'],
        replicats: [name: 'REPLICATS_LIST', pattern: '[A-Z0-9_]+'],
        // Exclude '$': some Ansible command versions expand variables in argv.
        credentials: [name: 'CREDENTIALS_LIST', pattern: '[A-Za-z0-9_][A-Za-z0-9_.#-]*']
    ]
    definitions.each { entityType, definition ->
        def values = entityLists[entityType]
        if (!(values instanceof List)) {
            error("${definition.name} must be a declared list.")
        }
        values.each { value ->
            def wildcard = value == '*' && (entityType in ['deployments', 'extracts', 'replicats'])
            if (!(value instanceof String) || (!(value ==~ definition.pattern) && !wildcard)) {
                error("Invalid entry in ${definition.name}; use explicit names/aliases or a literal * in deployment/process lists only. Partial globs, whitespace and command separators are not allowed.")
            }
        }
        if (values.toSet().size() != values.size()) {
            error("Remove duplicate entries from ${definition.name}.")
        }
    }
    if (!entityLists.deployments || !entityLists.credentials) {
        error('DEPLOYMENTS_LIST and CREDENTIALS_LIST must not be empty for deployment/process actions.')
    }
    if (entityLists.deployments.any { it.equalsIgnoreCase('ServiceManager') }) {
        error('Do not put ServiceManager in DEPLOYMENTS_LIST; use start_sm/stop_sm.')
    }
}

def validateDeployments(deployments, entityLists) {
    validateEntityLists(entityLists)
    if (!(deployments instanceof Map)) {
        error('OGG_DEPLOYMENTS must provide a deployment map for the selected environment/site.')
    }
    deployments.each { deployment, settings ->
        if (deployment == '*' || !(deployment in entityLists.deployments)) {
            error("Deployment ${deployment} must be a concrete name in DEPLOYMENTS_LIST; * is a selection marker, not a mapped deployment.")
        }
        if (!(settings instanceof Map)) {
            error("Configure extracts and replicats assignments for deployment ${deployment}.")
        }
        ['extracts', 'replicats'].each { processType ->
            def processes = settings.containsKey(processType) ? settings[processType] : []
            if (!(processes instanceof List)) {
                error("${deployment}.${processType} must be a list; omit it or use [] when none are configured.")
            }
            processes.each { process ->
                if (process == '*' || !(process in entityLists[processType])) {
                    error("${process} in ${deployment}.${processType} must be a concrete declared process; * belongs in the dropdown list only.")
                }
            }
            if (processes.toSet().size() != processes.size()) {
                error("Remove duplicate names from ${deployment}.${processType}.")
            }
        }
    }
}

def resolveOggTarget(action, deployments, entityLists, selections) {
    if (action in ['start_sm', 'stop_sm']) {
        return [deployment: '', credentialAlias: '', process: '']
    }
    validateDeployments(deployments, entityLists)
    def availableDeployments = entityLists.deployments.findAll { it != '*' && deployments.containsKey(it) }
    if (!(selections.credentialAlias in entityLists.credentials)) {
        error('Select CREDENTIAL_NAME from CREDENTIALS_LIST on Build with Parameters, then rerun the job.')
    }
    def deployment = selections.deployment
    def process = ''
    if (action in ['start_ext', 'stop_ext', 'start_rep', 'stop_rep']) {
        if (deployment == '*') {
            error('DEPLOYMENT=* is supported only for start_depl/stop_depl. Process actions require one concrete deployment.')
        }
        def processType = action.endsWith('_ext') ? 'extracts' : 'replicats'
        def parameterName = action.endsWith('_ext') ? 'EXTRACT' : 'REPLICAT'
        process = action.endsWith('_ext') ? selections.extract : selections.replicat
        if (!(process in entityLists[processType])) {
            error("Select ${parameterName} from its declared list on Build with Parameters, then rerun the job.")
        }
        if (process == '*' && (deployment in ['', 'SELECT_DEPLOYMENT'])) {
            error("Select one concrete DEPLOYMENT when ${parameterName}=*. A wildcard process cannot infer its deployment.")
        }
        if (action.startsWith('start_') && (deployment in ['', 'SELECT_DEPLOYMENT'])) {
            // Only a named process can infer a unique parent. A literal '*' is
            // passed to the script, which discovers actual groups on the host.
            def parents = availableDeployments.findAll { process in (deployments[it][processType] ?: []) }
            if (parents.isEmpty()) {
                error("${parameterName} ${process} has no deployment assignment for this environment/site; configure OGG_DEPLOYMENTS.")
            }
            if (parents.size() != 1) {
                error("${parameterName} ${process} belongs to multiple deployments; select DEPLOYMENT on Build with Parameters to disambiguate.")
            }
            deployment = parents[0]
        }
        if (!(deployment in availableDeployments)) {
            error('Select a DEPLOYMENT declared and assigned to the selected environment/site on Build with Parameters.')
        }
        if (process != '*' && !(process in (deployments[deployment][processType] ?: []))) {
            error("${parameterName} ${process} is not assigned to deployment ${deployment} at the selected environment/site.")
        }
    } else if (action in ['start_depl', 'stop_depl']) {
        if (deployment == '*') {
            if (!('*' in entityLists.deployments)) {
                error('Wildcard deployment actions are not enabled in DEPLOYMENTS_LIST.')
            }
            // Native ServiceManager wildcard scope is not the Jenkins mapping.
        } else if (!(deployment in availableDeployments)) {
            error('Select a DEPLOYMENT declared and assigned to the selected environment/site on Build with Parameters.')
        }
    } else {
        error('Unsupported OGG action for target resolution.')
    }
    return [deployment: deployment, credentialAlias: selections.credentialAlias, process: process]
}

def resultMeaning(ctx) {
    def action = ctx.action
    if (action.endsWith('_ext') || action.endsWith('_rep')) {
        def desired = action.startsWith('start_') ? 'RUNNING' : 'STOPPED'
        if (ctx.process == '*') {
            def processType = action.endsWith('_ext') ? 'Extracts' : 'Replicats'
            return "Wildcard * affects ALL actual ${processType} in deployment ${ctx.deployment}, not only Jenkins-mapped groups. The script requires a nonempty inventory and verifies all discovered groups reach ${desired}."
        }
        return "The exact process must reach ${desired}; the script verifies its state."
    }
    if (action.endsWith('_depl')) {
        if (ctx.deployment == '*') {
            return 'Wildcard * affects ALL deployments covered by the connected ServiceManager, not only Jenkins-mapped deployments or the selected profile type. PASS means command completion, not verified state of every deployment.'
        }
        return 'This affects the entire selected deployment. PASS means command completion, not independently verified deployment health.'
    }
    return 'This affects the ServiceManager instance on the single selected host. PASS means native script/launcher completion, not independently verified service health.'
}

// Check/build only the selected site's SSH/sudo secret, as in the reference.
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

def buildOggSecrets(configuration, vaultPathOgg, secretKey) {
    if (!checkVaultExists(configuration, vaultPathOgg, secretKey)) {
        error("Vault key '${secretKey}' at '${vaultPathOgg}' is unavailable. Check the key, path, and Vault permissions.")
    }
    return [[path: vaultPathOgg, engineVersion: 2, secretValues: [[envVar: 'PASS_OGG', vaultKey: secretKey]]]]
}

// ----------------------------------------------------------------------------
// A fixed Bash wrapper sources the chosen profile and executes one OGG action.
// Target values remain separate argv entries, never interpolated into shell code.
// Temp variables contain lookup expressions, not password values.
// ----------------------------------------------------------------------------
def runPlaybook(ctx) {
    stage('Run OGG operational action') {
        container('ansible') {
            withEnv([
                "OGG_INVENTORY=${ctx.inventoryPath}",
                "OGG_PLAYBOOK=${ctx.playbookPath}",
                "OGG_TARGET_GROUP=${ctx.targetGroup}",
                "OGG_ACTION_SCRIPT=${ctx.scriptPath}",
                "OGG_ENV_PROFILE_PATH=${ctx.envProfilePath}",
                "OGG_SELECTED_ACTION=${ctx.action}",
                "OGG_DEPLOYMENT=${ctx.deployment}",
                "OGG_CREDENTIAL_ALIAS=${ctx.credentialAlias}",
                "OGG_PROCESS=${ctx.process}"
            ]) {
                try {
                    writeFile file: ctx.playbookPath, text: '''
                        |---
                        |- name: Validate the selected OGG target inside the Ansible pod
                        |  hosts: localhost
                        |  connection: local
                        |  gather_facts: false
                        |  become: false
                        |  any_errors_fatal: true
                        |  tasks:
                        |    - name: Validate operational inputs
                        |      ansible.builtin.assert:
                        |        that:
                        |          - not ansible_check_mode
                        |          - ogg_target_group in ['ogg_DC', 'ogg_DR']
                        |          - ogg_action in ['stop_ext', 'stop_rep', 'stop_depl', 'stop_sm', 'start_ext', 'start_rep', 'start_depl', 'start_sm']
                        |          - ogg_action_script is match('^/[A-Za-z0-9_./-]+$')
                        |          - not ogg_action_script.startswith('/path/to/')
                        |          - "'..' not in ogg_action_script.split('/')"
                        |          - ogg_env_profile is match('^/[A-Za-z0-9_./-]+$')
                        |          - "'..' not in ogg_env_profile.split('/')"
                        |        fail_msg: 'Select a valid OGG action, site, deployed script and environment profile; check mode is not supported.'
                        |
                        |    - name: Validate deployment and AdminClient alias when required
                        |      ansible.builtin.assert:
                        |        that:
                        |          - (ogg_deployment is match('^[A-Za-z0-9_][A-Za-z0-9_.-]*$')) or (ogg_deployment == '*' and ogg_action in ['start_depl', 'stop_depl'])
                        |          - ogg_deployment | lower != 'servicemanager'
                        |          - ogg_credential_alias is match('^[A-Za-z0-9_][A-Za-z0-9_.#-]*$')
                        |        fail_msg: 'An existing AdminClient alias is required. Deployment * is supported only for start_depl/stop_depl; process actions require a concrete deployment.'
                        |      when: ogg_action not in ['start_sm', 'stop_sm']
                        |
                        |    - name: Validate the process name or literal wildcard when required
                        |      ansible.builtin.assert:
                        |        that:
                        |          - ogg_process == '*' or ogg_process is match('^[A-Z0-9_]+$')
                        |        fail_msg: 'Select one explicit Extract/Replicat or a literal *. Partial globs and command separators are not allowed.'
                        |      when: ogg_action in ['start_ext', 'stop_ext', 'start_rep', 'stop_rep']
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
                        |          - hostvars[groups[ogg_target_group][0]].ansible_user | default(hostvars[groups[ogg_target_group][0]].ansible_ssh_user | default('')) == 'localpwm'
                        |          - hostvars[groups[ogg_target_group][0]].ansible_ssh_user | default('localpwm') == 'localpwm'
                        |          - hostvars[groups[ogg_target_group][0]].ansible_connection | default('ssh') in ['ssh', 'ansible.builtin.ssh']
                        |        fail_msg: 'The selected inventory host must use SSH as localpwm; ansible_user and ansible_ssh_user must not conflict.'
                        |
                        |- name: Run one GoldenGate action on the selected site
                        |  hosts: "{{ ogg_target_group }}"
                        |  connection: ssh
                        |  gather_facts: false
                        |  any_errors_fatal: true
                        |  become: true
                        |  become_method: sudo
                        |  become_user: oracle
                        |  become_flags: '-H -S -i'
                        |  tasks:
                        |    - name: Verify effective Oracle identity before executing the action
                        |      ansible.builtin.command:
                        |        argv:
                        |          - id
                        |          - '-un'
                        |      register: oracle_identity
                        |      changed_when: false
                        |      failed_when: oracle_identity.rc != 0 or (oracle_identity.stdout | trim) != 'oracle'
                        |
                        |    - name: Check the pre-deployed operational script as oracle
                        |      ansible.builtin.stat:
                        |        path: "{{ ogg_action_script }}"
                        |        follow: true
                        |      register: ogg_script
                        |
                        |    - name: Require a readable operational script
                        |      ansible.builtin.assert:
                        |        that:
                        |          - ogg_script.stat.exists
                        |          - ogg_script.stat.isreg | default(false)
                        |          - ogg_script.stat.readable | default(false)
                        |        fail_msg: 'Deploy op_ogg_actions.sh at the configured path and make it readable by oracle before running this job.'
                        |
                        |    - name: Check the selected environment profile as oracle
                        |      ansible.builtin.stat:
                        |        path: "{{ ogg_env_profile }}"
                        |        follow: true
                        |      register: ogg_profile
                        |
                        |    - name: Require a readable environment profile
                        |      ansible.builtin.assert:
                        |        that:
                        |          - ogg_profile.stat.exists
                        |          - ogg_profile.stat.isreg | default(false)
                        |          - ogg_profile.stat.readable | default(false)
                        |        fail_msg: 'The selected OGG environment profile must exist and be readable by oracle on this host.'
                        |
                        |    - name: Source the selected profile and execute the action in the same Bash session
                        |      ansible.builtin.command:
                        |        argv: >-
                        |          {{ ['/bin/bash', '-c', ogg_profile_wrapper,
                        |              'ogg-operational', ogg_env_profile, ogg_action_script, ogg_action]
                        |             + ([ogg_deployment, ogg_credential_alias] if ogg_action not in ['start_sm', 'stop_sm'] else [])
                        |             + ([ogg_process] if ogg_action in ['start_ext', 'stop_ext', 'start_rep', 'stop_rep'] else []) }}
                        |      vars:
                        |        ogg_profile_wrapper: |-
                        |          readonly _jenkins_ogg_profile="$1"
                        |          shift
                        |          readonly -a _jenkins_ogg_args=("$@")
                        |          trap 'rc=$?; [ "$rc" -ne 0 ] || rc=1; printf "%s" "OGG profile exited before the action started." >&2; exit "$rc"' EXIT
                        |          source "$_jenkins_ogg_profile" || exit $?
                        |          trap - EXIT
                        |          # Quoted array expansion passes '*' as one literal argument, without globbing.
                        |          exec /bin/bash -- "${_jenkins_ogg_args[@]}"
                        |      register: ogg_action_result
                        |      failed_when: false
                        |      changed_when: ogg_action_result.rc == 0
                        |
                        |    - name: Show operational output, including failures
                        |      ansible.builtin.debug:
                        |        msg: "{{ ogg_action_result.stdout_lines | default([]) }}"
                        |
                        |    - name: Show operational error output
                        |      ansible.builtin.debug:
                        |        msg: "{{ ogg_action_result.stderr_lines | default([]) }}"
                        |      when: (ogg_action_result.stderr | default('') | length) > 0
                        |
                        |    - name: Fail the playbook if the operational script failed
                        |      ansible.builtin.assert:
                        |        that:
                        |          - (ogg_action_result.rc | default(1)) == 0
                        |        fail_msg: 'The OGG action failed. Review the script output and remote log path above; no automatic retry is performed.'
                    '''.stripMargin()
                    writeFile file: 'ogg_operational_vars.yml', text: '''
                        |ogg_target_group: "{{ lookup('env', 'OGG_TARGET_GROUP') }}"
                        |ogg_action_script: "{{ lookup('env', 'OGG_ACTION_SCRIPT') }}"
                        |ogg_env_profile: "{{ lookup('env', 'OGG_ENV_PROFILE_PATH') }}"
                        |ogg_action: "{{ lookup('env', 'OGG_SELECTED_ACTION') }}"
                        |ogg_deployment: "{{ lookup('env', 'OGG_DEPLOYMENT') }}"
                        |ogg_credential_alias: "{{ lookup('env', 'OGG_CREDENTIAL_ALIAS') }}"
                        |ogg_process: "{{ lookup('env', 'OGG_PROCESS') }}"
                        |ogg_ansible_password: "{{ lookup('env', 'PASS_OGG') }}"
                        |# Bind legacy aliases too so inventory cannot replace the selected Vault password.
                        |ansible_password: "{{ ogg_ansible_password }}"
                        |ansible_ssh_pass: "{{ ogg_ansible_password }}"
                        |ansible_become_password: "{{ ogg_ansible_password }}"
                        |ansible_become_pass: "{{ ogg_ansible_password }}"
                        |ansible_sudo_pass: "{{ ogg_ansible_password }}"
                    '''.stripMargin()
                    sh '''
                        set +x
                        set -eu
                        : "${PASS_OGG:?Vault returned an empty localpwm password}"
                        ANSIBLE_FORCE_COLOR=true ansible-playbook \\
                            -i "${OGG_INVENTORY}" \\
                            -e @ogg_operational_vars.yml \\
                            --limit "${OGG_TARGET_GROUP},localhost" \\
                            "${OGG_PLAYBOOK}"
                    '''
                } finally {
                    sh 'rm -f -- ogg_operational_vars.yml "${OGG_PLAYBOOK}"'
                }
            }
        }
    }
}

// ----------------------------------------------------------------------------
// Resolve and approve the complete target before provisioning the Ansible pod.
// Empty allowlists and placeholder paths fail closed; examples are not targets.
// ----------------------------------------------------------------------------
def ENVIRONMENT = (params.ENVIRONMENT ?: '').toString()
def TARGET_SITE = (params.TARGET_SITE ?: '').toString()
def OGG_ACTION = (params.OGG_ACTION ?: '').toString()
def OGG_ENV_PROFILE = (params.OGG_ENV_PROFILE ?: '').toString()
def targetSelections = [
    deployment: (params.DEPLOYMENT ?: '').toString(),
    extract: (params.EXTRACT ?: '').toString(),
    replicat: (params.REPLICAT ?: '').toString(),
    credentialAlias: (params.CREDENTIAL_NAME ?: '').toString()
]
def site = SITES[TARGET_SITE] ?: [:]
def ctx = [
    environment: ENVIRONMENT,
    targetSite: TARGET_SITE,
    targetGroup: site.group,
    scriptPath: site.scriptPath,
    envProfileName: OGG_ENV_PROFILE,
    envProfilePath: OGG_ENV_PROFILES[OGG_ENV_PROFILE],
    vaultKey: site.vaultKey,
    inventoryPath: "inventory/database/${SYSTEM_NAME}/${ENV}/${ENVIRONMENT}.ini".toString(),
    playbookPath: PLAYBOOK_FILE,
    action: OGG_ACTION
]

stage('Validate selection') {
    if (!(ENVIRONMENT in CLUSTERS)) {
        error('Select a valid ENVIRONMENT and rerun the job. The first build initializes its parameters.')
    }
    if (!(TARGET_SITE in ['DC', 'DR'])) {
        error('Select DC or DR in TARGET_SITE before running this job.')
    }
    if (!(OGG_ACTION in OGG_ACTIONS)) {
        error('Select one of the eight supported OGG_ACTION values before running this job.')
    }
    if (!OGG_ENV_PROFILES.containsKey(OGG_ENV_PROFILE)) {
        error('Select OGG for Oracle or OGG for DAA in OGG_ENV_PROFILE on Build with Parameters, then rerun the job.')
    }
    if (!(ctx.envProfilePath instanceof String) || !(ctx.envProfilePath ==~ '/[A-Za-z0-9_./-]+') || ctx.envProfilePath.tokenize('/').contains('..')) {
        error('The configured environment profile must have a safe absolute path without parent-directory traversal.')
    }
    if (ctx.targetGroup != "ogg_${TARGET_SITE}" || !site.vaultKey?.trim()) {
        error('Configure the selected site inventory group and Vault password key.')
    }
    if (!ctx.scriptPath || ctx.scriptPath.startsWith('/path/to/')) {
        error("Replace the operational scriptPath placeholder for ${TARGET_SITE} with the pre-deployed absolute path.")
    }
    if (!(ctx.scriptPath ==~ '/[A-Za-z0-9_./-]+') || ctx.scriptPath.tokenize('/').contains('..') || ctx.scriptPath.tokenize('/').last() != 'op_ogg_actions.sh') {
        error('scriptPath must be a safe absolute path to op_ogg_actions.sh without parent-directory traversal.')
    }
}

stage('Resolve OGG target') {
    def deployments = OGG_DEPLOYMENTS[ENVIRONMENT]?.get(TARGET_SITE)
    ctx.putAll(resolveOggTarget(OGG_ACTION, deployments, ENTITY_LISTS, targetSelections))
}

stage('Confirm OGG action') {
    def target = ctx.deployment ? "deployment ${ctx.deployment}" : 'ServiceManager'
    if (ctx.process) {
        target += "; process ${ctx.process}"
    }
    if (ctx.credentialAlias) {
        target += "; credential alias ${ctx.credentialAlias}"
    }
    currentBuild.description = "${ENVIRONMENT} ${TARGET_SITE}: ${OGG_ACTION}; ${target}; profile ${ctx.envProfileName}"
    echo "Environment: ${ENVIRONMENT} (${ENV}); target site: ${TARGET_SITE}; group: ${ctx.targetGroup}"
    echo "Action: ${OGG_ACTION}; target: ${target}; script: ${ctx.scriptPath}"
    echo "OGG profile: ${ctx.envProfileName}; remote path: ${ctx.envProfilePath}"
    echo "Run-ON: ${ONNODE}; pod template: ansible"
    echo resultMeaning(ctx)
    timeout(time: 10, unit: 'MINUTES') {
        input(id: 'confirmOggAction', message: "Confirm ${ENVIRONMENT} ${TARGET_SITE}: ${OGG_ACTION}; ${target}; profile ${ctx.envProfileName} (${ctx.envProfilePath}). ${resultMeaning(ctx)}", ok: 'Run action')
    }
}

def VAULT_PATH_OGG = "kv2/ogg/${ENVIRONMENT}/secret".toString()
def configuration = [vaultUrl: VAULT_ADDR, vaultCredentialId: VAULT_APPROLE, engineVersion: 2]

podTemplate(inheritFrom: 'ansible') {
    node(POD_LABEL) {
        ansiColor('xterm') {
            stage('Checkout SCM') {
                cleanWs()
                checkout scm
            }
            stage('Validate inventory') {
                if (!fileExists(ctx.inventoryPath)) {
                    error("Required SCM inventory not found: ${ctx.inventoryPath}")
                }
            }
            def secrets = buildOggSecrets(configuration, VAULT_PATH_OGG, ctx.vaultKey)
            withVault([configuration: configuration, vaultSecrets: secrets]) {
                // Deliberately do not retry an action with a potentially changed state.
                timeout(time: 30, unit: 'MINUTES') {
                    runPlaybook(ctx)
                }
            }
        }
    }
}
