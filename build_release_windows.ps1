param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+([+-][0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$SourceDir = (Join-Path $PSScriptRoot "..\sistema-desktop"),
    [string]$Channel = "win-x64",
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://github\.com/[^/]+/[^/]+/?$')]
    [string]$ReleaseRepoUrl,
    [string]$GitHubToken = $env:RELEASE_REPO_TOKEN,
    [switch]$Publish,
    [switch]$Merge,
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$VelopackVersion = "1.2.161"
$BuildRoot = $PSScriptRoot
$SourceDir = (Resolve-Path $SourceDir).Path
$VenvDir = Join-Path $BuildRoot ".venv-build"
$Python = Join-Path $VenvDir "Scripts\python.exe"
$PublishRoot = Join-Path $BuildRoot "publish"
$PackDir = Join-Path $PublishRoot "sistema-desktop"
$Artifacts = Join-Path $BuildRoot "artifacts"
$ReleaseConfig = Join-Path $SourceDir "desktop\app\release_config.py"
$OriginalReleaseConfig = [System.IO.File]::ReadAllBytes($ReleaseConfig)
$PreviousVpkToken = $env:VPK_TOKEN

if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    throw "No se encontró Python Launcher. Instale Python 3.12 x64 con el comando py."
}
if (-not (Test-Path $Python)) {
    & py -3.12 -m venv $VenvDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Python)) {
        throw "No se pudo crear .venv-build con Python 3.12."
    }
}

& $Python -c "import struct, sys; assert sys.version_info[:2] == (3, 12) and struct.calcsize('P') == 8, 'Se requiere Python 3.12 x64'"
if ($LASTEXITCODE -ne 0) { throw "El entorno de build no es Python 3.12 x64." }

& $Python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "No se pudo actualizar pip." }
& $Python -m pip install -e "${SourceDir}[dev]"
if ($LASTEXITCODE -ne 0) { throw "No se pudieron instalar las dependencias." }
& $Python -m pip check
if ($LASTEXITCODE -ne 0) { throw "Hay dependencias incompatibles." }

if (-not $SkipTests) {
    Push-Location $SourceDir
    try {
        & $Python -m ruff check desktop
        if ($LASTEXITCODE -ne 0) { throw "Ruff encontró errores." }
        & $Python -m pyright --pythonpath $Python
        if ($LASTEXITCODE -ne 0) { throw "Pyright encontró errores." }
        & $Python -m pytest desktop/app/tests desktop/app/validation -q
        if ($LASTEXITCODE -ne 0) { throw "Las pruebas no aprobaron." }
    }
    finally {
        Pop-Location
    }
}

if (Test-Path $PackDir) {
    Remove-Item -Recurse -Force $PackDir
}
$PyInstallerBuild = Join-Path $BuildRoot "build"
New-Item -ItemType Directory -Force $PublishRoot, $Artifacts, $PyInstallerBuild | Out-Null

try {
    Set-Content -Path $ReleaseConfig -Encoding utf8 -Value @"
"""Generado por build_release_windows.ps1; no editar en el artefacto."""

UPDATE_REPOSITORY_URL = "$($ReleaseRepoUrl.TrimEnd('/'))"
"@
    Push-Location $SourceDir
    try {
        & $Python -m PyInstaller `
            --noconfirm `
            --clean `
            --onedir `
            --windowed `
            --name sistema-desktop `
            --distpath $PublishRoot `
            --workpath (Join-Path $PyInstallerBuild "pyinstaller") `
            --specpath $PyInstallerBuild `
            --collect-all keyring `
            --collect-all velopack `
            --hidden-import pythoncom `
            --hidden-import pywintypes `
            --hidden-import win32com.client `
            desktop\app\main.py
        if ($LASTEXITCODE -ne 0) { throw "PyInstaller no pudo generar la aplicación." }
    }
    finally {
        Pop-Location
    }
}
finally {
    [System.IO.File]::WriteAllBytes($ReleaseConfig, $OriginalReleaseConfig)
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "VeloPack requiere .NET SDK. Instálelo antes de crear releases."
}
if (Get-Command vpk -ErrorAction SilentlyContinue) {
    & dotnet tool update --global vpk --version $VelopackVersion
} else {
    & dotnet tool install --global vpk --version $VelopackVersion
}
if ($LASTEXITCODE -ne 0) { throw "No se pudo instalar o actualizar vpk." }

try {
    if ($GitHubToken) { $env:VPK_TOKEN = $GitHubToken }

    $RepoUri = [Uri]$ReleaseRepoUrl
    $RepoPath = $RepoUri.AbsolutePath.Trim('/') -replace '\.git$', ''
    $Headers = @{ Accept = "application/vnd.github+json" }
    if ($GitHubToken) { $Headers.Authorization = "Bearer $GitHubToken" }
    $ExistingReleases = @(
        Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$RepoPath/releases?per_page=20" `
            -Headers $Headers
    )
    $ChannelFeed = "releases.$Channel.json"
    $HasChannelRelease = $ExistingReleases | Where-Object {
        $_.assets.name -contains $ChannelFeed
    }

    # Exercise the bundled imports, actual COM marshaling, Qt proxy lookup,
    # HTTPX session and updater bridge, then TLS + GitHub's CDN redirect.
    # This gate also runs with -SkipTests: an untested frozen app is not published.
    $SmokeReport = Join-Path $PyInstallerBuild "network-self-test.json"
    Remove-Item $SmokeReport -ErrorAction SilentlyContinue
    $FeedUrl = "$($ReleaseRepoUrl.TrimEnd('/'))/releases/latest/download/$ChannelFeed"
    $SmokeArgs = @("--network-self-test", "`"$SmokeReport`"", "--feed-url", "`"$FeedUrl`"")
    if (-not $HasChannelRelease) { $SmokeArgs += "--allow-missing-feed" }
    $Smoke = Start-Process -FilePath (Join-Path $PackDir "sistema-desktop.exe") `
        -ArgumentList $SmokeArgs -PassThru
    if (-not $Smoke.WaitForExit(180000)) {
        Stop-Process -Id $Smoke.Id -Force -ErrorAction SilentlyContinue
        throw "La comprobación de red del ejecutable excedió 180 segundos."
    }
    $Smoke.Refresh()
    if ($Smoke.ExitCode -ne 0 -or -not (Test-Path $SmokeReport)) {
        if (Test-Path $SmokeReport) { Get-Content -Raw $SmokeReport | Write-Host }
        throw "Falló la comprobación de red del ejecutable Windows. No se publicará."
    }
    $SmokeResult = Get-Content -Raw $SmokeReport | ConvertFrom-Json
    if (-not $SmokeResult.ok) { throw "La comprobación de red no aprobó: $SmokeReport" }
    Write-Host "Transporte del ejecutable Windows verificado: $($SmokeResult.checks -join ', ')"

    # Recuperar el feed anterior permite conservar el historial y generar deltas.
    if ($HasChannelRelease) {
        & vpk download github `
            --repoUrl $ReleaseRepoUrl `
            --channel $Channel `
            --outputDir $Artifacts
        if ($LASTEXITCODE -ne 0) { throw "No se pudo recuperar el release VeloPack anterior." }
    }

    & vpk pack `
        --packId "ImportacionesExportaciones.Desktop" `
        --packVersion $Version `
        --packDir $PackDir `
        --mainExe "sistema-desktop.exe" `
        --packTitle "Sistema de Importaciones y Exportaciones" `
        --packAuthors "Sistema de Importaciones y Exportaciones" `
        --runtime "win-x64" `
        --channel $Channel `
        --outputDir $Artifacts
    if ($LASTEXITCODE -ne 0) { throw "VeloPack no pudo crear el release." }

    if ($Publish) {
        if (-not $GitHubToken) { throw "GitHubToken es obligatorio al publicar." }
        $UploadArgs = @(
            "upload", "github",
            "--outputDir", $Artifacts,
            "--channel", $Channel,
            "--repoUrl", $ReleaseRepoUrl,
            "--publish", "true",
            "--releaseName", "Sistema Desktop $Version",
            "--tag", "v$Version"
        )
        if ($Merge) { $UploadArgs += @("--merge", "true") }
        & vpk @UploadArgs
        if ($LASTEXITCODE -ne 0) { throw "No se pudo publicar el release en GitHub." }
    }
}
finally {
    if ($null -eq $PreviousVpkToken) {
        Remove-Item Env:VPK_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:VPK_TOKEN = $PreviousVpkToken
    }
}

Write-Host "Release VeloPack generado en: $Artifacts"
