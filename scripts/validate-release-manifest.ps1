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

$productKeys = @{}
$releaseAssetNames = @{}
foreach ($product in $manifest.artifacts.releaseAssets) {
    $productKey = "$($product.kind)|$($product.id)@$($product.version)"
    if ($productKeys.ContainsKey($productKey)) {
        throw "Duplicate release product identity in manifest: $productKey"
    }
    $productKeys[$productKey] = $true
    if ($releaseAssetNames.ContainsKey($product.asset.fileName)) {
        throw "Duplicate release asset filename in manifest: $($product.asset.fileName)"
    }
    $releaseAssetNames[$product.asset.fileName] = $true
}

foreach ($dependency in $manifest.dependencies) {
    if ($dependency.version -ieq "latest" -or $dependency.version -match '[*<>~^]') {
        throw "Floating or range dependency version is not allowed: $($dependency.name) $($dependency.version)"
    }
    if ($dependency.releaseTag -and ($dependency.releaseTag -ieq "latest" -or $dependency.releaseTag -match '[*<>~^]')) {
        throw "Floating or range dependency release tag is not allowed: $($dependency.name) $($dependency.releaseTag)"
    }
}

$artifactRoot = [System.IO.Path]::GetFullPath($ArtifactDirectory)
$artifactRootItem = Get-Item -LiteralPath $artifactRoot -Force
if ($artifactRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Release artifact directory is a link or reparse point: $artifactRoot"
}
$assets = @(
    $manifest.artifacts.releaseAssets | ForEach-Object { $_.asset }
    $manifest.artifacts.sboms | ForEach-Object { $_.asset }
)
if ($manifest.artifacts.attestation) {
    $assets += $manifest.artifacts.attestation
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

    $file = Get-Item -LiteralPath $assetPath -Force
    if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Release asset is a link or reparse point: $($asset.fileName)"
    }
    if ($file.Length -ne $asset.sizeBytes) {
        throw "Release asset size mismatch: $($asset.fileName)"
    }
    $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $asset.sha256.ToLowerInvariant()) {
        throw "Release asset SHA-256 mismatch: $($asset.fileName)"
    }
}

foreach ($buildOutput in $manifest.validation.buildOutputs) {
    if ($buildOutput.includedInReleaseAsset -and -not $releaseAssetNames.ContainsKey($buildOutput.includedInReleaseAsset)) {
        throw "Build output references an unknown release asset: $($buildOutput.includedInReleaseAsset)"
    }
}

$sbomKeys = @{}
foreach ($sbom in $manifest.artifacts.sboms) {
    $subjectKey = "$($sbom.subjectAssetKind)|$($sbom.subjectAssetId)@$($sbom.subjectAssetVersion)"
    if (-not $productKeys.ContainsKey($subjectKey)) {
        throw "SBOM subject does not identify a released asset: $subjectKey"
    }
    $sbomKeys[$subjectKey] = $true

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
    if (-not $component -or $component.name -cne $sbom.subjectAssetId -or
        $component.version -cne $sbom.subjectAssetVersion) {
        throw "CycloneDX metadata component does not match the released asset: $subjectKey"
    }
}

foreach ($productKey in $productKeys.Keys) {
    if (-not $sbomKeys.ContainsKey($productKey)) {
        throw "Released asset does not have a matching CycloneDX SBOM: $productKey"
    }
}

Write-Output "Release manifest and $($assets.Count) artifact files passed validation."