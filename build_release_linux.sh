#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Uso: $0 VERSION SOURCE_DIR RELEASE_REPO_URL [--publish] [--skip-tests]" >&2
  exit 2
fi

VERSION="$1"
SOURCE_DIR="$(realpath "$2")"
RELEASE_REPO_URL="${3%/}"
shift 3
PUBLISH=false
SKIP_TESTS=false
for option in "$@"; do
  case "$option" in
    --publish) PUBLISH=true ;;
    --skip-tests) SKIP_TESTS=true ;;
    *) echo "Opción desconocida: $option" >&2; exit 2 ;;
  esac
done

VELOPACK_VERSION="1.2.161"
CHANNEL="linux-x64"
BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$BUILD_ROOT/.venv-build-linux"
PYTHON="$VENV_DIR/bin/python"
PUBLISH_ROOT="$BUILD_ROOT/publish-linux"
PACK_DIR="$PUBLISH_ROOT/sistema-desktop"
ARTIFACTS="$BUILD_ROOT/artifacts-linux"
PYINSTALLER_BUILD="$BUILD_ROOT/build-linux"
RELEASE_CONFIG="$SOURCE_DIR/desktop/app/release_config.py"
RELEASE_CONFIG_BACKUP="$(mktemp)"
ICON="$BUILD_ROOT/build-linux/sistema-desktop.png"

cp "$RELEASE_CONFIG" "$RELEASE_CONFIG_BACKUP"
restore_config() {
  cp "$RELEASE_CONFIG_BACKUP" "$RELEASE_CONFIG"
  rm -f "$RELEASE_CONFIG_BACKUP"
  unset VPK_TOKEN || true
}
trap restore_config EXIT

if [[ ! -x "$PYTHON" ]]; then
  python -m venv "$VENV_DIR"
fi
"$PYTHON" -m pip install --upgrade pip
"$PYTHON" -m pip install -e "${SOURCE_DIR}[dev]"

if [[ "$SKIP_TESTS" != true ]]; then
  (
    cd "$SOURCE_DIR"
    "$PYTHON" -m ruff check desktop
    "$PYTHON" -m pyright --pythonpath "$PYTHON"
    QT_QPA_PLATFORM=offscreen "$PYTHON" -m pytest desktop/app/tests desktop/app/validation -q
  )
fi

rm -rf "$PACK_DIR" "$PYINSTALLER_BUILD"
mkdir -p "$PUBLISH_ROOT" "$ARTIFACTS" "$PYINSTALLER_BUILD"
cat > "$RELEASE_CONFIG" <<EOF
"""Generado por build_release_linux.sh; no editar en el artefacto."""

UPDATE_REPOSITORY_URL = "$RELEASE_REPO_URL"
EOF

(
  cd "$SOURCE_DIR"
  "$PYTHON" -m PyInstaller \
    --noconfirm \
    --clean \
    --onedir \
    --windowed \
    --name sistema-desktop \
    --distpath "$PUBLISH_ROOT" \
    --workpath "$PYINSTALLER_BUILD/pyinstaller" \
    --specpath "$PYINSTALLER_BUILD" \
    --collect-all keyring \
    --collect-all velopack \
    desktop/app/main.py
)
QT_QPA_PLATFORM=offscreen "$PYTHON" "$BUILD_ROOT/create_icon.py" "$ICON"

export PATH="$PATH:$HOME/.dotnet/tools"
if command -v vpk >/dev/null 2>&1; then
  dotnet tool update --global vpk --version "$VELOPACK_VERSION"
else
  dotnet tool install --global vpk --version "$VELOPACK_VERSION"
fi

if [[ -n "${RELEASE_REPO_TOKEN:-}" ]]; then
  export VPK_TOKEN="$RELEASE_REPO_TOKEN"
fi

REPO_PATH="${RELEASE_REPO_URL#https://github.com/}"
HAS_CHANNEL_RELEASE="$($PYTHON - "$REPO_PATH" "$CHANNEL" <<'PY'
import os
import sys
import httpx

repo, channel = sys.argv[1:]
headers = {"Accept": "application/vnd.github+json"}
if token := os.environ.get("RELEASE_REPO_TOKEN"):
    headers["Authorization"] = f"Bearer {token}"
response = httpx.get(
    f"https://api.github.com/repos/{repo}/releases?per_page=30",
    headers=headers,
    follow_redirects=True,
    timeout=30,
)
response.raise_for_status()
feed = f"releases.{channel}.json"
print("true" if any(feed in {a["name"] for a in r["assets"]} for r in response.json()) else "false")
PY
)"

if [[ "$HAS_CHANNEL_RELEASE" == true ]]; then
  vpk download github \
    --repoUrl "$RELEASE_REPO_URL" \
    --channel "$CHANNEL" \
    --outputDir "$ARTIFACTS"
fi

vpk pack \
  --packId "ImportacionesExportaciones.Desktop" \
  --packVersion "$VERSION" \
  --packDir "$PACK_DIR" \
  --mainExe "sistema-desktop" \
  --packTitle "Sistema de Importaciones y Exportaciones" \
  --packAuthors "Sistema de Importaciones y Exportaciones" \
  --runtime "linux-x64" \
  --channel "$CHANNEL" \
  --icon "$ICON" \
  --categories "Office" \
  --outputDir "$ARTIFACTS"

if [[ "$PUBLISH" == true ]]; then
  if [[ -z "${RELEASE_REPO_TOKEN:-}" ]]; then
    echo "RELEASE_REPO_TOKEN es obligatorio al publicar." >&2
    exit 1
  fi
  vpk upload github \
    --outputDir "$ARTIFACTS" \
    --channel "$CHANNEL" \
    --repoUrl "$RELEASE_REPO_URL" \
    --publish true \
    --merge true \
    --releaseName "Sistema Desktop $VERSION" \
    --tag "v$VERSION"
fi

echo "Release VeloPack Linux generado en: $ARTIFACTS"
