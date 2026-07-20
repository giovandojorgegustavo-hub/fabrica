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
#
# Observabilidad v3 (ADR 002): cada corrida recibe un run_id, emite eventos
# JSONL a ~/.fabrica-vigilante/eventos.jsonl, y asigna el issue del trabajo a
# la cuenta maquina del rol. Contrato de entorno (lo setea el vigilante o el
# operador; ambos opcionales):
#   FABRICA_TRABAJO  ej. "pr44" o "issue43". Default: "manual".
#   FABRICA_ISSUE    numero de issue a asignar/etiquetar (solo el numero).

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
# Issue #38 (hallazgo A1 de qa en app-erp#8): los roles REVISORES con cuenta
# maquina declarada en la tabla de docs/identidades.md EXIGEN su token. Sin
# token NO se degrada al operador: se aborta. La caida silenciosa publicaria
# reviews con body \"**Rol**: qa\" desde la cuenta del operador — el gate de
# separacion de identidad que sostiene el circuito.
case "$ROL" in
  qa|seguridad)
    if [[ ! -e "$TOKEN_FILE" ]]; then
      echo "lanzar-rol: el rol '$ROL' EXIGE cuenta maquina propia (tabla de docs/identidades.md)." >&2
      echo "lanzar-rol: no existe $TOKEN_FILE — no se degrada al operador. Abortando." >&2
      exit 4
    fi
    ;;
esac

# Issue #38 (hallazgo M1): [[ -e ]] sigue symlinks, asi que un symlink roto
# (rotacion a medias) tambien degradaria silenciosamente al operador.
if [[ -L "$TOKEN_FILE" && ! -e "$TOKEN_FILE" ]]; then
  echo "lanzar-rol: $TOKEN_FILE es un symlink roto (rotacion a medias?). Abortando." >&2
  exit 4
fi

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

# --- Observabilidad v3 (ADR 002) ---------------------------------------
# run_id: <UTC compacto>-<repo>-<trabajo>-<rol>-<sufijo>. El timestamp del
# run_id usa ISO8601 BASICO (seguro para filenames); el ts de los eventos usa
# ISO8601 EXTENDIDO. Ambas formas son el mismo reloj UTC (ADR 002 §1).
EVENTOS_DIR="${HOME}/.fabrica-vigilante"
EVENTOS_FILE="${EVENTOS_DIR}/eventos.jsonl"
EVENTOS_LOCK="${EVENTOS_DIR}/eventos.lock"
REPO_NOMBRE="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
TRABAJO="${FABRICA_TRABAJO:-manual}"
# Review PR#45 H1: los componentes del run_id (y de la linea JSONL) se
# validan/sanitizan ANTES de interpolar — un env malicioso o un path con
# comillas no puede fabricar campos JSON. TRABAJO viene de afuera: se valida
# y se aborta claro. REPO_NOMBRE viene del filesystem: se sanitiza
# deterministicamente. ROL ya paso por la allowlist de arriba.
if [[ ! "$TRABAJO" =~ ^[A-Za-z0-9._-]+$ || "${#TRABAJO}" -gt 64 ]]; then
  echo "lanzar-rol: FABRICA_TRABAJO invalido ('${TRABAJO:0:80}'): solo [A-Za-z0-9._-], max 64 chars." >&2
  exit 2
fi
# Review PR#45 r2 H-B1: FABRICA_ISSUE debe ser SOLO el numero — gh acepta
# URLs y un valor manipulado apuntaria el assignee a un repo ajeno.
if [[ -n "${FABRICA_ISSUE:-}" && ! "$FABRICA_ISSUE" =~ ^[0-9]+$ ]]; then
  echo "lanzar-rol: FABRICA_ISSUE invalido ('${FABRICA_ISSUE:0:80}'): solo el numero del issue." >&2
  exit 2
fi
# Caps de longitud (review PR#45 r2 H-M1): con TRABAJO<=64 y REPO<=64, la
# linea JSONL queda matematicamente por debajo del cap de 4 KiB — el
# truncado de linea pasa a ser cinturon, nunca tijera de JSON.
REPO_NOMBRE="${REPO_NOMBRE//[^A-Za-z0-9._-]/-}"
REPO_NOMBRE="${REPO_NOMBRE:0:64}"
SUFIJO="$(openssl rand -hex 2 2>/dev/null || printf '%04x' "$((RANDOM % 65536))")"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${REPO_NOMBRE}-${TRABAJO}-${ROL}-${SUFIJO}"
mkdir -p "$EVENTOS_DIR" 2>/dev/null || true

# Escapado JSON minimo para TODO string interpolado en la linea de eventos
# (review PR#45 H1: no solo detalle — defensa en profundidad aunque los
# inputs ya esten validados).
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ | }"
  # Review PR#45 r2 H-B2: RFC 8259 exige escapar TODO control char. Los que
  # no tienen representacion legible se eliminan directamente.
  s="${s//[[:cntrl:]]/}"
  printf '%s' "$s"
}

# Milisegundos desde epoch (issue #49: corridas <1s reportaban duracion 0).
# EPOCHREALTIME es bash 5+; fallback a segundos*1000 donde no exista.
ms_ahora() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local s="${EPOCHREALTIME%%.*}" f="${EPOCHREALTIME#*.}"
    printf '%s' "$(( s * 1000 + 10#${f:0:3} ))"
  else
    printf '%s' "$(( $(date +%s) * 1000 ))"
  fi
}

# Duracion en segundos con 3 decimales (numero JSON valido) a partir de ms.
duracion_s_desde() {
  local ini_ms="$1" fin_ms
  fin_ms="$(ms_ahora)"
  local d=$(( fin_ms - ini_ms ))
  printf '%d.%03d' "$(( d / 1000 ))" "$(( d % 1000 ))"
}

# Emite UNA linea JSONL. Nunca bloquea la corrida: si el archivo no se puede
# escribir, loguea a stderr y sigue (ADR 002 §2 — la observabilidad no frena
# la produccion). flock + linea max 4 KiB garantizan appends atomicos; si
# flock no existe (macOS del operador), append directo con aviso.
emitir_evento() {
  local evento="$1" resultado="$2" duracion="$3" detalle="$4"
  # detalle: truncado a 1 KiB ANTES de escapar (review PR#45 r2 H-M2: truncar
  # despues puede cortar un escape \" por la mitad y dejar un \ huerfano que
  # invalida el JSON). El escapado puede crecer el string, pero acotado y muy
  # por debajo del cap de linea. El resto de los strings tambien pasa por
  # json_str (review PR#45 H1).
  detalle="${detalle:0:1024}"
  detalle="$(json_str "$detalle")"
  local linea
  linea="$(printf '{"ts":"%s","run_id":"%s","repo":"%s","trabajo":"%s","rol":"%s","evento":"%s","resultado":%s,"duracion_s":%s,"costo_usd":null,"detalle":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_str "$RUN_ID")" "$(json_str "$REPO_NOMBRE")" \
    "$(json_str "$TRABAJO")" "$(json_str "$ROL")" "$(json_str "$evento")" \
    "$resultado" "$duracion" "$detalle")"
  linea="${linea:0:4096}"
  # Concurrencia (ADR 002 §2 + review PR#45 H4 y r2 H-A1): el lock se toma
  # sobre EVENTOS_LOCK — el archivo de lock SEPARADO que fija el ADR — y se
  # escribe a EVENTOS_FILE dentro del bloque locked. TODO emisor futuro (el
  # vigilante en PR 2 incluido) debe lockear ESTE MISMO archivo; lockear el
  # jsonl directo seria otro inode y no sincronizaria. En Linux (ambiente
  # del vigilante, roles en paralelo) flock es OBLIGATORIO — si falta, se
  # omite la emision con aviso (nunca JSONL intercalado corrupto, y la
  # corrida no se bloquea). El append directo queda solo para la maquina
  # del operador (macOS), donde no hay paralelismo real.
  if command -v flock >/dev/null 2>&1; then
    ( flock 9; printf '%s\n' "$linea" >> "$EVENTOS_FILE" ) 9>>"$EVENTOS_LOCK" 2>/dev/null \
      || echo "lanzar-rol: no pude emitir evento a $EVENTOS_FILE (no bloquea)" >&2
  elif [[ "$(uname)" == "Linux" ]]; then
    echo "lanzar-rol: flock no disponible en Linux — evento OMITIDO (instalar util-linux)." >&2
  else
    printf '%s\n' "$linea" >> "$EVENTOS_FILE" 2>/dev/null \
      || echo "lanzar-rol: no pude emitir evento a $EVENTOS_FILE (no bloquea)" >&2
  fi
}

# ADR 002 §5: al tomar un trabajo, asignar el issue a la cuenta maquina del
# rol. El mapeo rol->cuenta replica la tabla de docs/identidades.md (unica
# fuente de verdad; si esa tabla cambia, cambiar aca). Roles sin cuenta no
# asignan. Fallo de asignacion NO bloquea (el PAT del rol puede no tener
# permiso de issues): queda avisado en stderr.
if [[ -n "${FABRICA_ISSUE:-}" ]]; then
  case "$ROL" in
    qa)        CUENTA_ROL="qa-fabrica-gg" ;;
    seguridad) CUENTA_ROL="seguridad-fabrica-gg" ;;
    *)
      # Issue #48: aviso EXPLICITO para roles sin cuenta mapeada — si la
      # tabla de identidades.md suma una cuenta nueva, este mensaje delata
      # que falta actualizar el case (no cae en silencio).
      CUENTA_ROL=""
      echo "lanzar-rol: rol '$ROL' sin cuenta maquina en el mapeo local — no se asigna assignee (si la tabla de docs/identidades.md cambio, actualizar este case)." >&2
      ;;
  esac
  if [[ -n "$CUENTA_ROL" ]]; then
    # Issue #52: repo EXPLICITO — sin -R, gh infiere del cwd y un lanzamiento
    # desde otro directorio tocaria el repo equivocado. Si el slug no se
    # puede resolver, mejor no asignar que asignar a ciegas.
    SLUG_ISSUE="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    if [[ -z "$SLUG_ISSUE" ]]; then
      echo "lanzar-rol: no pude resolver el slug del repo — no se asigna assignee (no bloquea)." >&2
    # Review PR#45 r2 H-M3: la CAUSA del fallo queda visible en stderr (el
    # PAT del rol puede no tener issues:write y hay que poder verlo).
    elif ! salida_gh="$(gh issue edit "$FABRICA_ISSUE" -R "$SLUG_ISSUE" --add-assignee "$CUENTA_ROL" 2>&1 >/dev/null)"; then
      echo "lanzar-rol: no pude asignar #$FABRICA_ISSUE a $CUENTA_ROL (no bloquea): ${salida_gh:0:200}" >&2
    fi
  fi
fi

FULL_PROMPT="$(printf '%s\n\n---\n\nPedido del usuario:\n\n%s\n\n---\n\nrun_id de esta corrida: %s\nSi tu trabajo es una revision, inclui la linea `run: %s` en tu comentario firmado del PR (ADR 002).\n' \
  "$ROL_TEXT" "$PROMPT_TEXT" "$RUN_ID" "$RUN_ID")"

echo "lanzar-rol: rol=$ROL identidad=$IDENTIDAD run=$RUN_ID atribucion=${BITACORA_V2_HOOK_TOKEN_FILE:-generica}" >&2
emitir_evento "inicio" null null ""
# Evento reintento (ADR 002 §2): el vigilante pasa FABRICA_INTENTO cuando
# relanza tras fallo transitorio. Se valida numerico (misma disciplina que
# FABRICA_TRABAJO).
if [[ "${FABRICA_INTENTO:-1}" =~ ^[0-9]+$ && "${FABRICA_INTENTO:-1}" -gt 1 ]]; then
  emitir_evento "reintento" null null "intento ${FABRICA_INTENTO}"
fi
INICIO_MS="$(ms_ahora)"
# El separador -- es OBLIGATORIO: el prompt arranca con el frontmatter del
# archivo de rol ("---") y sin separador el CLI lo parsea como opcion
# (error: unknown option '---'). Encontrado en la primera corrida real del
# vigilante — el lanzador nunca habia sido ejecutado de punta a punta.
# Ya no usamos exec: hay que emitir el evento de cierre con el exit code
# real de la sesion (ADR 002 §2). El exit code se propaga intacto.
# Issue #47 (review PR#45 H2): claude corre en background con trap de
# TERM/INT — una cancelacion (timeout del vigilante, Ctrl-C del operador)
# mata a la sesion hija Y emite el evento de cierre; nada queda huerfano ni
# fuera de la observabilidad.
set +e
claude -p "$@" -- "$FULL_PROMPT" &
CLAUDE_PID=$!
trap 'kill "$CLAUDE_PID" 2>/dev/null; wait "$CLAUDE_PID" 2>/dev/null; emitir_evento "fallo" "\"fallo\"" "$(duracion_s_desde "$INICIO_MS")" "cancelado por senal"; exit 143' TERM INT
wait "$CLAUDE_PID"
RC=$?
trap - TERM INT
set -e
DURACION="$(duracion_s_desde "$INICIO_MS")"
if [[ $RC -eq 0 ]]; then
  emitir_evento "fin" '"ok"' "$DURACION" ""
else
  emitir_evento "fallo" '"fallo"' "$DURACION" "claude exit=$RC"
fi
exit "$RC"
