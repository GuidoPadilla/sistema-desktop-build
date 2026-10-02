# Build y releases de Sistema Desktop

Repositorio de empaquetado. El código fuente vive en `../sistema-desktop`; React y Frappe no se copian aquí.

## Release Windows con VeloPack

Requisitos del equipo de build:

- Windows 10/11 x64.
- Python 3.12 x64 y Python Launcher (`py`).
- .NET SDK para instalar/ejecutar `vpk`.

Desde PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build_release_windows.ps1 `
  -Version 0.1.0 `
  -ReleaseRepoUrl "https://github.com/OWNER/sistema-desktop-build"
```

El script prueba el cliente, genera una carpeta PyInstaller `--onedir` y ejecuta VeloPack. Los instaladores, paquetes y feed `releases.win.json` quedan en `artifacts/`.

Para subir a GitHub Releases, después de crear ambos repos remotos:

```powershell
$env:GITHUB_TOKEN = "token-temporal"
.\publish_github.ps1 -RepoUrl "https://github.com/ORG/sistema-desktop-releases" -Publish
Remove-Item Env:GITHUB_TOKEN
```

El token nunca debe guardarse en archivos ni en Git.

El workflow del repositorio fuente incorpora esta URL en el ejecutable y publica automáticamente cada push de `main`.
