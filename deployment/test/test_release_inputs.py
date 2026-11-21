"""Release-input checks, using only the standard library so CI can run them first."""

import re
import runpy
import unittest
from collections import Counter
from pathlib import Path
from tempfile import TemporaryDirectory

DEPLOYMENT = Path(__file__).resolve().parents[1]
REPO = DEPLOYMENT.parent
CHECK = runpy.run_path(str(DEPLOYMENT / "check-secrets.py"))
SEED = runpy.run_path(str(DEPLOYMENT / "demo/build-seed.py"))


class ReleaseInputsTest(unittest.TestCase):
    def test_local_files_are_rejected_but_frontend_defaults_are_allowed(self):
        for name in (
            "deployment/.dev-ssh.json",
            "deployment/offline/data/01-mysql-all.sql.gz",
            "deployment/.run/debug.json",
            "deployment/build-manifest.json",
            "deployment/init/02-demo-accounts.sql",
            "deployment/demo/demo.env",
            "mall-agent/.env",
            "mall-app-web/.env.production.local",
        ):
            with self.subTest(name=name):
                self.assertTrue(CHECK["is_private_path"](name))
        for name in ("mall-app-web/.env.production", "mall-agent/.env.example", "deployment/.dev-ssh.example.json"):
            with self.subTest(name=name):
                self.assertFalse(CHECK["is_private_path"](name))

    def test_scanner_reports_locations_without_password_values(self):
        payload = 'def demo():\n    return {"password": "private fixture only"}\n'
        relpath = "mall-agent/scripts/demo_fixture.py"
        with TemporaryDirectory() as directory:
            root = Path(directory)
            p = root / relpath
            p.parent.mkdir(parents=True)
            p.write_text(payload, encoding="utf-8")
            found = CHECK["scan"](relpath, root, SEED["PUBLIC_SOURCE_TABLES"])
        self.assertEqual(found, [f"{relpath}:2: hardcoded-development-password"])

    def test_public_sql_only_seeds_allowlisted_tables(self):
        for relpath in sorted(CHECK["PUBLIC_SEEDS"]):
            with self.subTest(relpath=relpath):
                p = REPO / relpath
                self.assertEqual(CHECK["scan"](relpath, REPO, SEED["PUBLIC_SOURCE_TABLES"]), [])
                rows = Counter(CHECK["PUBLIC_SEED_INSERT"].findall(p.read_text(encoding="utf-8")))
                self.assertTrue(SEED["KEEP"].issubset(rows))
                self.assertFalse({"ums_admin", "ums_member", "oms_cart_item", "oms_order"}.intersection(rows))

    def test_bundled_image_references_have_files(self):
        text = (DEPLOYMENT / "init/01-mall.sql").read_text(encoding="utf-8")
        files = set(re.findall(r"/demo-assets/([A-Za-z0-9_.-]+)", text))
        self.assertIn("unavailable.svg", files)
        self.assertTrue(all((DEPLOYMENT / "demo/assets" / name).is_file() for name in files))


if __name__ == "__main__":
    unittest.main()
