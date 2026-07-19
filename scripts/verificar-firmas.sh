#!/usr/bin/env bash
# scripts/verificar-firmas.sh — valida que las revisiones firmadas de un PR
# vengan de las cuentas maquina reales, no solo de un comentario con formato
# de firma.
#
# Uso:
#   scripts/verificar-firmas.sh <PR> [--con-arquitecto] [--con-producto]
#
# Ejemplo:
#   scripts/verificar-firmas.sh 12
#   scripts/verificar-firmas.sh 42 --con-arquitecto --con-producto
#
# Que hace:
#   1. Lee todos los comentarios del PR via 'gh pr view --json comments'.
#   2. Para cada rol requerido (qa, seguridad, y opcionalmente arquitecto/producto),
#      exige que exista al menos UN comentario con marcador "**Rol**: <rol>"
#      Y que ese comentario provenga de la cuenta maquina 'fabrica-<rol>'.
#   3. Falla claro si:
#        - No hay comentario firmado para un rol requerido.
#        - Hay un comentario que dice ser de un rol pero el author.login NO es
#          la cuenta maquina esperada (posible autoaprobacion disfrazada).
#
# El chequeo textual solo (grep de "**Rol**: <x>") NO alcanza: cualquiera con
# pull_request:write puede escribir eso. La validacion real es que
# author.login == fabrica-<rol>. Este script es el enforcement mecanico que
# CLAUDE.md exige antes del merge.
#
# Dependencias: gh (autenticado), jq.

set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "verificar-firmas: falta 'gh' (GitHub CLI)." >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "verificar-firmas: falta 'jq'." >&2
  exit 2
fi

if [[ $# -lt 1 ]]; then
  echo "uso: $0 <PR> [--con-arquitecto] [--con-producto]" >&2
  exit 2
fi

PR="$1"; shift

# Roles requeridos por default: qa y seguridad (todo PR de codigo).
REQUERIDOS=("qa" "seguridad")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --con-arquitecto) REQUERIDOS+=("arquitecto") ;;
    --con-producto)   REQUERIDOS+=("producto") ;;
    *)
      echo "verificar-firmas: flag desconocido '$1'" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! "$PR" =~ ^[0-9]+$ ]]; then
  echo "verificar-firmas: PR debe ser numero (ej: 12)." >&2
  exit 2
fi

# gh pr view devuelve todos los comentarios con .comments[].author.login y .body.
COMMENTS_JSON="$(gh pr view "$PR" --json comments)"

FALLOS=0
for ROL in "${REQUERIDOS[@]}"; do
  ESPERADO="fabrica-${ROL}"
  # Busca comentarios cuyo body contenga "**Rol**: <rol>" al principio de una linea.
  # jq extrae los author.login de los comentarios que matchean.
  MATCH_LOGINS="$(printf '%s' "$COMMENTS_JSON" \
    | jq -r --arg rol "$ROL" '
        .comments[]
        | select(.body | test("(^|\n)\\*\\*Rol\\*\\*: " + $rol + "(\\s|$)"; "i"))
        | .author.login
      ')"

  if [[ -z "$MATCH_LOGINS" ]]; then
    echo "verificar-firmas: FALTA revision firmada de rol '$ROL' en PR #$PR." >&2
    FALLOS=$((FALLOS + 1))
    continue
  fi

  OK_PARA_ROL=0
  while IFS= read -r LOGIN; do
    if [[ "$LOGIN" == "$ESPERADO" ]]; then
      OK_PARA_ROL=1
      echo "verificar-firmas: OK rol='$ROL' author.login='$LOGIN'"
    else
      echo "verificar-firmas: SOSPECHOSO rol='$ROL' viene de author.login='$LOGIN' (esperado '$ESPERADO')." >&2
      FALLOS=$((FALLOS + 1))
    fi
  done <<< "$MATCH_LOGINS"

  if [[ $OK_PARA_ROL -eq 0 ]]; then
    echo "verificar-firmas: rol '$ROL' no tiene NINGUN comentario firmado por '$ESPERADO'." >&2
  fi
done

if [[ $FALLOS -gt 0 ]]; then
  echo "verificar-firmas: $FALLOS problemas de firma en PR #$PR. NO mergear." >&2
  exit 1
fi

echo "verificar-firmas: PR #$PR con firmas validas de ${REQUERIDOS[*]}."
