#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path


ORGANIZATION = "labview-benchmark-actor-plugins"
REPOSITORY_PATTERN = re.compile(r"^labview-benchmark-actor-plugins/[A-Za-z0-9_.-]+$")
VALID_STATUSES = {"needs-classification", "ready", "blocked"}
DEFAULT_CATALOG = Path(__file__).resolve().parents[1] / "catalog" / "modules.json"


def build_plan(catalog):
    if not isinstance(catalog, dict) or catalog.get("schemaVersion") != "1.0":
        raise ValueError("Catalog must be an object with schemaVersion '1.0'.")
    if catalog.get("organization") != ORGANIZATION:
        raise ValueError(f"Catalog organization must be '{ORGANIZATION}'.")
    modules = catalog.get("modules")
    if not isinstance(modules, list):
        raise ValueError("Catalog modules must be an array.")

    by_repository = {}
    for module in modules:
        if not isinstance(module, dict):
            raise ValueError("Every catalog module must be an object.")
        repository = module.get("repository")
        if not isinstance(repository, str) or not REPOSITORY_PATTERN.fullmatch(repository):
            raise ValueError(f"Invalid or unapproved repository: {repository!r}.")
        if repository in by_repository:
            raise ValueError(f"Duplicate repository in catalog: {repository}.")
        if module.get("status") not in VALID_STATUSES:
            raise ValueError(f"Invalid status for {repository}: {module.get('status')!r}.")
        if not isinstance(module.get("enabled"), bool):
            raise ValueError(f"Module {repository} must set enabled to a boolean.")
        dependencies = module.get("dependsOn")
        if not isinstance(dependencies, list) or any(not isinstance(item, str) for item in dependencies):
            raise ValueError(f"Module {repository} dependsOn must be an array of repository names.")
        if len(dependencies) != len(set(dependencies)):
            raise ValueError(f"Module {repository} has duplicate dependencies.")
        if repository in dependencies:
            raise ValueError(f"Module {repository} cannot depend on itself.")

        if module["enabled"]:
            if module["status"] != "ready":
                raise ValueError(f"Enabled module {repository} must have status 'ready'.")
            workflow = module.get("releaseWorkflow")
            if not isinstance(workflow, str) or not workflow.startswith(".github/workflows/") or ".." in Path(workflow).parts:
                raise ValueError(f"Enabled module {repository} must declare a safe releaseWorkflow path.")
        by_repository[repository] = module

    for repository, module in by_repository.items():
        for dependency in module["dependsOn"]:
            if dependency not in by_repository:
                raise ValueError(f"Module {repository} depends on unknown catalog repository {dependency}.")

    enabled = {repository: module for repository, module in by_repository.items() if module["enabled"]}
    for repository, module in enabled.items():
        for dependency in module["dependsOn"]:
            if dependency not in enabled:
                raise ValueError(
                    f"Enabled module {repository} depends on non-enabled module {dependency}; "
                    "enable the full release dependency chain or consume a previously published release."
                )

    state = {}
    ordered = []

    def visit(repository):
        current_state = state.get(repository, 0)
        if current_state == 1:
            raise ValueError(f"Dependency cycle detected at {repository}.")
        if current_state == 2:
            return
        state[repository] = 1
        for dependency in sorted(enabled[repository]["dependsOn"]):
            visit(dependency)
        state[repository] = 2
        ordered.append(repository)

    for repository in sorted(enabled):
        visit(repository)

    excluded = [
        {"repository": repository, "status": module["status"], "reason": "disabled"}
        for repository, module in sorted(by_repository.items())
        if not module["enabled"]
    ]
    return {"organization": ORGANIZATION, "buildOrder": ordered, "excluded": excluded}


def render_markdown(plan):
    lines = ["## ProjectBuddy build plan", ""]
    if plan["buildOrder"]:
        lines.extend(["### Release order", ""])
        lines.extend(f"{index}. `{repository}`" for index, repository in enumerate(plan["buildOrder"], start=1))
    else:
        lines.extend(["No modules are currently enabled and release-ready; no build was dispatched."])
    if plan["excluded"]:
        lines.extend(["", "### Not scheduled", ""])
        lines.extend(f"- `{item['repository']}` ({item['status']}; {item['reason']})" for item in plan["excluded"])
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate the ProjectBuddy module catalog and print a safe build plan.")
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    args = parser.parse_args(argv)

    try:
        catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
        plan = build_plan(catalog)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"ProjectBuddy build plan: FAIL: {error}", file=sys.stderr)
        return 2

    if args.format == "markdown":
        print(render_markdown(plan), end="")
    else:
        print(json.dumps(plan, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())