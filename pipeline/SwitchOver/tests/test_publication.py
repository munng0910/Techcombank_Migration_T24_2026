"""Offline checks for the SwitchOver publication boundary; no live services used."""

import configparser
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
import unittest
from urllib.parse import unquote, urlsplit


class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.links.extend(value for name, value in attrs if name == "href" and value)


ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, capture_output=True
    ).stdout


def publication_files():
    paths = git("ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", ".")
    return sorted({Path(p.decode("utf-8")) for p in paths.split(b"\0") if p})


class PublicationTests(unittest.TestCase):
    def test_only_reviewed_locations_are_candidates(self):
        root_files = {"README.md", ".gitignore", ".gitattributes"}
        directories = {"archive", "config", "docs", "jenkins", "scripts", "tests"}
        for path in publication_files():
            with self.subTest(path=str(path)):
                if len(path.parts) == 1:
                    self.assertIn(path.name, root_files)
                else:
                    self.assertIn(path.parts[0], directories)
                self.assertNotIn(path.suffix.lower(), {".docx", ".log", ".out", ".pem", ".key"})
                if path.suffix.lower() == ".ini":
                    self.assertEqual(path.parent, Path("config/examples"))

    def test_private_originals_and_inventory_are_ignored(self):
        originals = {
            "jenkins": ["Jenkinsfile_ogg_operational.groovy", "Jenkinsfile_ogg_operational_v2310.groovy", "Jenkinsfile_run_start_service.groovy"],
            "scripts": ["OGGHUB_operation_actions.sh", "OGGHUB_Add-Extract_Add-Replicat.sh", "OGGHUB_Start-Extract.sh", "OGG_Failover_TCB-PT-orig.sh"],
            "tests/ogg": ["test_op_ogg_actions.sh", "test_op_ogg_wildcards.sh", "test_ogghub_add_extract_replicat.sh"],
            "orig": ["start_ogg_services.sh", "example_output.txt"],
            "markdown": ["jenkins_ogg_operational_pipeline_requirements.md", "ogg_operational_actions_script_specification.md", "prompt_orig.md", "report.md", "report_ogg_operational_switchover.html", "report_ogg_operational_switchover.docx"],
        }
        # Check hypothetical paths too: clean clones must not need private files.
        private_paths = [ROOT / "local/originals" / directory / name
                         for directory, names in originals.items() for name in names]
        private_paths.extend([ROOT / "local/originals/work_flow.txt", ROOT / "local/inventory/dev/pt.ini"])
        for path in private_paths:
            with self.subTest(path=str(path.relative_to(ROOT))):
                result = subprocess.run(
                    ["git", "check-ignore", "-q", "--", str(path)], cwd=ROOT
                )
                self.assertEqual(result.returncode, 0)

    def test_example_inventory_is_sanitized_and_publishable(self):
        self.assertIn(Path("config/examples/pt.ini"), publication_files())
        inventory = configparser.ConfigParser(interpolation=None, allow_no_value=True)
        inventory.read(ROOT / "config/examples/pt.ini", encoding="utf-8")
        for group in ("ogg_DC", "ogg_DR"):
            hosts = list(inventory[group])
            self.assertEqual(len(hosts), 1)
            self.assertTrue(hosts[0].split()[0].endswith(".invalid"))
        self.assertEqual(inventory["ogg_targets:vars"]["ansible_user"], "localpwm")
        self.assertNotIn("StrictHostKeyChecking=no", (ROOT / "config/examples/pt.ini").read_text())

    def test_candidate_text_has_no_password_connect_examples_or_private_keys(self):
        password_connect = re.compile(r"\bconnect\s+https?://[^\r\n]*\bpassword\b", re.I)
        key_headers = ["-----BEGIN " + kind + "PRIVATE KEY-----" for kind in ("", "RSA ", "EC ", "OPENSSH ")]
        for path in publication_files():
            text = (ROOT / path).read_text(encoding="utf-8")
            with self.subTest(path=str(path)):
                self.assertIsNone(password_connect.search(text), "Password-based CONNECT example needs review")
                for header in key_headers:
                    self.assertNotIn(header, text)

    def test_document_links_resolve_to_publishable_module_files(self):
        candidates = publication_files()
        published = {(ROOT / path).resolve() for path in candidates}
        for path in candidates:
            if path.suffix not in {".md", ".html"}:
                continue
            text = (ROOT / path).read_text(encoding="utf-8")
            if path.suffix == ".html":
                parser = LinkParser()
                parser.feed(text)
                links = parser.links
            else:
                links = re.findall(r"\[[^\]]+\]\(([^)]+)\)", text)
            for link in links:
                target = urlsplit(link)
                if target.scheme or target.netloc or not target.path:
                    continue
                with self.subTest(source=str(path), link=link):
                    destination = (ROOT / path.parent / unquote(target.path)).resolve()
                    self.assertIn(destination, published, "Link must resolve to a published module file")

    def test_shell_files_use_lf_and_test_targets_exist(self):
        for directory in ("scripts", "tests/ogg"):
            for path in (ROOT / directory).glob("*.sh"):
                with self.subTest(path=str(path.relative_to(ROOT))):
                    self.assertNotIn(b"\r", path.read_bytes())
        for name in ("test_op_ogg_actions.sh", "test_op_ogg_wildcards.sh", "test_ogghub_add_extract_replicat.sh"):
            source = (ROOT / "tests/ogg" / name).read_text(encoding="utf-8")
            target = re.search(r"^SCRIPT=.*\)/([^\n]+)$", source, re.M)
            self.assertIsNotNone(target, name)
            self.assertTrue((ROOT / target.group(1)).is_file(), name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
