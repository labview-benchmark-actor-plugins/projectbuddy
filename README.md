# ProjectBuddy

ProjectBuddy defines reusable build and release contracts for LabVIEW modules.
The `labview-benchmark-actor-plugins/projectbuddy` fork is intended to hold the
organization-specific module inventory and orchestrate trusted release runs.
Individual module repositories own their source and publish their own releases.

## Release manifest

Every release should include a `release-manifest.json` conforming to
[`schemas/release-manifest.schema.json`](schemas/release-manifest.schema.json).
The manifest binds the repository, immutable release tag, source commit, package
versions, LabVIEW/VIPM toolchain, exact dependency versions, published release
assets, matching CycloneDX SBOMs, digests, runner build outputs, and successful
test runs. A release may contain multiple asset types; each SBOM names its
released asset id, kind, and version.

For container builds, `toolchain.labviewBaseImageDigest` records the immutable
NI LabVIEW image reference. If that image supplies the LabVIEW VILib package,
`toolchain.labviewVilib` records its actual `installedVersion` and uses
`source: preinstalled-base-image`; do not claim a manifest package version that
the builder did not install. VILib provenance requires the image digest.
`toolchain.vipmVersion` records the VIPM CLI
version; `toolchain.vipmDesktopVersion` optionally records the separately pinned
Desktop version.

`artifacts.releaseAssets` contains only files published with the release.
`validation.buildOutputs` separately records build specs and outcomes. An
executable output must be executed on the build runner, but it does not have to
be published as a separate release asset. If a VIP includes that executable,
`includedInReleaseAsset` identifies the containing VIP asset.

Build-time LVLIBP dependencies can be pinned to an immutable release by
repository, tag, version, and asset filename. Their `stagePath` is relative to
the consumer workflow checkout root, not the module checkout. For
TestCoordinator's `../../dependencies.lvlibp` project URL, this is
`dependencies.lvlibp` at the SandboxSBOMReporting checkout root. A source
checkout alone does not satisfy this dependency. The local stager verifies the
dependency release manifest and asset digest before copying the file, refuses
path escapes, linked staging paths, and conflicting overwrites, and does not
fetch the release itself. The caller must prevent concurrent changes to the
artifact directory and workspace during verification and staging.

For GitHub releases, download the pinned release's `release-manifest.json` and
every asset listed in it, then use
`scripts/stage-immutable-release-dependency.ps1` with the same arguments as the
local stager. It requires GitHub CLI with `gh release verify`, checks that the
exact tag currently names a published immutable release, verifies GitHub's signed
release attestation, and matches the source commit and named asset digests before
staging. It does not download assets. The release manifest's `immutable` field
alone is not proof.

The tested `svelderrainruiz/dependencies` producer has no cross-repository source
dependency. TestCoordinator consumes the published LVLIBP as a build dependency;
its release pin is separate from the producer's own source and package inputs.

The validator in `scripts/validate-release-manifest.ps1` checks schema shape,
repository/tag identity, exact dependency versions, build-output inclusion,
one matching CycloneDX SBOM per published asset, and the size and SHA-256 digest
of every local release asset. Linked artifact directories and assets are rejected.
Consumers must
also verify GitHub release/tag immutability through the GitHub API or equivalent
protected-tag evidence; the manifest's `immutable: true` field is a claim, not
proof by itself.

The example in [`examples/release-manifest.json`](examples/release-manifest.json)
is synthetic. Its file sizes, digests, commit, and run URL are placeholders and
must not be published as release evidence.

`tests/Test-ReleaseManifest.ps1` accepts `-CandidateArtifactDirectory` to run
the staging checks with a downloaded candidate's LVLIBP and SBOM after checking
their sizes, hashes, and recorded file/product versions against its build record.
On Windows it independently reads the LVLIBP's embedded versions; on other
platforms the recorded versions remain unverified claims. The release tag and
release manifest in that test remain synthetic; this does not verify a published release
or establish complete SBOM coverage.
The ProjectBuddy plan workflow also runs the synthetic release-contract tests on
hosted Linux and Windows; those tests do not publish releases or require LabVIEW.

## Org build plan

`catalog/modules.json` is the org control-plane inventory. `repository` names
the org promotion target; `testedSourceRepository` names the personal fork
selected by SandboxSBOMReporting and is the source of test evidence. These are
separate identities because org repositories can differ materially from tested
forks. Entries start disabled with classification notes and blockers. The
`modules` aggregate is deprecated and retained only as historical context, not
as a release candidate. The plan workflow does not dispatch builds. A module can be enabled only after it
is classified as release-ready, all blockers are resolved, and it has a safe
repository-local release workflow. Dependencies are ordered before consumers;
missing, disabled, or cyclic release dependencies fail plan validation. The
six standalone org targets remain disabled while source alignment, SBOM
coverage, package boundaries, and producer workflows are being established.

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