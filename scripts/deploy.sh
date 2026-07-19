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
# Contrato del endpoint de salud (obligatorio para el DoD):
#   HTTP 200 + JSON con al menos { "status": "ok", "commit": "<sha completo>" }.
#   - "status" != "ok" -> app degradada -> el deploy falla aunque HTTP sea 200.
#   - "commit" != commit desplegado -> el proceso vivo corre otro codigo ->
#     el deploy falla. Esto cubre el caso de "systemd reinicio pero el
#     WorkingDirectory apunta al checkout viejo".
#
# Dependencias: jq (para leer el JSON de salud sin regex fragil).
#
# Falla claro y se detiene en cuanto una etapa no cumple. Cada etapa imprime
# lo que hace, y la ultima confirma que el proceso vivo esta corriendo el
# commit nuevo comparando el hash reportado por /salud contra el commit
# desplegado ademas del timestamp de inicio del servicio.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "deploy: falta 'jq' (necesario para leer el JSON del endpoint de salud)." >&2
  exit 2
fi

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
HEALTH_BODY="$(curl --fail --silent --show-error --max-time 10 "$HEALTH_URL")" || {
  echo "deploy: smoke test FALLO en $HEALTH_URL (HTTP no-2xx o timeout)" >&2
  exit 6
}
HEALTH_STATUS="$(printf '%s' "$HEALTH_BODY" | jq -r '.status // empty')"
if [[ "$HEALTH_STATUS" != "ok" ]]; then
  echo "deploy: /salud respondio HTTP OK pero status='$HEALTH_STATUS' (esperado 'ok')." >&2
  echo "deploy: la app esta viva pero degradada; el deploy no se acepta." >&2
  echo "deploy: body recibido: $HEALTH_BODY" >&2
  exit 6
fi
echo "deploy: smoke OK (status=ok)."

echo "==> [5/5] confirmacion final: proceso vivo corre commit desplegado"
STATE="$(systemctl show -p ActiveState --value "$SERVICE_NAME")"
if [[ "$STATE" != "active" ]]; then
  echo "deploy: $SERVICE_NAME esta en estado '$STATE', no 'active'" >&2
  exit 7
fi
LIVE_COMMIT="$(printf '%s' "$HEALTH_BODY" | jq -r '.commit // empty')"
if [[ -z "$LIVE_COMMIT" ]]; then
  echo "deploy: /salud no reporta 'commit'; contrato del endpoint incumplido." >&2
  echo "deploy: sin ese campo, no se puede validar que el proceso vivo corre '$TARGET_COMMIT'." >&2
  exit 8
fi
if [[ "$LIVE_COMMIT" != "$TARGET_COMMIT" ]]; then
  echo "deploy: el proceso vivo reporta commit '$LIVE_COMMIT'," >&2
  echo "deploy: pero se desplego '$TARGET_COMMIT'." >&2
  echo "deploy: systemd reinicio otra cosa (probable WorkingDirectory apuntando a otro checkout)." >&2
  exit 9
fi
echo "deploy: $SERVICE_NAME activo desde $AFTER_TS, corriendo commit $TARGET_COMMIT (confirmado por /salud)."
echo "deploy: OK."
