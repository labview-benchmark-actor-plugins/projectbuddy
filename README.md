# ProjectBuddy

ProjectBuddy defines reusable build and release contracts for LabVIEW modules.
The `labview-benchmark-actor-plugins/projectbuddy` fork is intended to hold the
organization-specific module inventory and orchestrate trusted release runs.
Individual module repositories own their source and publish their own releases.

## Release manifest

Every release should include a `release-manifest.json` conforming to
[`schemas/release-manifest.schema.json`](schemas/release-manifest.schema.json).
The manifest binds the repository, immutable release tag, source commit, package
versions, LabVIEW/VIPM toolchain, exact dependency versions, package assets,
matching CycloneDX SBOMs, digests, and successful test runs. A release may
contain multiple package artifacts; every SBOM names its package id and version.

The validator in `scripts/validate-release-manifest.ps1` checks schema shape,
repository/tag identity, exact dependency versions, package-to-SBOM bindings,
and the size and SHA-256 digest of every local release asset. Consumers must
also verify GitHub release/tag immutability through the GitHub API or equivalent
protected-tag evidence; the manifest's `immutable: true` field is a claim, not
proof by itself.

The example in [`examples/release-manifest.json`](examples/release-manifest.json)
is synthetic. Its file sizes, digests, commit, and run URL are placeholders and
must not be published as release evidence.

## Org build plan

`catalog/modules.json` is the org control-plane inventory. Entries start
disabled with `needs-classification`; the plan workflow does not dispatch
builds. A module can be enabled only after it is classified as release-ready
and has a safe repository-local release workflow. Dependencies are ordered
before consumers; missing, disabled, or cyclic release dependencies fail plan
validation.

Run the plan and tests locally with:

```bash
python3 scripts/build_plan.py --format markdown
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

The GitHub workflow is plan-only. Cross-repository dispatch and Windows release
execution remain disabled until the org runner group and least-privilege app are
authorized.

## Current scope

The initial contract and example do not build LabVIEW packages. The reusable
Windows producer workflow, organization runner authorization, GitHub App
installation, and module inventory are tracked separately in the release
integration issues in SandboxSBOMReporting.