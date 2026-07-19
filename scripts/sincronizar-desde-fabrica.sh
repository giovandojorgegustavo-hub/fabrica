#!/usr/bin/env bash
# scripts/sincronizar-desde-fabrica.sh — actualiza los artefactos vendored de fabrica.
#
# Uso:
#   scripts/sincronizar-desde-fabrica.sh <tag>
#
# Ejemplo:
#   scripts/sincronizar-desde-fabrica.sh v0.2.0
#
# Este script vive en fabrica como referencia canonica. Cada repo producto lo
# copia (vendored) y lo mantiene alineado con la version que consume.
#
# Que hace:
#   1. Descarga el tarball del tag desde el repo fabrica en GitHub.
#   2. Extrae y reemplaza en el repo actual:
#        CLAUDE.md
#        .claude/agents/*.md
#        scripts/deploy.sh
#        scripts/lanzar-rol.sh
#        scripts/sincronizar-desde-fabrica.sh   (el mismo script se autoactualiza)
#        docs/identidades.md
#        docs/adr/*.md                          (los ADRs referenciados)
#   3. Actualiza .fabrica-version con el tag nuevo.
#   4. Deja el checkout con cambios sin commitear, listos para armar el PR.
#
# El commit y el PR los hace el operador humano, con revision qa + seguridad
# (y arquitecto si el diff toca contratos). Ver docs/adr/001-sync-fabrica-a-repos-producto.md.

set -euo pipefail

REPO_FABRICA="${REPO_FABRICA:-giovandojorgegustavo-hub/fabrica}"

if [[ $# -ne 1 ]]; then
  echo "uso: $0 <tag>" >&2
  echo "ej: $0 v0.2.0" >&2
  exit 2
fi

TAG="$1"

# Valida forma semver antes de tocar red o disco.
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "sincronizar: tag invalido '$TAG'. Formato esperado: vMAYOR.MENOR.PARCHE (ej: v0.2.0)." >&2
  exit 3
fi

if [[ ! -d ".git" ]]; then
  echo "sincronizar: no estoy en la raiz de un repo git." >&2
  exit 4
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

URL="https://github.com/${REPO_FABRICA}/archive/refs/tags/${TAG}.tar.gz"
echo "==> descargando $URL"
if ! curl --fail --silent --show-error --location \
       --proto '=https' --proto-redir '=https' \
       --max-time 60 \
       "$URL" -o "$TMPDIR/fabrica.tar.gz"; then
  echo "sincronizar: no pude descargar $URL" >&2
  exit 5
fi

echo "==> extrayendo"
tar -xzf "$TMPDIR/fabrica.tar.gz" -C "$TMPDIR"
SRC="$(find "$TMPDIR" -maxdepth 1 -type d -name 'fabrica-*' | head -n1)"
if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "sincronizar: no encontre el directorio extraido en $TMPDIR" >&2
  exit 6
fi

copiar() {
  local rel="$1"
  local src="$SRC/$rel"
  local dst="./$rel"
  if [[ ! -e "$src" ]]; then
    echo "sincronizar: $rel no existe en el tag $TAG, salto" >&2
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  if [[ -d "$src" ]]; then
    rm -rf "$dst"
    cp -a "$src" "$dst"
  else
    cp -a "$src" "$dst"
  fi
  echo "  copiado: $rel"
}

echo "==> vendoring artefactos"
copiar "CLAUDE.md"
copiar ".claude/agents"
copiar "scripts/deploy.sh"
copiar "scripts/lanzar-rol.sh"
copiar "scripts/sincronizar-desde-fabrica.sh"
copiar "docs/identidades.md"
copiar "docs/adr"

printf '%s\n' "$TAG" > .fabrica-version
echo "==> .fabrica-version -> $TAG"

echo
echo "sincronizar: listo. Cambios sin commitear."
echo "sincronizar: revisa 'git status' y 'git diff', arma la rama y abri PR."
echo "sincronizar: el PR pasa por qa + seguridad como cualquier cambio de proceso."
