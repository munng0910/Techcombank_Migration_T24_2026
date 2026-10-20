// Offline checks of the reference-style scripted workflow. No real Jenkins or remote actions.
// Run: groovy tests/ogg/validate_start_service.groovy [workspace] [optional-fixture-directory]
import org.codehaus.groovy.control.CompilerConfiguration

class OfflineFailure extends RuntimeException {
    OfflineFailure(String message) { super(message) }
}
abstract class MockJenkins extends Script {
    Map env = [:], params = [:]
    List events = [], logs = [], definitions = [], probeCalls = [], vaultCalls = [], writes = [], commands = [], cleanups = []
    Map passwords = [oggnode1_ansible_password: 'OFFLINE_NODE1_PASSWORD_DO_NOT_LOG', oggnode2_ansible_password: 'OFFLINE_NODE2_PASSWORD_DO_NOT_LOG']
    Set availableKeys = new LinkedHashSet(passwords.keySet())
    String failureMode = '', inContainer = null
    boolean inventoryExists = true
    Object disableConcurrentBuilds() { [kind: 'concurrency'] }
    Object choice(Map definition) { definition }
    Object parameters(List parameters) { definitions = parameters; [kind: 'parameters'] }
    void properties(List properties) { assert properties.size() == 2; events << 'properties' }
    void println(Object message) { logs << message.toString(); events << 'configuration' }
    void error(Object message) { throw new OfflineFailure(message.toString()) }
    void stage(String name, Closure body) { events << "stage:${name}".toString(); body() }
    void podTemplate(Map configuration, Closure body) {
        assert configuration == [inheritFrom: 'ansible']
        assert logs.size() == 7 && events[0] == 'properties'
        assert logs[-1].startsWith('VAULT_PATH_OGG: kv2/ogg/')
        events << 'pod'; body()
    }
    void node(String label, Closure body) { assert label == 'mock-pod'; events << 'node'; body() }
    void ansiColor(String name, Closure body) { assert name == 'xterm'; body() }
    void cleanWs() { events << 'clean' }
    void checkout(Object scm) {
        assert scm == 'configured-scm' && events[-1] == 'clean'
        events << 'checkout'
        if (failureMode == 'checkout') { throw new OfflineFailure('simulated SCM failure') }
    }
    boolean fileExists(String path) {
        assert path.startsWith('inventory/database/t24/') && path.endsWith('.ini')
        inventoryExists
    }
    Object withVault(Map configuration, Closure body) {
        assert events.contains('checkout') && !events.contains('confirm') && !events.contains('container')
        def binding = configuration.vaultSecrets[0].secretValues[0]
        if (binding.envVar == 'TEST_VAULT') {
            events << 'probe'; probeCalls << configuration
            if (failureMode == 'probe-interrupted') { throw new InterruptedException('simulated Vault probe interruption') }
            if (failureMode == 'probe-failure' || !(binding.vaultKey in availableKeys)) { throw new OfflineFailure('simulated unavailable Vault key') }
            env.TEST_VAULT = passwords[binding.vaultKey]
            try { return body() } finally { env.remove('TEST_VAULT') }
        }
        assert binding.envVar == 'PASS_OGG' && probeCalls.size() == 1
        events << 'vault'; vaultCalls << configuration
        if (failureMode == 'vault') { throw new OfflineFailure('simulated Vault failure') }
        env.PASS_OGG = passwords[binding.vaultKey]
        try { return body() } finally { env.remove('PASS_OGG') }
    }
    Object input(Map options) {
        assert options.id == 'confirm' && options.ok == 'Yes' && !options.containsKey('submitter')
        assert env.PASS_OGG in passwords.values()
        events << 'confirm'
        if (failureMode == 'confirm') { throw new OfflineFailure('simulated operator rejection') }
        'Yes'
    }
    void container(String name, Closure body) {
        assert name == 'ansible' && events.contains('confirm')
        inContainer = name; events << 'container'
        try { body() } finally { inContainer = null }
    }
    void withEnv(List bindings, Closure body) {
        Map previous = [:]; Set absent = [] as Set
        bindings.each { binding ->
            int split = binding.indexOf('='); String key = binding.substring(0, split)
            if (env.containsKey(key)) { previous[key] = env[key] } else { absent.add(key) }
            env[key] = binding.substring(split + 1)
        }
        try { body() } finally { absent.each { env.remove(it) }; previous.each { key, value -> env[key] = value } }
    }
    void writeFile(Map file) {
        assert inContainer == 'ansible' && env.PASS_OGG in passwords.values()
        assert passwords.values().every { !file.text.contains(it) }
        events << "write:${file.file}".toString(); writes << file
        if (failureMode == 'playbook-write' && file.file == 'start_ogg_services.yml') { throw new OfflineFailure('simulated playbook write failure') }
        if (failureMode == 'vars-write' && file.file == 'temp_vars.yml') { throw new OfflineFailure('simulated vars write failure') }
    }
    void sh(Object command) {
        assert inContainer == 'ansible'
        String text = command.toString()
        if (text.startsWith('rm -f --')) {
            assert text == 'rm -f -- temp_vars.yml "${OGG_PLAYBOOK}"'
            cleanups << text; events << 'cleanup'
        } else {
            assert writes*.file == ['start_ogg_services.yml', 'temp_vars.yml']
            commands << [text: text, environment: new LinkedHashMap(env)]; events << 'execute'
            if (failureMode == 'ansible') { throw new OfflineFailure('simulated Ansible failure') }
        }
    }
}

File root = args ? new File(args[0]) : new File('.')
File fixtures = args.length > 1 ? new File(args[1]) : null
String original = new File(root, 'jenkins/Jenkinsfile_run_start_service.groovy').getText('UTF-8')
String configured = original.replace('/path/to/file/start_ogg_services.sh', '/opt/ogg/start_ogg_services.sh')
CompilerConfiguration compiler = new CompilerConfiguration(scriptBaseClass: MockJenkins.name)
int passed = 0

def exercise = { Map options ->
    def pipeline = (MockJenkins) new GroovyShell(MockJenkins.class.classLoader,
        new Binding([POD_LABEL: 'mock-pod', scm: 'configured-scm']), compiler).parse(options.source ?: configured)
    pipeline.getEnv().JENKINS_URL = options.containsKey('url') ? options.url : 'https://jenkins-dev.example.test/'
    pipeline.getParams().ENVIRONMENT = options.containsKey('cluster') ? options.cluster : 'pt'
    pipeline.getParams().TARGET_SITE = options.containsKey('site') ? options.site : 'DC'
    pipeline.setFailureMode(options.failureMode ?: '')
    pipeline.setInventoryExists(!options.missingInventory)
    if (options.containsKey('availableKeys')) { pipeline.setAvailableKeys(options.availableKeys as Set) }
    String failure = null
    try { pipeline.run() } catch (OfflineFailure ex) { failure = ex.message }
    catch (InterruptedException ex) {
        if (!options.interrupted) { throw ex }
        failure = ex.message
    }
    if (options.expected) { assert failure?.contains(options.expected): "Expected '${options.expected}', got '${failure}'" }
    else { assert failure == null: failure }
    assert pipeline.inContainer == null && !pipeline.env.containsKey('PASS_OGG') && !pipeline.env.containsKey('TEST_VAULT') && !pipeline.env.containsKey('OGG_TARGET_GROUP')
    assert pipeline.passwords.values().every { !pipeline.logs.join('\n').contains(it) }
    assert pipeline.definitions*.name == ['ENVIRONMENT', 'TARGET_SITE']
    assert pipeline.definitions[0].choiceType == 'PT_RADIO'
    assert pipeline.definitions[1].choices == ['SELECT_SITE', 'DC', 'DR']
    assert pipeline.events.indexOf('pod') > pipeline.events.lastIndexOf('configuration')
    pipeline
}

[
    [tier: 'dev', url: 'https://jenkins-dev.example.test/', clusters: ['pt', 'sit', 'techupgrade'], vault: 'https://vault-dev.example.com/', role: 'example-vault-dev-approle'],
    [tier: 'prod', url: 'https://jenkins.example.com/', clusters: ['corelive1a', 'corelive1b'], vault: 'https://vault.example.com/', role: 'example-vault-prod-approle']
].each { config ->
    config.clusters.each { cluster ->
        ['DC', 'DR'].each { site ->
            def result = exercise([url: config.url, cluster: cluster, site: site])
            assert result.probeCalls.size() == 1 && result.vaultCalls.size() == 1
            String expectedKey = site == 'DC' ? 'oggnode1_ansible_password' : 'oggnode2_ansible_password'
            def vault = result.vaultCalls[0]
            assert vault.configuration == [vaultUrl: config.vault, vaultCredentialId: config.role, engineVersion: 2]
            assert vault.vaultSecrets[0].path == "kv2/ogg/${cluster}/secret"
            assert vault.vaultSecrets[0].secretValues == [[envVar: 'PASS_OGG', vaultKey: expectedKey]]
            assert result.probeCalls[0].configuration == vault.configuration
            assert result.probeCalls[0].vaultSecrets[0].path == vault.vaultSecrets[0].path
            assert result.probeCalls[0].vaultSecrets[0].secretValues == [[envVar: 'TEST_VAULT', vaultKey: expectedKey]]
            assert result.events.indexOf('checkout') < result.events.indexOf('probe')
            assert result.events.indexOf('probe') < result.events.indexOf('vault')
            assert result.events.indexOf('vault') < result.events.indexOf('confirm')
            assert result.events.indexOf('confirm') < result.events.indexOf('container')
            assert result.events.indexOf('container') < result.events.indexOf('write:start_ogg_services.yml')
            assert result.events.indexOf('write:temp_vars.yml') < result.events.indexOf('execute')
            assert result.events[-1] == 'cleanup' && result.cleanups.size() == 1
            assert result.writes[0].text.contains('hosts: localhost') && result.writes[0].text.contains('hosts: "{{ ogg_target_group }}"')
            assert result.writes[1].text.contains("lookup('env', 'PASS_OGG')")
            assert result.passwords.values().every { !result.writes[1].text.contains(it) }
            def call = result.commands[0]
            assert call.environment.PASS_OGG == result.passwords[expectedKey]
            assert call.environment.OGG_INVENTORY == "inventory/database/t24/${config.tier}/${cluster}.ini"
            assert call.environment.OGG_TARGET_GROUP == "ogg_${site}"
            assert call.environment.OGG_PLAYBOOK == 'start_ogg_services.yml'
            assert call.environment.OGG_START_SCRIPT == '/opt/ogg/start_ogg_services.sh'
            assert call.text.contains('--limit "${OGG_TARGET_GROUP},localhost"') && call.text.contains('-e @temp_vars.yml')
            assert result.passwords.values().every { !call.text.contains(it) }
            assert result.definitions[0].script.script.script.contains(config.tier == 'prod' ? 'corelive1a:selected' : 'pt:selected')
            if (fixtures) {
                String stem = "${config.tier}-${cluster}-${site}"
                new File(fixtures, "${stem}-playbook.yml").setText(result.writes[0].text, 'UTF-8')
                new File(fixtures, "${stem}-vars.yml").setText(result.writes[1].text, 'UTF-8')
                new File(fixtures, "${stem}-shell.sh").setText(call.text, 'UTF-8')
            }
            passed++; println "PASS: ${config.tier}/${cluster}/${site}: configuration -> pod -> checkout -> Vault -> confirm -> write playbook -> Ansible -> cleanup"
        }
    }
}

[null, 'https://another-jenkins.example.test/'].each { url ->
    def result = exercise([url: url])
    assert result.commands[0].environment.OGG_INVENTORY == 'inventory/database/t24/dev/pt.ini'
    passed++; println 'PASS: non-production Jenkins follows the reference development branch without an allowlist'
}
[null, '', 'SELECT_SITE', 'OTHER'].each { site ->
    def result = exercise([site: site, expected: 'Select DC or DR'])
    assert result.vaultCalls.isEmpty() && result.writes.isEmpty()
    passed++; println 'PASS: invalid site stops before Vault and playbook generation'
}
[null, '', 'corelive1a', '../other'].each { cluster ->
    def result = exercise([cluster: cluster, expected: 'Select a valid ENVIRONMENT'])
    assert result.vaultCalls.isEmpty() && result.writes.isEmpty()
    passed++; println 'PASS: invalid cluster stops before Vault and playbook generation'
}
['DC', 'DR'].each { site ->
    def result = exercise([source: original, site: site, expected: 'Replace the scriptPath placeholder'])
    assert result.vaultCalls.isEmpty() && result.writes.isEmpty()
    passed++; println 'PASS: approved placeholder still blocks service execution'
}
def missing = exercise([missingInventory: true, expected: 'Required SCM inventory not found'])
assert missing.vaultCalls.isEmpty() && missing.writes.isEmpty()
passed++; println 'PASS: missing inventory fails without an inline/static-playbook fallback'

['DC', 'DR'].each { site ->
    String selectedKey = site == 'DC' ? 'oggnode1_ansible_password' : 'oggnode2_ansible_password'
    String otherKey = site == 'DC' ? 'oggnode2_ansible_password' : 'oggnode1_ansible_password'
    def missingSelected = exercise([site: site, availableKeys: [otherKey], expected: "Vault key '${selectedKey}'"])
    assert missingSelected.probeCalls.size() == 1 && missingSelected.vaultCalls.isEmpty() && missingSelected.writes.isEmpty()
    assert !missingSelected.events.contains('confirm')
    passed++; println "PASS: ${site} missing selected key stops before execution; no fallback to the other node"
    def missingOther = exercise([site: site, availableKeys: [selectedKey]])
    assert missingOther.probeCalls.size() == 1 && missingOther.vaultCalls.size() == 1
    assert missingOther.probeCalls[0].vaultSecrets[0].secretValues[0].vaultKey == selectedKey
    passed++; println "PASS: ${site} works when only its selected key is available; the other node is not queried"
}
def failedProbe = exercise([failureMode: 'probe-failure', expected: 'is unavailable'])
assert failedProbe.vaultCalls.isEmpty() && failedProbe.writes.isEmpty()
passed++; println 'PASS: failed Vault probe blocks execution with a key/path/permissions error'
def interruptedProbe = exercise([failureMode: 'probe-interrupted', interrupted: true, expected: 'simulated Vault probe interruption'])
assert interruptedProbe.vaultCalls.isEmpty() && interruptedProbe.writes.isEmpty()
passed++; println 'PASS: Vault probe interruption is propagated rather than treated as a missing key'

['checkout': 'simulated SCM failure', 'vault': 'simulated Vault failure', 'confirm': 'simulated operator rejection',
 'playbook-write': 'simulated playbook write failure', 'vars-write': 'simulated vars write failure', 'ansible': 'simulated Ansible failure'].each { mode, expected ->
    def result = exercise([failureMode: mode, expected: expected])
    assert result.commands.size() == (mode == 'ansible' ? 1 : 0)
    assert result.cleanups.size() == (mode in ['playbook-write', 'vars-write', 'ansible'] ? 1 : 0)
    passed++; println "PASS: ${mode} failure propagates; generated files cleaned when generation began"
}
println "Offline reference-workflow checks: ${passed} PASS. No real pod, SCM, Vault, approval, Ansible, SSH, or services used."
