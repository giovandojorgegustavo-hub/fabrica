#!/usr/bin/env bash
# scripts/lanzar-rol.sh — mini-lanzador de identidades por rol.
#
# Uso:
#   scripts/lanzar-rol.sh <rol> <prompt>
#   scripts/lanzar-rol.sh <rol> -f <archivo_con_prompt>
#
# Ejemplos:
#   scripts/lanzar-rol.sh qa "revisa el PR #42"
#   scripts/lanzar-rol.sh seguridad -f prompts/pr-42.txt
#
# El flag -f es EXPLICITO (issue #23): antes se adivinaba con [[ -f ]] y un
# prompt literal que coincidiera con un path existente se reemplazaba en
# silencio por el contenido del archivo.
#
# Lee `.claude/agents/<rol>.md` como prompt del rol, y `/etc/fabrica/tokens/<rol>.token`
# como el PAT de la cuenta maquina del rol. Inyecta el token via variable de
# entorno GITHUB_TOKEN para la sesion claude; NO lo escribe a disco.
#
# Layout de tokens y configuracion de cuentas: docs/identidades.md.
# Este script NO crea tokens. Falla claro si no existen.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "uso: $0 <rol> <prompt>   |   $0 <rol> -f <archivo>" >&2
  exit 2
fi

ROL="$1"
shift
if [[ "$1" == "-f" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "lanzar-rol: -f requiere un archivo" >&2
    exit 2
  fi
  PROMPT_FILE="$2"
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "lanzar-rol: no existe el archivo de prompt '$PROMPT_FILE'" >&2
    exit 2
  fi
  PROMPT_TEXT="$(cat "$PROMPT_FILE")"
  shift 2
else
  PROMPT_TEXT="$1"
  shift
fi
# Los argumentos restantes se pasan tal cual a claude. El vigilante los usa
# para restringir la sesion (ej: --allowedTools "Bash(gh:*)").

# Allowlist estricta de los 7 roles de la Fabrica. TODOS pasan por este
# lanzador — revisores y constructores — porque el lanzador es lo que hace
# que un rol sea un TRABAJADOR de verdad: prompt de rol, identidad que
# corresponda, y atribucion de su trabajo en la bitacora.
# Sin este check, ROL="../../etc/passwd" construye paths fuera del contrato.
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

ROL_TEXT="$(cat "$ROL_FILE")"

# --- Identidad de GitHub -----------------------------------------------
# Dos regimenes, segun la tabla de docs/identidades.md:
#   (a) rol CON cuenta maquina (hay token en /etc/fabrica/tokens/<rol>.token):
#       se inyecta ese PAT — el rol firma con su propia identidad y sus
#       aprobaciones cuentan para branch protection.
#   (b) rol SIN cuenta maquina: corre con la identidad del OPERADOR (la
#       autenticacion de gh que ya tiene el usuario). Es el caso de los
#       constructores (backend, frontend, ux) y de arquitecto/producto
#       mientras sus cuentas no existan: construyen y firman por convencion,
#       pero NO pueden emitir aprobaciones que el candado cuente. Esa
#       asimetria es deliberada: el gate lo sostienen los revisores.
IDENTIDAD="operador"
if [[ -e "$TOKEN_FILE" ]]; then
  # Issue #14: el token debe ser un ARCHIVO REGULAR, no symlink ni FIFO ni
  # device — un symlink fuera del layout (error del operador) o una FIFO
  # adversarial inyectarian contenido arbitrario como token.
  if [[ -L "$TOKEN_FILE" || ! -f "$TOKEN_FILE" ]]; then
    echo "lanzar-rol: $TOKEN_FILE debe ser un archivo regular (no symlink/FIFO/device)." >&2
    exit 4
  fi
  # ADVERTENCIA (issue #14): NUNCA activar set -x alrededor de la lectura del
  # token — el PAT se imprimiria en stderr. El path del archivo puede loguearse;
  # el VALOR jamas. Lectura UNICA (sin test -r previo: evita TOCTOU).
  if ! GITHUB_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)" || [[ -z "$GITHUB_TOKEN" ]]; then
    echo "lanzar-rol: existe $TOKEN_FILE pero no puedo leerlo (permisos?) o esta vacio." >&2
    echo "lanzar-rol: el operador debe pertenecer al grupo fabrica-tokens; ver docs/identidades.md." >&2
    exit 4
  fi
  # Issue #23: validar forma del PAT aca — un archivo con basura fallaria
  # recien dentro de la sesion, lejos de la causa.
  if [[ ! "$GITHUB_TOKEN" =~ ^(ghp_|github_pat_) ]]; then
    echo "lanzar-rol: el contenido de $TOKEN_FILE no parece un PAT de GitHub (prefijo ghp_ o github_pat_)." >&2
    exit 4
  fi
  export GITHUB_TOKEN
  IDENTIDAD="cuenta maquina ($TOKEN_FILE)"
fi

# --- Atribucion del trabajo en la bitacora -----------------------------
# Si existe un token de ingesta propio del rol, se lo pasamos a los hooks:
# asi el trabajo de cada trabajador aparece en la bitacora como SU empleado
# y no todos bajo un generico (issue bitacora-v2#7). Si no existe, los hooks
# usan su default y el chat se ingiere igual — jamas se pierde trazabilidad
# por falta de configuracion.
HOOK_TOKEN_ROL="/etc/bitacora-v2/hooks/${ROL}.token"
if [[ -f "$HOOK_TOKEN_ROL" && ! -L "$HOOK_TOKEN_ROL" ]]; then
  export BITACORA_V2_HOOK_TOKEN_FILE="$HOOK_TOKEN_ROL"
fi

FULL_PROMPT="$(printf '%s\n\n---\n\nPedido del usuario:\n\n%s\n' "$ROL_TEXT" "$PROMPT_TEXT")"

echo "lanzar-rol: rol=$ROL identidad=$IDENTIDAD atribucion=${BITACORA_V2_HOOK_TOKEN_FILE:-generica}" >&2
# El separador -- es OBLIGATORIO: el prompt arranca con el frontmatter del
# archivo de rol ("---") y sin separador el CLI lo parsea como opcion
# (error: unknown option '---'). Encontrado en la primera corrida real del
# vigilante — el lanzador nunca habia sido ejecutado de punta a punta.
exec claude -p "$@" -- "$FULL_PROMPT"
