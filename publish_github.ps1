param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://github\.com/[^/]+/[^/]+/?$')]
    [string]$RepoUrl,
    [string]$Channel = "win",
    [switch]$Publish,
    [switch]$PreRelease
)

$ErrorActionPreference = "Stop"
$Artifacts = Join-Path $PSScriptRoot "artifacts"

if (-not (Test-Path $Artifacts)) {
    throw "No existe artifacts/. Ejecute build_release_windows.ps1 primero."
}
if (-not $env:GITHUB_TOKEN) {
    throw "Defina GITHUB_TOKEN solo en el entorno de esta sesión."
}
if (-not (Get-Command vpk -ErrorAction SilentlyContinue)) {
    throw "No se encontró vpk. Ejecute el build de release primero."
}

$env:VPK_TOKEN = $env:GITHUB_TOKEN
$Arguments = @(
    "upload", "github",
    "--outputDir", $Artifacts,
    "--channel", $Channel,
    "--repoUrl", $RepoUrl
)
if ($Publish) { $Arguments += @("--publish", "true") }
if ($PreRelease) { $Arguments += @("--pre", "true") }

try {
    & vpk @Arguments
    if ($LASTEXITCODE -ne 0) { throw "No se pudo publicar el release en GitHub." }
}
finally {
    Remove-Item Env:VPK_TOKEN -ErrorAction SilentlyContinue
}
