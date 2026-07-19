#!/usr/bin/env bash
# scripts/deploy.sh — despliega el commit actual al ambiente vivo y verifica.
#
# Uso:
#   scripts/deploy.sh
#
# Configuracion por repo en scripts/deploy.env (NO versionado):
#   SERVICE_NAME=<systemd unit>           # ej: bitacora-api
#   HEALTH_URL=<url del smoke test>       # ej: http://10.14.0.1:8000/salud
#   MIGRATIONS_CMD=<comando o vacio>      # ej: python3 scripts/migrar.py
#   BRANCH=<rama viva>                    # default: main
#
# Falla claro y se detiene en cuanto una etapa no cumple. Cada etapa imprime
# lo que hace, y la ultima confirma que el proceso vivo esta corriendo el
# commit nuevo comparando el timestamp de inicio del servicio antes y despues
# del restart.

set -euo pipefail

CONFIG="${DEPLOY_CONFIG:-scripts/deploy.env}"
if [[ ! -f "$CONFIG" ]]; then
  echo "deploy: falta $CONFIG (configuracion del repo)." >&2
  echo "deploy: crear con SERVICE_NAME, HEALTH_URL, MIGRATIONS_CMD (opcional), BRANCH (opcional)." >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${SERVICE_NAME:?deploy: falta SERVICE_NAME en $CONFIG}"
: "${HEALTH_URL:?deploy: falta HEALTH_URL en $CONFIG}"
BRANCH="${BRANCH:-main}"
MIGRATIONS_CMD="${MIGRATIONS_CMD:-}"

echo "==> [1/5] git switch $BRANCH && pull --ff-only"
git switch "$BRANCH"
git pull --ff-only

TARGET_COMMIT="$(git rev-parse HEAD)"
echo "==> commit objetivo: $TARGET_COMMIT"

if [[ -n "$MIGRATIONS_CMD" ]]; then
  echo "==> [2/5] migraciones: $MIGRATIONS_CMD"
  eval "$MIGRATIONS_CMD"
else
  echo "==> [2/5] migraciones: nada declarado, salto"
fi

echo "==> [3/5] restart de $SERVICE_NAME"
BEFORE_TS="$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE_NAME" 2>/dev/null || true)"
sudo systemctl restart "$SERVICE_NAME"
# Espera corta para que systemd registre el nuevo timestamp.
sleep 2
AFTER_TS="$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE_NAME")"
if [[ -z "$AFTER_TS" ]]; then
  echo "deploy: no pude leer ActiveEnterTimestamp de $SERVICE_NAME" >&2
  exit 4
fi
if [[ "$BEFORE_TS" == "$AFTER_TS" ]]; then
  echo "deploy: ActiveEnterTimestamp NO cambio ($BEFORE_TS)." >&2
  echo "deploy: $SERVICE_NAME no reinicio realmente; algo se comio el restart." >&2
  exit 5
fi
echo "deploy: $SERVICE_NAME reinicio: $BEFORE_TS -> $AFTER_TS"

echo "==> [4/5] smoke test contra $HEALTH_URL"
if ! curl --fail --silent --show-error --max-time 10 "$HEALTH_URL" > /dev/null; then
  echo "deploy: smoke test FALLO en $HEALTH_URL" >&2
  exit 6
fi
echo "deploy: smoke OK."

echo "==> [5/5] confirmacion final"
STATE="$(systemctl show -p ActiveState --value "$SERVICE_NAME")"
if [[ "$STATE" != "active" ]]; then
  echo "deploy: $SERVICE_NAME esta en estado '$STATE', no 'active'" >&2
  exit 7
fi
echo "deploy: $SERVICE_NAME activo desde $AFTER_TS, corriendo commit $TARGET_COMMIT."
echo "deploy: OK."
