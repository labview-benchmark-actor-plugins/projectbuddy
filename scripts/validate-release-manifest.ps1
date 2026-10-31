[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactDirectory,

    [string]$SchemaPath
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path $PSScriptRoot "../schemas/release-manifest.schema.json"
}
foreach ($path in @($ManifestPath, $SchemaPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Input file not found: $path"
    }
}
if (-not (Test-Path -LiteralPath $ArtifactDirectory -PathType Container)) {
    throw "Artifact directory not found: $ArtifactDirectory"
}

$manifestText = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8
try {
    $schemaValid = Test-Json -Json $manifestText -SchemaFile $SchemaPath -ErrorAction Stop
} catch {
    throw "Release manifest does not satisfy the ProjectBuddy schema: $($_.Exception.Message)"
}
if (-not $schemaValid) {
    throw "Release manifest does not satisfy the ProjectBuddy schema."
}

$manifest = $manifestText | ConvertFrom-Json -AsHashtable
if ($manifest.module.repository -ine $manifest.source.repository) {
    throw "Module repository does not match source repository."
}
if ($manifest.source.ref -cne "refs/tags/$($manifest.release.tag)") {
    throw "Source ref does not match the release tag."
}

$packageKeys = @{}
foreach ($package in $manifest.artifacts.packages) {
    $packageKey = "$($package.id)@$($package.version)"
    if ($packageKeys.ContainsKey($packageKey)) {
        throw "Duplicate package identity in release manifest: $packageKey"
    }
    $packageKeys[$packageKey] = $true
}

foreach ($dependency in $manifest.dependencies) {
    if ($dependency.version -ieq "latest" -or $dependency.version -match '[*<>~^]') {
        throw "Floating or range dependency version is not allowed: $($dependency.name) $($dependency.version)"
    }
}

$artifactRoot = [System.IO.Path]::GetFullPath($ArtifactDirectory)
$assets = @(
    $manifest.artifacts.packages | ForEach-Object { $_.asset }
    $manifest.artifacts.sboms | ForEach-Object { $_.asset }
)
if ($manifest.artifacts.provenance) {
    $assets += $manifest.artifacts.provenance
}

foreach ($asset in $assets) {
    $assetPath = [System.IO.Path]::GetFullPath((Join-Path $artifactRoot $asset.fileName))
    $relativePath = [System.IO.Path]::GetRelativePath($artifactRoot, $assetPath)
    if ([System.IO.Path]::IsPathRooted($relativePath) -or $relativePath -eq ".." -or
        $relativePath.StartsWith(".." + [System.IO.Path]::DirectorySeparatorChar)) {
        throw "Asset path escapes the artifact directory: $($asset.fileName)"
    }
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Release asset is missing: $($asset.fileName)"
    }

    $file = Get-Item -LiteralPath $assetPath
    if ($file.Length -ne $asset.sizeBytes) {
        throw "Release asset size mismatch: $($asset.fileName)"
    }
    $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $asset.sha256.ToLowerInvariant()) {
        throw "Release asset SHA-256 mismatch: $($asset.fileName)"
    }
}

foreach ($sbom in $manifest.artifacts.sboms) {
    $subjectKey = "$($sbom.subjectPackageId)@$($sbom.subjectPackageVersion)"
    if (-not $packageKeys.ContainsKey($subjectKey)) {
        throw "SBOM subject does not identify a released package: $subjectKey"
    }

    $sbomPath = Join-Path $artifactRoot $sbom.asset.fileName
    try {
        $sbomDocument = Get-Content -LiteralPath $sbomPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    } catch {
        throw "CycloneDX SBOM is not valid JSON '$($sbom.asset.fileName)': $($_.Exception.Message)"
    }
    if ($sbomDocument.bomFormat -cne "CycloneDX" -or $sbomDocument.specVersion -cne $sbom.specVersion) {
        throw "CycloneDX format or spec version does not match the release manifest: $($sbom.asset.fileName)"
    }
    $component = $sbomDocument.metadata.component
    if (-not $component -or $component.name -cne $sbom.subjectPackageId -or
        $component.version -cne $sbom.subjectPackageVersion) {
        throw "CycloneDX metadata component does not match the released package: $subjectKey"
    }
}

Write-Output "Release manifest and $($assets.Count) release assets passed validation."