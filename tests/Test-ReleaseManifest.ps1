[CmdletBinding()]
param([string]$CandidateArtifactDirectory)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throw {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $false
    try { & $Action | Out-Null } catch {
        $caught = $true
        if ($_.Exception.Message -notlike $Pattern) { throw }
    }
    Assert-True $caught "Expected failure matching '$Pattern'."
}

$root = Split-Path $PSScriptRoot -Parent
$examplePath = Join-Path $root "examples/release-manifest.json"
$schemaPath = Join-Path $root "schemas/release-manifest.schema.json"
$validatorPath = Join-Path $root "scripts/validate-release-manifest.ps1"
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("projectbuddy-release-test-" + [guid]::NewGuid())
$manifestPath = Join-Path $fixtureRoot "release-manifest.json"
$dependencyArtifactRoot = Join-Path $fixtureRoot "dependency-release"
$dependencyManifestPath = Join-Path $dependencyArtifactRoot "release-manifest.json"
$dependencyAssetPath = Join-Path $dependencyArtifactRoot "dependencies.lvlibp"
$dependencySbomPath = Join-Path $dependencyArtifactRoot "dependencies.lvlibp.cdx.sbom.json"
$stageRoot = Join-Path $fixtureRoot "consumer-workspace"
$releaseAssetPath = Join-Path $fixtureRoot "replay-1.0.0.zip"
$binaryAssetPath = Join-Path $fixtureRoot "launcher-1.0.0.exe"
$sbomPath = Join-Path $fixtureRoot "replay-1.0.0.cdx.sbom.json"
$attestationPath = Join-Path $fixtureRoot "release.intoto.jsonl"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$releaseAssetBytes = $utf8NoBom.GetBytes("synthetic source archive bytes")
$attestationBytes = $utf8NoBom.GetBytes("synthetic attestation bytes")
$sbomText = '{"bomFormat":"CycloneDX","specVersion":"1.5","version":1,"metadata":{"component":{"type":"library","name":"replay-source","version":"1.0.0"}}}'

function Write-FixtureManifest {
    param($Manifest)
    $json = $Manifest | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)
}

try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $null = New-Item -ItemType Directory -Path $dependencyArtifactRoot
    $null = New-Item -ItemType Directory -Path $stageRoot
    [System.IO.File]::WriteAllBytes($releaseAssetPath, $releaseAssetBytes)
    [System.IO.File]::WriteAllText($sbomPath, $sbomText, $utf8NoBom)
    [System.IO.File]::WriteAllBytes($attestationPath, $attestationBytes)

    $manifest = Get-Content -LiteralPath $examplePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $manifest.toolchain.vipmDesktopVersion = "2026.3.2.4056"
    $manifest.toolchain.labviewBaseImageDigest = "nationalinstruments/labview@sha256:$('a' * 64)"
    $manifest.toolchain.labviewVilib = @{ installedVersion = "26.3.1.0-0+d0"; source = "preinstalled-base-image" }
    $manifest.artifacts.attestation = @{
        fileName = [System.IO.Path]::GetFileName($attestationPath)
        sizeBytes = (Get-Item -LiteralPath $attestationPath).Length
        sha256 = (Get-FileHash -LiteralPath $attestationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $manifest.artifacts.releaseAssets[0].asset.fileName = [System.IO.Path]::GetFileName($releaseAssetPath)
    $manifest.artifacts.releaseAssets[0].asset.sizeBytes = (Get-Item -LiteralPath $releaseAssetPath).Length
    $manifest.artifacts.releaseAssets[0].asset.sha256 = (Get-FileHash -LiteralPath $releaseAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.artifacts.sboms[0].asset.fileName = [System.IO.Path]::GetFileName($sbomPath)
    $manifest.artifacts.sboms[0].asset.sizeBytes = (Get-Item -LiteralPath $sbomPath).Length
    $manifest.artifacts.sboms[0].asset.sha256 = (Get-FileHash -LiteralPath $sbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-FixtureManifest $manifest

    & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath | Out-Null
    $publishedAt = $manifest.release.publishedAt
    $manifest.release.Remove("publishedAt")
    Write-FixtureManifest $manifest
    & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath | Out-Null
    $manifest.release.publishedAt = $publishedAt
    Write-FixtureManifest $manifest
    $manifest.toolchain.Remove("vipmDesktopVersion")
    $manifest.toolchain.Remove("labviewBaseImageDigest")
    $manifest.toolchain.Remove("labviewVilib")
    Write-FixtureManifest $manifest
    & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath | Out-Null
    $manifest.toolchain.vipmDesktopVersion = "2026.3.2.4056"
    $manifest.toolchain.labviewBaseImageDigest = "nationalinstruments/labview@sha256:$('a' * 64)"
    $manifest.toolchain.labviewVilib = @{ installedVersion = "26.3.1.0-0+d0"; source = "preinstalled-base-image" }
    Write-FixtureManifest $manifest
    $manifest.toolchain.Remove("labviewVilib")
    Write-FixtureManifest $manifest
    & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath | Out-Null
    $manifest.toolchain.labviewVilib = @{ installedVersion = "26.3.1.0-0+d0"; source = "preinstalled-base-image" }
    $manifest.toolchain.Remove("labviewBaseImageDigest")
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*does not satisfy the ProjectBuddy schema*"
    $manifest.toolchain.labviewBaseImageDigest = "nationalinstruments/labview:latest"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*does not satisfy the ProjectBuddy schema*"
    $manifest.toolchain.labviewBaseImageDigest = "nationalinstruments/labview@sha256:$('a' * 64)"
    $manifest.toolchain.labviewVilib.source = "manifest-pin"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*does not satisfy the ProjectBuddy schema*"
    $manifest.toolchain.labviewVilib.source = "preinstalled-base-image"
    Write-FixtureManifest $manifest

    [System.IO.File]::WriteAllText($attestationPath, "synthetic attestation byteS", $utf8NoBom)
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*SHA-256 mismatch*"
    [System.IO.File]::WriteAllBytes($attestationPath, $attestationBytes)

    [System.IO.File]::WriteAllText($releaseAssetPath, "synthetic source archive byteS", $utf8NoBom)
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*SHA-256 mismatch*"

    [System.IO.File]::WriteAllBytes($releaseAssetPath, $releaseAssetBytes)
    Remove-Item -LiteralPath $sbomPath -Force
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*Release asset is missing*"

    [System.IO.File]::WriteAllText($sbomPath, $sbomText, $utf8NoBom)
    $manifest.artifacts.releaseAssets[0].asset.sizeBytes = (Get-Item -LiteralPath $releaseAssetPath).Length
    $manifest.artifacts.releaseAssets[0].asset.sha256 = (Get-FileHash -LiteralPath $releaseAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.artifacts.sboms[0].asset.sizeBytes = (Get-Item -LiteralPath $sbomPath).Length
    $manifest.artifacts.sboms[0].asset.sha256 = (Get-FileHash -LiteralPath $sbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.artifacts.sboms[0].subjectAssetVersion = "9.9.9"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*SBOM subject does not identify a released asset*"

    $manifest.artifacts.sboms[0].subjectAssetVersion = "1.0.0"
    $mismatchedSbom = '{"bomFormat":"CycloneDX","specVersion":"1.5","version":1,"metadata":{"component":{"type":"library","name":"other","version":"1.0.0"}}}'
    [System.IO.File]::WriteAllText($sbomPath, $mismatchedSbom, $utf8NoBom)
    $manifest.artifacts.sboms[0].asset.sizeBytes = (Get-Item -LiteralPath $sbomPath).Length
    $manifest.artifacts.sboms[0].asset.sha256 = (Get-FileHash -LiteralPath $sbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*CycloneDX metadata component does not match the released asset*"

    $manifest.artifacts.sboms[0].subjectAssetVersion = "1.0.0"
    [System.IO.File]::WriteAllText($sbomPath, $sbomText, $utf8NoBom)
    $manifest.artifacts.sboms[0].asset.sizeBytes = (Get-Item -LiteralPath $sbomPath).Length
    $manifest.artifacts.sboms[0].asset.sha256 = (Get-FileHash -LiteralPath $sbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.release.immutable = $false
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*does not satisfy the ProjectBuddy schema*"

    $manifest.release.immutable = $true
    $manifest.dependencies = @(@{ ecosystem = "vipm"; name = "example"; version = "latest"; scope = "build" })
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*Floating or range dependency version is not allowed*"

    $manifest.dependencies = @(@{
        ecosystem = "lvlibp"
        name = "lba-plugins-dependencies-ppl"
        version = "1.0.0.14"
        scope = "build"
        repository = "svelderrainruiz/dependencies"
        releaseTag = "v1.0.0.14"
        assetFileName = "dependencies.lvlibp"
        stagePath = "dependencies.lvlibp"
    })

    $dependencyBytes = $utf8NoBom.GetBytes("synthetic LVLIBP release bytes")
    $dependencySbomText = '{"bomFormat":"CycloneDX","specVersion":"1.5","version":1,"metadata":{"component":{"type":"library","name":"lba-plugins-dependencies-ppl","version":"1.0.0.14"}}}'
    $dependencySbomBytes = $utf8NoBom.GetBytes($dependencySbomText)
    $candidateRecord = $null
    if (-not [string]::IsNullOrWhiteSpace($CandidateArtifactDirectory)) {
        $candidateRoot = [System.IO.Path]::GetFullPath($CandidateArtifactDirectory)
        $candidateRecordPath = Join-Path $candidateRoot "lvlibp-build-record.json"
        $candidateAssetPath = Join-Path $candidateRoot "dependencies.lvlibp"
        $candidateSbomPath = Join-Path $candidateRoot "dependencies.lvlibp.cdx.sbom.json"
        $candidateManifestPath = Join-Path $candidateRoot "vipm.toml"
        foreach ($candidatePath in $candidateRecordPath, $candidateAssetPath, $candidateSbomPath, $candidateManifestPath) {
            Assert-True (Test-Path -LiteralPath $candidatePath -PathType Leaf) "Candidate fixture input is missing: $candidatePath"
        }
        $candidateRecord = Get-Content -LiteralPath $candidateRecordPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert-True ($candidateRecord.candidateOnly -eq $true -and $candidateRecord.source.repository -ceq "svelderrainruiz/dependencies") "Candidate fixture source identity is invalid."
        Assert-True ($candidateRecord.source.commit -match '^[A-Fa-f0-9]{40}$' -and
            $candidateRecord.build.spec -ceq "lba-plugins-dependencies-ppl" -and
            $candidateRecord.build.componentName -ceq "lba-plugins-dependencies-ppl" -and
            $candidateRecord.build.componentVersion -ceq "1.0.0.14") "Candidate fixture component identity is invalid."
        $candidateVersion = [string]$candidateRecord.build.componentVersion
        Assert-True ($candidateRecord.asset.fileVersion -ceq $candidateVersion -and
            $candidateRecord.asset.productVersion -ceq $candidateVersion) "Candidate fixture record lacks matching LVLIBP file and product versions."
        if ($IsWindows) {
            $candidateVersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($candidateAssetPath)
            Assert-True ($candidateVersionInfo.FileVersion -ceq $candidateVersion -and
                $candidateVersionInfo.ProductVersion -ceq $candidateVersion) "Candidate LVLIBP embedded versions do not match its SBOM component."
        }
        foreach ($candidateAsset in @(
                @{ Path = $candidateAssetPath; Record = $candidateRecord.asset },
                @{ Path = $candidateSbomPath; Record = $candidateRecord.sbom }
            )) {
            $candidateFile = Get-Item -LiteralPath $candidateAsset.Path
            $candidateHash = (Get-FileHash -LiteralPath $candidateAsset.Path -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-True ($candidateAsset.Record.fileName -ceq $candidateFile.Name -and
                $candidateAsset.Record.sizeBytes -eq $candidateFile.Length -and
                $candidateAsset.Record.sha256 -ceq $candidateHash) "Candidate fixture asset does not match its build record: $($candidateFile.Name)"
        }
        $candidateManifestHash = (Get-FileHash -LiteralPath $candidateManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ($candidateRecord.build.vipmManifestSha256 -ceq $candidateManifestHash) "Candidate fixture VIPM manifest does not match its build record."
        $dependencyBytes = [System.IO.File]::ReadAllBytes($candidateAssetPath)
        $dependencySbomBytes = [System.IO.File]::ReadAllBytes($candidateSbomPath)
    }
    [System.IO.File]::WriteAllBytes($dependencyAssetPath, $dependencyBytes)
    [System.IO.File]::WriteAllBytes($dependencySbomPath, $dependencySbomBytes)
    $dependencyRelease = Get-Content -LiteralPath $examplePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $dependencyRelease.module.repository = "svelderrainruiz/dependencies"
    $dependencyRelease.module.id = "dependencies"
    $dependencyRelease.module.version = "1.0.0.14"
    $dependencyRelease.source.repository = "svelderrainruiz/dependencies"
    $dependencyRelease.source.ref = "refs/tags/v1.0.0.14"
    $dependencyRelease.release.tag = "v1.0.0.14"
    $dependencyRelease.release.url = "https://github.com/svelderrainruiz/dependencies/releases/tag/v1.0.0.14"
    $dependencyRelease.toolchain.vipmDesktopVersion = "2026.3.2.4056"
    $dependencyRelease.toolchain.labviewBaseImageDigest = "nationalinstruments/labview@sha256:$('a' * 64)"
    $dependencyRelease.toolchain.labviewVilib = @{ installedVersion = "26.3.1.0-0+d0"; source = "preinstalled-base-image" }
    if ($candidateRecord) {
        $dependencyRelease.source.commit = $candidateRecord.source.commit
        $dependencyRelease.toolchain.labviewVersion = $candidateRecord.build.labviewVersion
        $dependencyRelease.toolchain.labviewBitness = $candidateRecord.build.labviewBitness
        $dependencyRelease.toolchain.labviewBaseImageDigest = $candidateRecord.build.labviewBaseImageDigest
        $dependencyRelease.toolchain.labviewVilib = $candidateRecord.build.labviewVilib
        if ($candidateRecord.build.vipmCliVersion) { $dependencyRelease.toolchain.vipmVersion = $candidateRecord.build.vipmCliVersion }
        if ($candidateRecord.build.vipmDesktopVersion) { $dependencyRelease.toolchain.vipmDesktopVersion = $candidateRecord.build.vipmDesktopVersion }
    }
    $dependencyRelease.artifacts.releaseAssets = @(@{
        id = "lba-plugins-dependencies-ppl"
        version = "1.0.0.14"
        buildSpec = "lba-plugins-dependencies-ppl"
        kind = "lvlibp"
        format = "lvlibp"
        asset = @{
            fileName = [System.IO.Path]::GetFileName($dependencyAssetPath)
            sizeBytes = (Get-Item -LiteralPath $dependencyAssetPath).Length
            sha256 = (Get-FileHash -LiteralPath $dependencyAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $dependencyRelease.artifacts.sboms[0].subjectAssetId = "lba-plugins-dependencies-ppl"
    $dependencyRelease.artifacts.sboms[0].subjectAssetVersion = "1.0.0.14"
    $dependencyRelease.artifacts.sboms[0].subjectAssetKind = "lvlibp"
    $dependencyRelease.artifacts.sboms[0].asset.fileName = [System.IO.Path]::GetFileName($dependencySbomPath)
    $dependencyRelease.artifacts.sboms[0].asset.sizeBytes = (Get-Item -LiteralPath $dependencySbomPath).Length
    $dependencyRelease.artifacts.sboms[0].asset.sha256 = (Get-FileHash -LiteralPath $dependencySbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $dependencyRelease.validation.buildOutputs = @(@{
        buildSpec = "lba-plugins-dependencies-ppl"
        outputType = "lvlibp"
        outcome = "built"
        includedInReleaseAsset = [System.IO.Path]::GetFileName($dependencyAssetPath)
        runUrl = "https://github.com/svelderrainruiz/dependencies/actions/runs/1234567890"
    })
    $dependencyRelease.artifacts.sboms[0].asset.fileName = [System.IO.Path]::GetFileName($dependencySbomPath)
    [System.IO.File]::WriteAllText($dependencyManifestPath, ($dependencyRelease | ConvertTo-Json -Depth 20), $utf8NoBom)

    $artifactRootLink = Join-Path $fixtureRoot "artifact-root-link"
    $artifactLinkType = if ($IsWindows) { "Junction" } else { "SymbolicLink" }
    $null = New-Item -ItemType $artifactLinkType -Path $artifactRootLink -Target $dependencyArtifactRoot
    Assert-Throw {
        & $validatorPath -ManifestPath $dependencyManifestPath -ArtifactDirectory $artifactRootLink -SchemaPath $schemaPath
    } "*link*"

    if (-not $IsWindows) {
        $outsideAssetPath = Join-Path $fixtureRoot "outside-asset.lvlibp"
        [System.IO.File]::WriteAllBytes($outsideAssetPath, $dependencyBytes)
        $assetLinkPath = Join-Path $dependencyArtifactRoot "linked-asset.lvlibp"
        $null = New-Item -ItemType SymbolicLink -Path $assetLinkPath -Target $outsideAssetPath
        $dependencyRelease.artifacts.releaseAssets[0].asset.fileName = "linked-asset.lvlibp"
        $dependencyRelease.validation.buildOutputs[0].includedInReleaseAsset = "linked-asset.lvlibp"
        [System.IO.File]::WriteAllText($dependencyManifestPath, ($dependencyRelease | ConvertTo-Json -Depth 20), $utf8NoBom)
        Assert-Throw {
            & $validatorPath -ManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot -SchemaPath $schemaPath
        } "*link*"
        $dependencyRelease.artifacts.releaseAssets[0].asset.fileName = "dependencies.lvlibp"
        $dependencyRelease.validation.buildOutputs[0].includedInReleaseAsset = "dependencies.lvlibp"
        $outsideSbomPath = Join-Path $fixtureRoot "outside-asset.cdx.sbom.json"
        [System.IO.File]::WriteAllBytes($outsideSbomPath, $dependencySbomBytes)
        $sbomLinkPath = Join-Path $dependencyArtifactRoot "linked-asset.cdx.sbom.json"
        $null = New-Item -ItemType SymbolicLink -Path $sbomLinkPath -Target $outsideSbomPath
        $dependencyRelease.artifacts.sboms[0].asset.fileName = "linked-asset.cdx.sbom.json"
        [System.IO.File]::WriteAllText($dependencyManifestPath, ($dependencyRelease | ConvertTo-Json -Depth 20), $utf8NoBom)
        Assert-Throw {
            & $validatorPath -ManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot -SchemaPath $schemaPath
        } "*link*"
        $dependencyRelease.artifacts.sboms[0].asset.fileName = "dependencies.lvlibp.cdx.sbom.json"
        [System.IO.File]::WriteAllText($dependencyManifestPath, ($dependencyRelease | ConvertTo-Json -Depth 20), $utf8NoBom)
    }

    Write-FixtureManifest $manifest
    & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath | Out-Null
    $stageScriptPath = Join-Path $root "scripts/stage-release-dependency.ps1"
    & $stageScriptPath -ConsumerManifestPath $manifestPath -DependencyName "lba-plugins-dependencies-ppl" `
        -DependencyManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot `
        -WorkspaceRoot $stageRoot -SchemaPath $schemaPath | Out-Null
    $stagedDependencyPath = Join-Path $stageRoot "dependencies.lvlibp"
    Assert-True (Test-Path -LiteralPath $stagedDependencyPath -PathType Leaf) "Pinned LVLIBP was not staged at its declared workspace path."
    Assert-True ((Get-FileHash -LiteralPath $stagedDependencyPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq
        (Get-FileHash -LiteralPath $dependencyAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()) "Staged LVLIBP bytes do not match the dependency release asset."
    & $stageScriptPath -ConsumerManifestPath $manifestPath -DependencyName "lba-plugins-dependencies-ppl" `
        -DependencyManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot `
        -WorkspaceRoot $stageRoot -SchemaPath $schemaPath | Out-Null

    $immutableStagePath = Join-Path $root "scripts/stage-immutable-release-dependency.ps1"
    $releasePurl = 'pkg:github/svelderrainruiz/dependencies@v1.0.0.14'
    $statement = @{
        predicateType = 'https://in-toto.io/attestation/release/v0.2'
        predicate = @{ repository = 'svelderrainruiz/dependencies'; tag = 'v1.0.0.14'; purl = $releasePurl }
        subject = @(
            @{ uri = $releasePurl; digest = @{ sha1 = $dependencyRelease.source.commit } },
            @{ name = 'release-manifest.json'; digest = @{ sha256 = (Get-FileHash -LiteralPath $dependencyManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() } },
            @{ name = 'dependencies.lvlibp'; digest = @{ sha256 = (Get-FileHash -LiteralPath $dependencyAssetPath -Algorithm SHA256).Hash.ToLowerInvariant() } },
            @{ name = 'dependencies.lvlibp.cdx.sbom.json'; digest = @{ sha256 = (Get-FileHash -LiteralPath $dependencySbomPath -Algorithm SHA256).Hash.ToLowerInvariant() } }
        )
    }
    $verificationState = @{
        release = @{ verificationResult = @{ statement = $statement } }
        metadata = @{ tag_name = 'v1.0.0.14'; immutable = $true; draft = $false }
        exitCode = 0; metadataExitCode = 0; arguments = @(); metadataArguments = @()
    }
    function gh {
        if ($args[0] -eq 'api') {
            $verificationState.metadataArguments = @($args)
            $global:LASTEXITCODE = $verificationState.metadataExitCode
            $verificationState.metadata | ConvertTo-Json -Depth 20
            return
        }
        $verificationState.arguments = @($args)
        $global:LASTEXITCODE = $verificationState.exitCode
        $verificationState.release | ConvertTo-Json -Depth 20
    }
    $verifiedStageRoot = Join-Path $fixtureRoot 'verified-consumer-workspace'
    $blockedStageRoot = Join-Path $fixtureRoot 'blocked-consumer-workspace'
    $null = New-Item -ItemType Directory -Path $verifiedStageRoot
    $null = New-Item -ItemType Directory -Path $blockedStageRoot
    $immutableStageArguments = @{
        ConsumerManifestPath = $manifestPath; DependencyName = 'lba-plugins-dependencies-ppl'
        DependencyManifestPath = $dependencyManifestPath; ArtifactDirectory = $dependencyArtifactRoot
        WorkspaceRoot = $verifiedStageRoot; SchemaPath = $schemaPath
    }
    & $immutableStagePath @immutableStageArguments | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $verifiedStageRoot 'dependencies.lvlibp') -PathType Leaf) "Attested LVLIBP was not staged."
    Assert-True (($verificationState.arguments -join '|') -ceq 'release|verify|--repo|svelderrainruiz/dependencies|--format|json|v1.0.0.14') "Release verification used unexpected arguments: $($verificationState.arguments -join '|')"
    Assert-True (($verificationState.metadataArguments -join '|') -ceq 'api|repos/svelderrainruiz/dependencies/releases/tags/v1.0.0.14') "Release metadata query did not use the exact consumer repository and tag."
    $immutableStageArguments.WorkspaceRoot = $blockedStageRoot
    $verificationState.metadata.immutable = $false
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*published immutable release*'
    $verificationState.metadata.immutable = $true
    $verificationState.metadata.draft = $true
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*published immutable release*'
    $verificationState.metadata.draft = $false
    $verificationState.metadata.tag_name = 'v1.0.0.13'
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*published immutable release*'
    $verificationState.metadata.tag_name = 'v1.0.0.14'
    $verificationState.metadataExitCode = 1
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*release metadata*failed*'
    $verificationState.metadataExitCode = 0
    $statement.predicate.tag = 'v1.0.0.13'
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*attested release identity*'
    $statement.predicate.tag = 'v1.0.0.14'
    $statement.predicate.repository = 'other/dependencies'
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*attested release identity*'
    $statement.predicate.repository = 'svelderrainruiz/dependencies'
    $statement.subject[0].digest.sha1 = 'b' * 40
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*attested source commit*'
    $statement.subject[0].digest.sha1 = $dependencyRelease.source.commit
    $manifestDigest = $statement.subject[1].digest.sha256
    $statement.subject[1].digest.sha256 = 'f' * 64
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*release-manifest.json*attestation*'
    $statement.subject[1].digest.sha256 = $manifestDigest
    $statement.subject += $statement.subject[2]
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*dependencies.lvlibp*attestation*'
    $statement.subject = @($statement.subject[0..3])
    $verificationState.exitCode = 1
    Assert-Throw { & $immutableStagePath @immutableStageArguments } '*release attestation verification failed*'
    $verificationState.exitCode = 0
    $global:LASTEXITCODE = 0
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $blockedStageRoot 'dependencies.lvlibp'))) "Failed attestation verification staged an LVLIBP."

    $manifest.dependencies[0].stagePath = "nested/inner/dependencies.lvlibp"
    Write-FixtureManifest $manifest
    & $stageScriptPath -ConsumerManifestPath $manifestPath -DependencyName "lba-plugins-dependencies-ppl" `
        -DependencyManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot `
        -WorkspaceRoot $stageRoot -SchemaPath $schemaPath | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot "nested/inner/dependencies.lvlibp") -PathType Leaf) "Nested LVLIBP staging failed."

    $outsideStageRoot = Join-Path $fixtureRoot "outside-workspace"
    $null = New-Item -ItemType Directory -Path $outsideStageRoot
    $linkPath = Join-Path $stageRoot "linked"
    $linkType = if ($IsWindows) { "Junction" } else { "SymbolicLink" }
    $null = New-Item -ItemType $linkType -Path $linkPath -Target $outsideStageRoot
    $manifest.dependencies[0].stagePath = "linked/escaped.lvlibp"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $stageScriptPath -ConsumerManifestPath $manifestPath -DependencyName "lba-plugins-dependencies-ppl" `
            -DependencyManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot `
            -WorkspaceRoot $stageRoot -SchemaPath $schemaPath
    } "*link*"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $outsideStageRoot "escaped.lvlibp"))) "LVLIBP was staged outside the workspace through a link."
    $manifest.dependencies[0].stagePath = "dependencies.lvlibp"
    Write-FixtureManifest $manifest

    $rootLinkPath = Join-Path $fixtureRoot "workspace-link"
    $null = New-Item -ItemType $linkType -Path $rootLinkPath -Target $stageRoot
    Assert-Throw {
        & $stageScriptPath -ConsumerManifestPath $manifestPath -DependencyName "lba-plugins-dependencies-ppl" `
            -DependencyManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot `
            -WorkspaceRoot $rootLinkPath -SchemaPath $schemaPath
    } "*link*"

    if (-not $IsWindows) {
        $outsideAssetPath = Join-Path $outsideStageRoot "outside.lvlibp"
        [System.IO.File]::WriteAllBytes($outsideAssetPath, $dependencyBytes)
        $fileLinkPath = Join-Path $stageRoot "linked.lvlibp"
        $null = New-Item -ItemType SymbolicLink -Path $fileLinkPath -Target $outsideAssetPath
        $manifest.dependencies[0].stagePath = "linked.lvlibp"
        Write-FixtureManifest $manifest
        Assert-Throw {
            & $stageScriptPath -ConsumerManifestPath $manifestPath -DependencyName "lba-plugins-dependencies-ppl" `
                -DependencyManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot `
                -WorkspaceRoot $stageRoot -SchemaPath $schemaPath
        } "*link*"
        $danglingLinkPath = Join-Path $stageRoot "dangling.lvlibp"
        $null = New-Item -ItemType SymbolicLink -Path $danglingLinkPath -Target (Join-Path $outsideStageRoot "missing.lvlibp")
        $manifest.dependencies[0].stagePath = "dangling.lvlibp"
        Write-FixtureManifest $manifest
        Assert-Throw {
            & $stageScriptPath -ConsumerManifestPath $manifestPath -DependencyName "lba-plugins-dependencies-ppl" `
                -DependencyManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot `
                -WorkspaceRoot $stageRoot -SchemaPath $schemaPath
        } "*link*"
        $manifest.dependencies[0].stagePath = "dependencies.lvlibp"
    }

    $manifest.dependencies[0].releaseTag = "v1.0.0.13"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $stageScriptPath -ConsumerManifestPath $manifestPath -DependencyName "lba-plugins-dependencies-ppl" `
            -DependencyManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot `
            -WorkspaceRoot $stageRoot -SchemaPath $schemaPath
    } "*Dependency release tag does not match the consumer pin*"
    $manifest.dependencies[0].releaseTag = "v1.0.0.14"

    [System.IO.File]::WriteAllText($stagedDependencyPath, "conflicting LVLIBP bytes", $utf8NoBom)
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $stageScriptPath -ConsumerManifestPath $manifestPath -DependencyName "lba-plugins-dependencies-ppl" `
            -DependencyManifestPath $dependencyManifestPath -ArtifactDirectory $dependencyArtifactRoot `
            -WorkspaceRoot $stageRoot -SchemaPath $schemaPath
    } "*Refusing to overwrite a different file at the LVLIBP stage path*"

    $manifest.dependencies[0].releaseTag = "latest"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*Floating or range dependency release tag is not allowed*"
    $manifest.dependencies[0].releaseTag = "v1.14.0.14"

    $manifest.dependencies[0].stagePath = "../dependencies.lvlibp"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*does not satisfy the ProjectBuddy schema*"

    $manifest.dependencies[0].stagePath = "dependencies.vip"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*does not satisfy the ProjectBuddy schema*"

    $manifest.dependencies[0].stagePath = "nested/dependencies:stream.lvlibp"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*does not satisfy the ProjectBuddy schema*"

    $manifest.dependencies = @()
    $manifest.validation.buildOutputs[1].outcome = "built"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*does not satisfy the ProjectBuddy schema*"

    $manifest.validation.buildOutputs[1].outcome = "executed"
    $manifest.validation.buildOutputs[0].includedInReleaseAsset = "missing.zip"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*Build output references an unknown release asset*"

    $manifest.validation.buildOutputs[0].includedInReleaseAsset = "replay-1.0.0.zip"
    [System.IO.File]::WriteAllText($binaryAssetPath, "synthetic executable bytes", $utf8NoBom)
    $manifest.artifacts.releaseAssets += @{
        id = "launcher-binary"
        version = "1.0.0"
        buildSpec = "Launcher"
        kind = "executable"
        format = "exe"
        asset = @{
            fileName = [System.IO.Path]::GetFileName($binaryAssetPath)
            sizeBytes = (Get-Item -LiteralPath $binaryAssetPath).Length
            sha256 = (Get-FileHash -LiteralPath $binaryAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*Released asset does not have a matching CycloneDX SBOM*"
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

Write-Output "ProjectBuddy release manifest checks passed."