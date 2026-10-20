"""Offline checks of the playbook/vars generated inside the Ansible pod.

These tests evaluate YAML/Jinja expressions; they do not run Ansible or SSH.
"""
from copy import deepcopy
from pathlib import Path
import re
import unittest
from uuid import uuid4

import yaml
from jinja2 import Environment, StrictUndefined


WORKSPACE = Path(__file__).resolve().parents[2]
JENKINSFILE = WORKSPACE / "jenkins/Jenkinsfile_run_start_service.groovy"


def generated_text(source, file_expression):
    pattern = r"writeFile file: " + re.escape(file_expression) + r", text: '''(.*?)'''\.stripMargin\(\)"
    match = re.search(pattern, source, re.S)
    if not match:
        raise AssertionError(f"Missing generated file template: {file_expression}")
    return re.sub(r"^[ \t]*\|", "", match.group(1), flags=re.M)


class GeneratedStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = JENKINSFILE.read_text(encoding="utf-8")
        cls.playbook_text = generated_text(cls.source, "ctx.playbookPath")
        cls.vars_text = generated_text(cls.source, "'temp_vars.yml'")
        cls.plays = yaml.safe_load(cls.playbook_text)
        cls.variables = yaml.safe_load(cls.vars_text)
        if not isinstance(cls.plays, list) or len(cls.plays) != 2:
            raise AssertionError("Expected pod-local inventory validation followed by selected-site execution")

    def setUp(self):
        self.environment = {
            "OGG_TARGET_GROUP": "ogg_DC",
            "OGG_START_SCRIPT": "/opt/ogg/start_ogg_services.sh",
            "PASS_OGG": uuid4().hex,
        }
        self.jinja = Environment(undefined=StrictUndefined)
        self.jinja.tests["match"] = lambda value, pattern: re.match(pattern, value) is not None
        self.jinja.globals["lookup"] = self.lookup

    def lookup(self, kind, name):
        self.assertEqual(kind, "env")
        return self.environment[name]

    def context(self, site="DC"):
        self.environment["OGG_TARGET_GROUP"] = f"ogg_{site}"
        result = {}
        for key, value in self.variables.items():
            result[key] = self.jinja.from_string(value).render(**result)
        result.update(
            ansible_check_mode=False,
            groups={"ogg_DC": ["ogg-dc"], "ogg_DR": ["ogg-dr"]},
            hostvars={"ogg-dc": {"ansible_user": "localpwm"}, "ogg-dr": {"ansible_user": "localpwm"}},
        )
        return result

    def evaluate(self, expression, context):
        return self.jinja.compile_expression(expression, undefined_to_none=False)(**context)

    def controller_accepts(self, context):
        # Stop at the first failed assertion, as Ansible does; never index an empty group.
        for task in self.plays[0]["tasks"]:
            for expression in task["ansible.builtin.assert"]["that"]:
                if not self.evaluate(expression, context):
                    return False
        return True

    def test_generation_and_reference_flow(self):
        controller, remote = self.plays
        self.assertEqual(controller["hosts"], "localhost")
        self.assertEqual(controller["connection"], "local")
        self.assertIs(controller["become"], False)
        self.assertIs(controller["gather_facts"], False)
        self.assertIs(controller["any_errors_fatal"], True)
        self.assertTrue(all("ansible.builtin.assert" in task for task in controller["tasks"]))
        self.assertEqual(remote["hosts"], "{{ ogg_target_group }}")
        self.assertEqual(remote["connection"], "ssh")
        self.assertIs(remote["gather_facts"], False)
        self.assertIs(remote["become"], True)
        self.assertEqual(remote["become_method"], "sudo")
        self.assertEqual(remote["become_user"], "oracle")
        self.assertEqual(remote["become_flags"], "-H -S -i")
        self.assertIn('--limit "${OGG_TARGET_GROUP},localhost"', self.source)
        self.assertNotIn("knownHostsCredentialId", self.source)
        self.assertNotIn("ogg-start-config.json", self.source)

    def test_both_sites_and_missing_or_invalid_inventory(self):
        for site in ("DC", "DR"):
            with self.subTest(site=site):
                context = self.context(site)
                self.assertTrue(self.controller_accepts(context))
                self.assertEqual(self.jinja.from_string(self.plays[1]["hosts"]).render(**context), f"ogg_{site}")
        valid = self.context()
        changes = [
            {"ansible_check_mode": True}, {"ogg_target_group": "db_t24live"},
            {"groups": {}}, {"groups": {"ogg_DC": []}},
            {"groups": {"ogg_DC": ["ogg-dc", "ogg-dr"]}},
            {"hostvars": {"ogg-dc": {"ansible_user": "oracle"}}},
            {"hostvars": {"ogg-dc": {}}},
            {"hostvars": {"ogg-dc": {"ansible_user": "localpwm", "ansible_connection": "local"}}},
            {"ogg_start_script": "/path/to/file/start_ogg_services.sh"},
            {"ogg_start_script": "/opt/../start.sh"}, {"ogg_start_script": "relative/start.sh"},
            {"ogg_start_script": "/opt/start.sh;id"},
        ]
        for change in changes:
            with self.subTest(change=change):
                context = deepcopy(valid)
                context.update(change)
                self.assertFalse(self.controller_accepts(context))

    def test_credentials_remain_environment_lookups(self):
        self.assertEqual(self.variables, {
            "ogg_target_group": "{{ lookup('env', 'OGG_TARGET_GROUP') }}",
            "ogg_start_script": "{{ lookup('env', 'OGG_START_SCRIPT') }}",
            "ogg_ansible_password": "{{ lookup('env', 'PASS_OGG') }}",
            "ansible_become_password": "{{ ogg_ansible_password }}",
        })
        context = self.context()
        self.assertEqual(context["ogg_ansible_password"], self.environment["PASS_OGG"])
        self.assertEqual(context["ansible_become_password"], self.environment["PASS_OGG"])
        # This is the inventory expression used for SSH; no clear password is written.
        self.assertEqual(self.jinja.from_string("{{ ogg_ansible_password }}").render(**context), self.environment["PASS_OGG"])
        for content in (self.source, self.playbook_text, self.vars_text):
            self.assertNotIn(self.environment["PASS_OGG"], content)
        self.assertNotIn("ansible_password", self.variables)

    def test_identity_guard_precedes_bash_startup(self):
        identity, startup = self.plays[1]["tasks"][:2]
        self.assertEqual(identity["ansible.builtin.command"]["argv"], ["id", "-un"])
        self.assertIs(identity["changed_when"], False)
        for rc, user, expected in ((0, "oracle\n", False), (0, "root", True), (1, "oracle", True)):
            context = {"oracle_identity": {"rc": rc, "stdout": user}}
            self.assertEqual(self.evaluate(identity["failed_when"], context), expected)
        context = self.context()
        argv = [self.jinja.from_string(value).render(**context) for value in startup["ansible.builtin.command"]["argv"]]
        self.assertEqual(argv, ["/bin/bash", "--", context["ogg_start_script"]])
        self.assertNotIn("failed_when", startup)
        for play in self.plays:
            for task in play["tasks"]:
                self.assertNotIn("ignore_errors", task)
                self.assertNotIn("rescue", task)
                self.assertNotIn("retries", task)
                self.assertNotIn("ansible.builtin.script", task)


if __name__ == "__main__":
    unittest.main()
