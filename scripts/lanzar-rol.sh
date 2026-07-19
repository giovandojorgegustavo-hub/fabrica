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

# Allowlist estricta: los unicos roles validos son los 7 que declara la Fabrica.
# Sin este check, ROL="../../etc/passwd" construye paths fuera del contrato
# (ver docs/identidades.md).
case "$ROL" in
  qa|seguridad|arquitecto|producto|backend|frontend|ux) ;;
  *)
    echo "lanzar-rol: rol invalido: '$ROL'" >&2
    echo "lanzar-rol: validos: qa, seguridad, arquitecto, producto, backend, frontend, ux" >&2
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
if [[ ! -r "$TOKEN_FILE" ]]; then
  echo "lanzar-rol: no puedo leer $TOKEN_FILE (no existe o no tengo permisos)" >&2
  echo "lanzar-rol: ver docs/identidades.md para el layout esperado de tokens." >&2
  exit 4
fi

if [[ -f "$PROMPT_ARG" ]]; then
  PROMPT_TEXT="$(cat "$PROMPT_ARG")"
else
  PROMPT_TEXT="$PROMPT_ARG"
fi

ROL_TEXT="$(cat "$ROL_FILE")"

# Inyecta el token del rol via env var. No lo escribimos a disco. La sesion
# claude lo hereda; gh y otras herramientas lo usan como identidad.
export GITHUB_TOKEN
GITHUB_TOKEN="$(cat "$TOKEN_FILE")"

FULL_PROMPT="$(printf '%s\n\n---\n\nPedido del usuario:\n\n%s\n' "$ROL_TEXT" "$PROMPT_TEXT")"

echo "lanzar-rol: rol=$ROL token=$TOKEN_FILE" >&2
exec claude -p "$FULL_PROMPT"
