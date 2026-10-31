[CmdletBinding()]
param()

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
$packagePath = Join-Path $fixtureRoot "core-1.0.0.vip"
$sbomPath = Join-Path $fixtureRoot "core-1.0.0.cdx.sbom.json"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$packageBytes = $utf8NoBom.GetBytes("synthetic package bytes")
$sbomText = '{"bomFormat":"CycloneDX","specVersion":"1.5","version":1,"metadata":{"component":{"type":"library","name":"core","version":"1.0.0"}}}'

function Write-FixtureManifest {
    param($Manifest)
    $json = $Manifest | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)
}

try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    [System.IO.File]::WriteAllBytes($packagePath, $packageBytes)
    [System.IO.File]::WriteAllText($sbomPath, $sbomText, $utf8NoBom)

    $manifest = Get-Content -LiteralPath $examplePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $manifest.artifacts.packages[0].asset.fileName = [System.IO.Path]::GetFileName($packagePath)
    $manifest.artifacts.packages[0].asset.sizeBytes = (Get-Item -LiteralPath $packagePath).Length
    $manifest.artifacts.packages[0].asset.sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.artifacts.sboms[0].asset.fileName = [System.IO.Path]::GetFileName($sbomPath)
    $manifest.artifacts.sboms[0].asset.sizeBytes = (Get-Item -LiteralPath $sbomPath).Length
    $manifest.artifacts.sboms[0].asset.sha256 = (Get-FileHash -LiteralPath $sbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-FixtureManifest $manifest

    & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath | Out-Null

    [System.IO.File]::WriteAllText($packagePath, "synthetic package byteS", $utf8NoBom)
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*SHA-256 mismatch*"

    [System.IO.File]::WriteAllBytes($packagePath, $packageBytes)
    Remove-Item -LiteralPath $sbomPath -Force
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*Release asset is missing*"

    [System.IO.File]::WriteAllText($sbomPath, $sbomText, $utf8NoBom)
    $manifest.artifacts.packages[0].asset.sizeBytes = (Get-Item -LiteralPath $packagePath).Length
    $manifest.artifacts.packages[0].asset.sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.artifacts.sboms[0].asset.sizeBytes = (Get-Item -LiteralPath $sbomPath).Length
    $manifest.artifacts.sboms[0].asset.sha256 = (Get-FileHash -LiteralPath $sbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.artifacts.sboms[0].subjectPackageVersion = "9.9.9"
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*SBOM subject does not identify a released package*"

    $manifest.artifacts.sboms[0].subjectPackageVersion = "1.0.0"
    $mismatchedSbom = '{"bomFormat":"CycloneDX","specVersion":"1.5","version":1,"metadata":{"component":{"type":"library","name":"other","version":"1.0.0"}}}'
    [System.IO.File]::WriteAllText($sbomPath, $mismatchedSbom, $utf8NoBom)
    $manifest.artifacts.sboms[0].asset.sizeBytes = (Get-Item -LiteralPath $sbomPath).Length
    $manifest.artifacts.sboms[0].asset.sha256 = (Get-FileHash -LiteralPath $sbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*CycloneDX metadata component does not match*"

    $manifest.artifacts.sboms[0].subjectPackageVersion = "1.0.0"
    [System.IO.File]::WriteAllText($sbomPath, $sbomText, $utf8NoBom)
    $manifest.artifacts.sboms[0].asset.sizeBytes = (Get-Item -LiteralPath $sbomPath).Length
    $manifest.artifacts.sboms[0].asset.sha256 = (Get-FileHash -LiteralPath $sbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.release.immutable = $false
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*does not satisfy the ProjectBuddy schema*"

    $manifest.release.immutable = $true
    $manifest.dependencies = @(@{ ecosystem = "vipm"; name = "example"; version = "latest" })
    Write-FixtureManifest $manifest
    Assert-Throw {
        & $validatorPath -ManifestPath $manifestPath -ArtifactDirectory $fixtureRoot -SchemaPath $schemaPath
    } "*Floating or range dependency version is not allowed*"
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

Write-Output "ProjectBuddy release manifest checks passed."