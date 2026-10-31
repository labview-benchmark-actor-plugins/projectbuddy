[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConsumerManifestPath,
    [Parameter(Mandatory = $true)][string]$DependencyName,
    [Parameter(Mandatory = $true)][string]$DependencyManifestPath,
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [string]$SchemaPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path $PSScriptRoot '../schemas/release-manifest.schema.json'
}
foreach ($path in @($ConsumerManifestPath, $DependencyManifestPath, $SchemaPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Input file not found: $path" }
}
if (-not (Test-Path -LiteralPath $ArtifactDirectory -PathType Container)) {
    throw "Dependency artifact directory not found: $ArtifactDirectory"
}
$artifactRoot = [System.IO.Path]::GetFullPath($ArtifactDirectory)
$manifestPath = [System.IO.Path]::GetFullPath($DependencyManifestPath)
$expectedManifestPath = [System.IO.Path]::GetFullPath((Join-Path $artifactRoot 'release-manifest.json'))
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not $manifestPath.Equals($expectedManifestPath, $pathComparison)) {
    throw 'The dependency release manifest must be release-manifest.json in the artifact directory.'
}
if ((Get-Item -LiteralPath $manifestPath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw 'The dependency release manifest must not be a link or reparse point.'
}

$consumerText = Get-Content -LiteralPath $ConsumerManifestPath -Raw -Encoding utf8
try {
    if (-not (Test-Json -Json $consumerText -SchemaFile $SchemaPath -ErrorAction Stop)) {
        throw 'Consumer manifest does not satisfy the ProjectBuddy schema.'
    }
    $consumer = $consumerText | ConvertFrom-Json -AsHashtable
} catch {
    throw "Invalid consumer manifest: $($_.Exception.Message)"
}
$dependencies = @($consumer.dependencies | Where-Object {
    $_.ecosystem -ceq 'lvlibp' -and $_.scope -ceq 'build' -and $_.name -ceq $DependencyName
})
if ($dependencies.Count -ne 1) {
    throw "Consumer manifest must declare exactly one build-scope LVLIBP dependency named '$DependencyName'."
}
$dependency = $dependencies[0]
if ($dependency.version -ieq 'latest' -or $dependency.version -match '[*<>~^]' -or
    $dependency.releaseTag -ieq 'latest' -or $dependency.releaseTag -match '[*<>~^]') {
    throw 'A floating dependency version or release tag is not allowed.'
}

& (Join-Path $PSScriptRoot 'validate-release-manifest.ps1') -ManifestPath $manifestPath `
    -ArtifactDirectory $artifactRoot -SchemaPath $SchemaPath | Out-Null
$releaseManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($releaseManifest.module.repository -ine $dependency.repository -or
    $releaseManifest.source.repository -ine $dependency.repository -or
    $releaseManifest.release.tag -cne $dependency.releaseTag -or
    $releaseManifest.source.ref -cne "refs/tags/$($dependency.releaseTag)") {
    throw 'Dependency release identity does not match the consumer pin.'
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required to verify the immutable release.' }
$releaseEndpoint = 'repos/{0}/releases/tags/{1}' -f $dependency.repository, [uri]::EscapeDataString($dependency.releaseTag)
$metadataJson = & gh api -- $releaseEndpoint
if ($LASTEXITCODE -ne 0) { throw "GitHub release metadata query failed with exit code $LASTEXITCODE." }
try {
    $metadata = ($metadataJson -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
} catch {
    throw "GitHub release metadata is invalid JSON: $($_.Exception.Message)"
}
if ($metadata.tag_name -cne $dependency.releaseTag -or $metadata.immutable -isnot [bool] -or
    -not $metadata.immutable -or $metadata.draft -isnot [bool] -or $metadata.draft) {
    throw 'The pinned tag is not a published immutable release.'
}
$verificationJson = & gh release verify --repo $dependency.repository --format json -- $dependency.releaseTag
if ($LASTEXITCODE -ne 0) { throw "GitHub release attestation verification failed with exit code $LASTEXITCODE." }
try {
    $verification = ($verificationJson -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
} catch {
    throw "GitHub release attestation output is invalid JSON: $($_.Exception.Message)"
}
$statement = $verification.verificationResult.statement
$predicate = $statement.predicate
if ($statement.predicateType -cne 'https://in-toto.io/attestation/release/v0.2' -or
    $predicate.repository -ine $dependency.repository -or $predicate.tag -cne $dependency.releaseTag -or
    [string]::IsNullOrWhiteSpace([string]$predicate.purl)) {
    throw 'The attested release identity does not match the consumer pin.'
}
$sourceSubjects = @($statement.subject | Where-Object { $_.uri -ceq $predicate.purl })
$commitAlgorithm = if ($releaseManifest.source.commit.Length -eq 40) { 'sha1' } else { 'sha256' }
if ($sourceSubjects.Count -ne 1 -or $sourceSubjects[0].digest[$commitAlgorithm] -ine $releaseManifest.source.commit) {
    throw 'The attested source commit does not match the dependency release manifest.'
}

$assets = @(
    @{ fileName = 'release-manifest.json'; sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    $releaseManifest.artifacts.releaseAssets | ForEach-Object { $_.asset }
    $releaseManifest.artifacts.sboms | ForEach-Object { $_.asset }
)
if ($releaseManifest.artifacts.attestation) { $assets += $releaseManifest.artifacts.attestation }
foreach ($asset in $assets) {
    $subjects = @($statement.subject | Where-Object { $_.name -ceq $asset.fileName })
    if ($subjects.Count -ne 1 -or $subjects[0].digest.sha256 -ine $asset.sha256) {
        throw "Release asset '$($asset.fileName)' does not have a unique matching SHA-256 in the verified attestation."
    }
}

& (Join-Path $PSScriptRoot 'stage-release-dependency.ps1') -ConsumerManifestPath $ConsumerManifestPath `
    -DependencyName $DependencyName -DependencyManifestPath $manifestPath -ArtifactDirectory $artifactRoot `
    -WorkspaceRoot $WorkspaceRoot -SchemaPath $SchemaPath