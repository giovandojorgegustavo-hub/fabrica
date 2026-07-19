#!/usr/bin/env bash
# scripts/lanzar-rol.sh — mini-lanzador de identidades por rol.
#
# Uso:
#   scripts/lanzar-rol.sh <rol> <prompt_o_ruta>
#
# Ejemplos:
#   scripts/lanzar-rol.sh qa "revisa el PR #42"
#   scripts/lanzar-rol.sh seguridad prompts/pr-42.txt
#
# Lee `.claude/agents/<rol>.md` como prompt del rol, y `/etc/fabrica/tokens/<rol>.token`
# como el PAT de la cuenta maquina del rol. Inyecta el token via variable de
# entorno GITHUB_TOKEN para la sesion claude; NO lo escribe a disco.
#
# Layout de tokens y configuracion de cuentas: docs/identidades.md.
# Este script NO crea tokens. Falla claro si no existen.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "uso: $0 <rol> <prompt_o_ruta>" >&2
  exit 2
fi

ROL="$1"
PROMPT_ARG="$2"

# Allowlist estricta: solo los roles REVISORES tienen identidad propia con
# token (ver docs/identidades.md). Los roles implementadores (backend,
# frontend, ux) trabajan con la identidad del operador y no pasan por aca.
# Sin este check, ROL="../../etc/passwd" construye paths fuera del contrato.
case "$ROL" in
  qa|seguridad|arquitecto|producto) ;;
  *)
    echo "lanzar-rol: rol invalido: '$ROL'" >&2
    echo "lanzar-rol: validos (revisores con token): qa, seguridad, arquitecto, producto" >&2
    echo "lanzar-rol: los roles implementadores (backend, frontend, ux) no usan este lanzador." >&2
    exit 2
    ;;
esac

ROL_FILE=".claude/agents/${ROL}.md"
if [[ ! -f "$ROL_FILE" ]]; then
  echo "lanzar-rol: no existe $ROL_FILE" >&2
  echo "lanzar-rol: correr desde la raiz del repo donde vive .claude/agents/." >&2
  exit 3
fi

TOKEN_FILE="/etc/fabrica/tokens/${ROL}.token"

if [[ -f "$PROMPT_ARG" ]]; then
  PROMPT_TEXT="$(cat "$PROMPT_ARG")"
else
  PROMPT_TEXT="$PROMPT_ARG"
fi

ROL_TEXT="$(cat "$ROL_FILE")"

# Inyecta el token del rol via env var. No lo escribimos a disco. La sesion
# claude lo hereda; gh y otras herramientas lo usan como identidad.
# Lectura UNICA (sin test -r previo: evita TOCTOU) + validacion de contenido.
# El layout esperado es root:fabrica-tokens 640 con el operador en el grupo
# fabrica-tokens (ver docs/identidades.md).
if ! GITHUB_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)" || [[ -z "$GITHUB_TOKEN" ]]; then
  echo "lanzar-rol: no puedo leer $TOKEN_FILE (no existe, esta vacio, o no tengo permisos)" >&2
  echo "lanzar-rol: el operador debe pertenecer al grupo fabrica-tokens; ver docs/identidades.md." >&2
  exit 4
fi
export GITHUB_TOKEN

FULL_PROMPT="$(printf '%s\n\n---\n\nPedido del usuario:\n\n%s\n' "$ROL_TEXT" "$PROMPT_TEXT")"

echo "lanzar-rol: rol=$ROL token=$TOKEN_FILE" >&2
exec claude -p "$FULL_PROMPT"
