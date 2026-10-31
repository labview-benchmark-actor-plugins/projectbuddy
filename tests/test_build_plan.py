import json
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build_plan import build_plan, render_markdown


class BuildPlanTests(unittest.TestCase):
    def make_module(self, name, *, role="plugin-module", enabled=False, status="needs-classification", depends_on=None, workflow=None, blockers=None):
        module = {
            "repository": f"labview-benchmark-actor-plugins/{name}",
            "testedSourceRepository": f"svelderrainruiz/{name}",
            "role": role,
            "status": status,
            "enabled": enabled,
            "dependsOn": depends_on or [],
            "classificationNotes": [],
            "blockers": blockers or [],
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
        self.assertIn("Tested source: `svelderrainruiz/core`", render_markdown(plan))
        modules = {module["repository"].rsplit("/", 1)[-1]: module for module in catalog["modules"]}
        self.assertEqual(modules["dependencies"]["role"], "shared-dependency-package")
        self.assertEqual(modules["modules"]["role"], "integration-aggregate")
        self.assertEqual(modules["modules"]["status"], "blocked")
        self.assertIn("deprecated", " ".join(modules["modules"]["classificationNotes"]).lower())
        self.assertIn("coordinator Launcher EXE build spec", " ".join(modules["modules"]["classificationNotes"]))
        self.assertEqual(modules["testcoordinator"]["role"], "test-harness")
        dependency_notes = " ".join(modules["dependencies"]["classificationNotes"])
        self.assertIn("tested-fork and org profiles allow only native-windows", dependency_notes)
        self.assertIn("lba-plugins-dependencies-ppl spec producing dependencies.lvlibp", dependency_notes)
        self.assertIn("Dependencies_lba-plugins-dependencies-ppl.cdx.sbom.json", dependency_notes)
        self.assertIn("no generated SBOM is present locally", dependency_notes)
        self.assertIn("published as its own immutable release asset", dependency_notes)
        self.assertIn("no cross-repository source dependency", dependency_notes)
        self.assertIn("org Dependencies.lvproj defines a source-distribution spec but no PPL spec", dependency_notes)
        self.assertIn("VIPB remains under development and open for contribution", dependency_notes)
        replay_notes = " ".join(modules["replay"]["classificationNotes"])
        self.assertIn("tested fork also has a separate replay source-distribution build spec", replay_notes)
        self.assertIn("the org Replay project lacks", replay_notes)
        self.assertIn("Neither Replay Launcher EXE build spec declares Bld_sbomFile", replay_notes)
        coordinator_notes = " ".join(modules["testcoordinator"]["classificationNotes"])
        self.assertIn("TestCoordinator.exe", coordinator_notes)
        self.assertIn("testcoordinator_TestCoordinatorx64.cdx.sbom.json", coordinator_notes)
        self.assertIn("No generated TestCoordinator SBOM is present locally", coordinator_notes)
        self.assertIn("all 51 project URLs were unresolved", coordinator_notes)
        self.assertIn("dependencies.lvlibp in the SandboxSBOMReporting checkout root", coordinator_notes)
        self.assertIn("not a source dependency of the dependencies producer", coordinator_notes)
        coordinator_blockers = " ".join(modules["testcoordinator"]["blockers"])
        self.assertIn("stage the exact pinned dependencies.lvlibp release at the SandboxSBOMReporting checkout root", coordinator_blockers)
        self.assertIn("../Libraries references", coordinator_blockers)
        self.assertFalse(any(module["enabled"] for module in catalog["modules"]))
        self.assertTrue(modules["dependencies"]["blockers"])

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
            self.make_catalog([self.make_module("plugin") | {"testedSourceRepository": "invalid"}]),
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

    def test_enabled_module_with_blockers_is_rejected(self):
        module = self.make_module(
            "plugin",
            enabled=True,
            status="ready",
            workflow=".github/workflows/release.yml",
            blockers=["unresolved checkout dependency"],
        )
        with self.assertRaisesRegex(ValueError, "cannot have unresolved blockers"):
            build_plan(self.make_catalog([module]))


if __name__ == "__main__":
    unittest.main()