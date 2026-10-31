import json
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build_plan import build_plan, render_markdown


class BuildPlanTests(unittest.TestCase):
    def make_module(self, name, *, enabled=False, status="needs-classification", depends_on=None, workflow=None):
        module = {
            "repository": f"labview-benchmark-actor-plugins/{name}",
            "status": status,
            "enabled": enabled,
            "dependsOn": depends_on or [],
        }
        if workflow is not None:
            module["releaseWorkflow"] = workflow
        return module

    def make_catalog(self, modules):
        return {"schemaVersion": "1.0", "organization": "labview-benchmark-actor-plugins", "modules": modules}

    def test_checked_in_catalog_is_plan_only_until_modules_are_classified(self):
        catalog = json.loads((ROOT / "catalog" / "modules.json").read_text(encoding="utf-8"))
        plan = build_plan(catalog)
        self.assertEqual(plan["buildOrder"], [])
        self.assertEqual(len(plan["excluded"]), 7)
        self.assertIn("no build was dispatched", render_markdown(plan))

    def test_ready_modules_follow_dependency_order(self):
        modules = [
            self.make_module("plugin", enabled=True, status="ready", depends_on=["labview-benchmark-actor-plugins/dependencies"], workflow=".github/workflows/release.yml"),
            self.make_module("dependencies", enabled=True, status="ready", workflow=".github/workflows/release.yml"),
        ]
        plan = build_plan(self.make_catalog(modules))
        self.assertEqual(plan["buildOrder"], [
            "labview-benchmark-actor-plugins/dependencies",
            "labview-benchmark-actor-plugins/plugin",
        ])

    def test_unknown_owner_duplicate_and_nonready_enabled_modules_fail_closed(self):
        cases = [
            self.make_catalog([self.make_module("plugin") | {"repository": "outside-org/plugin"}]),
            self.make_catalog([self.make_module("plugin"), self.make_module("plugin")]),
            self.make_catalog([self.make_module("plugin", enabled=True, status="needs-classification", workflow=".github/workflows/release.yml")]),
        ]
        for catalog in cases:
            with self.subTest(catalog=catalog):
                with self.assertRaises(ValueError):
                    build_plan(catalog)

    def test_unsafe_workflow_unknown_dependency_and_cycle_fail_closed(self):
        unsafe = self.make_module("plugin", enabled=True, status="ready", workflow="../release.yml")
        missing_dependency = self.make_module("plugin", enabled=True, status="ready", depends_on=["labview-benchmark-actor-plugins/missing"], workflow=".github/workflows/release.yml")
        cycle = [
            self.make_module("one", enabled=True, status="ready", depends_on=["labview-benchmark-actor-plugins/two"], workflow=".github/workflows/release.yml"),
            self.make_module("two", enabled=True, status="ready", depends_on=["labview-benchmark-actor-plugins/one"], workflow=".github/workflows/release.yml"),
        ]
        for modules in ([unsafe], [missing_dependency], cycle):
            with self.subTest(modules=modules):
                with self.assertRaises(ValueError):
                    build_plan(self.make_catalog(modules))

    def test_enabled_module_requires_its_release_dependencies_in_the_same_plan(self):
        modules = [
            self.make_module("plugin", enabled=True, status="ready", depends_on=["labview-benchmark-actor-plugins/dependencies"], workflow=".github/workflows/release.yml"),
            self.make_module("dependencies", status="ready", workflow=".github/workflows/release.yml"),
        ]
        with self.assertRaisesRegex(ValueError, "non-enabled module"):
            build_plan(self.make_catalog(modules))


if __name__ == "__main__":
    unittest.main()