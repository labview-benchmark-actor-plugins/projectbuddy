[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConsumerManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$DependencyName,

    [Parameter(Mandatory = $true)]
    [string]$DependencyManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactDirectory,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$SchemaPath
)

$ErrorActionPreference = "Stop"

function Assert-UnlinkedStagePath {
    param([string]$Root, [string]$RelativePath)

    $componentPath = $Root
    foreach ($component in @('') + @($RelativePath -split '[\\/]')) {
        if ($component) { $componentPath = Join-Path $componentPath $component }
        $entry = Get-Item -LiteralPath $componentPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $entry -and ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "LVLIBP stage path contains a link or reparse point: $componentPath"
        }
    }
}

if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path $PSScriptRoot "../schemas/release-manifest.schema.json"
}
foreach ($path in @($ConsumerManifestPath, $DependencyManifestPath, $SchemaPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Input file not found: $path"
    }
}
if (-not (Test-Path -LiteralPath $ArtifactDirectory -PathType Container)) {
    throw "Dependency artifact directory not found: $ArtifactDirectory"
}
if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
    throw "Workspace root not found: $WorkspaceRoot"
}

try {
    $consumerText = Get-Content -LiteralPath $ConsumerManifestPath -Raw -Encoding utf8
    if (-not (Test-Json -Json $consumerText -SchemaFile $SchemaPath -ErrorAction Stop)) {
        throw "Consumer manifest does not satisfy the ProjectBuddy schema."
    }
    $consumer = $consumerText | ConvertFrom-Json -AsHashtable
} catch {
    throw "Invalid consumer manifest: $($_.Exception.Message)"
}

$matchingDependencies = @(
    $consumer.dependencies | Where-Object {
        $_.ecosystem -ceq "lvlibp" -and $_.scope -ceq "build" -and $_.name -ceq $DependencyName
    }
)
if ($matchingDependencies.Count -ne 1) {
    throw "Consumer manifest must declare exactly one build-scope LVLIBP dependency named '$DependencyName'."
}
$dependency = $matchingDependencies[0]

$validatorPath = Join-Path $PSScriptRoot "validate-release-manifest.ps1"
& $validatorPath -ManifestPath $DependencyManifestPath -ArtifactDirectory $ArtifactDirectory -SchemaPath $SchemaPath | Out-Null
$dependencyManifest = Get-Content -LiteralPath $DependencyManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable

if ($dependency.repository -ine $dependencyManifest.module.repository -or
    $dependency.repository -ine $dependencyManifest.source.repository) {
    throw "Dependency release repository does not match the consumer pin: $($dependency.repository)"
}
if ($dependency.releaseTag -cne $dependencyManifest.release.tag -or
    $dependencyManifest.source.ref -cne "refs/tags/$($dependency.releaseTag)") {
    throw "Dependency release tag does not match the consumer pin: $($dependency.releaseTag)"
}

$matchingProducts = @(
    $dependencyManifest.artifacts.releaseAssets | Where-Object {
        $_.kind -ceq "lvlibp" -and $_.id -ceq $dependency.name -and $_.version -ceq $dependency.version
    }
)
if ($matchingProducts.Count -ne 1) {
    throw "Dependency release must contain exactly one LVLIBP product matching '$($dependency.name)@$($dependency.version)'."
}
$product = $matchingProducts[0]
if ($product.asset.fileName -cne $dependency.assetFileName) {
    throw "Dependency release asset filename does not match the consumer pin: $($dependency.assetFileName)"
}

$artifactRoot = [System.IO.Path]::GetFullPath($ArtifactDirectory)
$assetPath = [System.IO.Path]::GetFullPath((Join-Path $artifactRoot $product.asset.fileName))
$assetRelativePath = [System.IO.Path]::GetRelativePath($artifactRoot, $assetPath)
if ([System.IO.Path]::IsPathRooted($assetRelativePath) -or $assetRelativePath -eq ".." -or
    $assetRelativePath.StartsWith(".." + [System.IO.Path]::DirectorySeparatorChar)) {
    throw "Dependency release asset escapes the artifact directory: $($product.asset.fileName)"
}

$workspaceFullPath = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$stagePath = [System.IO.Path]::GetFullPath((Join-Path $workspaceFullPath $dependency.stagePath))
$stageRelativePath = [System.IO.Path]::GetRelativePath($workspaceFullPath, $stagePath)
if ([System.IO.Path]::IsPathRooted($stageRelativePath) -or $stageRelativePath -eq ".." -or
    $stageRelativePath.StartsWith(".." + [System.IO.Path]::DirectorySeparatorChar)) {
    throw "LVLIBP stage path escapes the workspace root: $($dependency.stagePath)"
}

Assert-UnlinkedStagePath -Root $workspaceFullPath -RelativePath $stageRelativePath

if (Test-Path -LiteralPath $stagePath -PathType Leaf) {
    $existingHash = (Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($existingHash -eq $product.asset.sha256.ToLowerInvariant()) {
        Write-Output "Verified LVLIBP is already staged at '$stagePath'."
        return
    }
    throw "Refusing to overwrite a different file at the LVLIBP stage path: $stagePath"
}
if (Test-Path -LiteralPath $stagePath) {
    throw "LVLIBP stage path already exists and is not a file: $stagePath"
}

$stageDirectory = [System.IO.Path]::GetDirectoryName($stagePath)
$null = New-Item -ItemType Directory -Path $stageDirectory -Force
Assert-UnlinkedStagePath -Root $workspaceFullPath -RelativePath $stageRelativePath
$temporaryPath = Join-Path $stageDirectory (".lvlibp-stage-" + [guid]::NewGuid().ToString("N") + ".tmp")
try {
    Copy-Item -LiteralPath $assetPath -Destination $temporaryPath
    $stagedHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($stagedHash -ne $product.asset.sha256.ToLowerInvariant()) {
        throw "Staged LVLIBP SHA-256 does not match its verified release manifest."
    }
    [System.IO.File]::Move($temporaryPath, $stagePath)
} finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

Write-Output "Staged verified LVLIBP '$($dependency.name)@$($dependency.version)' at '$stagePath'."