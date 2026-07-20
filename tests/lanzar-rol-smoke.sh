#!/usr/bin/env bash
# tests/lanzar-rol-smoke.sh — smoke tests del lanzador (issues #50 y #53).
#
# Corre SIN tocar GitHub ni lanzar sesiones reales: `claude` es un stub en un
# PATH prefijado y HOME apunta a un sandbox temporal que se limpia al salir.
# FABRICA_ISSUE nunca se setea en los casos que llegan a ejecutar, asi que
# gh no se invoca. Requiere python3 (validacion JSON con parser real).
#
# Uso: tests/lanzar-rol-smoke.sh   (desde cualquier directorio del repo)

set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
STUB="$TMP/bin/claude"
EVENTOS="$TMP/home/.fabrica-vigilante/eventos.jsonl"
FALLOS=0

correr() {
  # Ejecuta el lanzador en el sandbox; devuelve su exit code sin matar la suite.
  local rc=0
  PATH="$TMP/bin:$PATH" HOME="$TMP/home" "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

caso() { printf '== %s\n' "$1"; }
ok()   { printf '   OK\n'; }
mal()  { printf '   FALLO: %s\n' "$1"; FALLOS=$((FALLOS + 1)); }

# --- 1. Camino feliz: inicio + fin ok, exit 0 ---------------------------
caso "camino feliz emite inicio + fin ok"
printf '#!/bin/bash\nexit 0\n' > "$STUB"; chmod +x "$STUB"
rm -f "$EVENTOS"
rc="$(FABRICA_TRABAJO=pr999 correr scripts/lanzar-rol.sh backend "test")"
if [[ "$rc" == "0" ]] && python3 - "$EVENTOS" <<'EOF'
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1])]
assert [e["evento"] for e in evs] == ["inicio", "fin"], evs
assert evs[1]["resultado"] == "ok"
assert isinstance(evs[1]["duracion_s"], (int, float))
EOF
then ok; else mal "rc=$rc o eventos inesperados"; fi

# --- 2. Exit code se propaga; evento fallo con detalle ------------------
caso "exit code se propaga y emite fallo"
printf '#!/bin/bash\nexit 3\n' > "$STUB"
rm -f "$EVENTOS"
rc="$(FABRICA_TRABAJO=pr999 correr scripts/lanzar-rol.sh backend "test")"
if [[ "$rc" == "3" ]] && python3 - "$EVENTOS" <<'EOF'
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1])]
assert evs[-1]["evento"] == "fallo" and "exit=3" in evs[-1]["detalle"], evs
EOF
then ok; else mal "rc=$rc (esperaba 3) o evento fallo ausente"; fi

# --- 3. FABRICA_TRABAJO invalido aborta claro, sin eventos --------------
caso "FABRICA_TRABAJO con comillas aborta exit 2"
rm -f "$EVENTOS"
rc="$(FABRICA_TRABAJO='x","evento":"pwned' correr scripts/lanzar-rol.sh backend "test")"
if [[ "$rc" == "2" && ! -s "$EVENTOS" ]]; then ok; else mal "rc=$rc o emitio eventos"; fi

# --- 4. FABRICA_TRABAJO gigante aborta (cap 64, H-M1) -------------------
caso "FABRICA_TRABAJO de 5000 chars aborta exit 2"
rc="$(FABRICA_TRABAJO="$(printf 'a%.0s' {1..5000})" correr scripts/lanzar-rol.sh backend "test")"
if [[ "$rc" == "2" ]]; then ok; else mal "rc=$rc"; fi

# --- 5. FABRICA_ISSUE no numerico aborta (H-B1) -------------------------
caso "FABRICA_ISSUE con URL aborta exit 2"
rc="$(FABRICA_ISSUE="https://github.com/otro/repo/issues/1" correr scripts/lanzar-rol.sh backend "test")"
if [[ "$rc" == "2" ]]; then ok; else mal "rc=$rc"; fi

# --- 6. Aritmetica del cap de linea (#53): peor caso permitido ----------
caso "TRABAJO de 64 chars: toda linea < 4096 y JSON valido"
printf '#!/bin/bash\nexit 7\n' > "$STUB"
rm -f "$EVENTOS"
rc="$(FABRICA_TRABAJO="$(printf 'a%.0s' {1..64})" FABRICA_INTENTO=2 correr scripts/lanzar-rol.sh backend "test")"
if [[ "$rc" == "7" ]] && python3 - "$EVENTOS" <<'EOF'
import json, sys
for l in open(sys.argv[1]):
    assert len(l.rstrip("\n")) < 4096, len(l)
    json.loads(l)
EOF
then ok; else mal "rc=$rc o linea invalida/larga"; fi

# --- 7. Evento reintento con FABRICA_INTENTO > 1 ------------------------
caso "FABRICA_INTENTO=2 emite evento reintento"
if python3 - "$EVENTOS" <<'EOF'
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1])]
assert any(e["evento"] == "reintento" and "intento 2" in e["detalle"] for e in evs), evs
EOF
then ok; else mal "evento reintento ausente"; fi

# --- 8. Señal TERM: exit 143, sin huerfanos, evento de cierre -----------
caso "kill -TERM mata al hijo y emite fallo cancelado"
printf '#!/bin/bash\nexec sleep 30\n' > "$STUB"
rm -f "$EVENTOS"
PATH="$TMP/bin:$PATH" HOME="$TMP/home" FABRICA_TRABAJO=pr999 \
  scripts/lanzar-rol.sh backend "test" >/dev/null 2>&1 &
WRAPPER=$!
sleep 2
kill -TERM "$WRAPPER" 2>/dev/null || true
rc=0; wait "$WRAPPER" || rc=$?
huerfano=0
# El sleep del stub debe haber muerto con el wrapper (exec => mismo PID).
pgrep -P 1 -f "^sleep 30$" >/dev/null 2>&1 && huerfano=1
if [[ "$rc" == "143" && "$huerfano" == "0" ]] && python3 - "$EVENTOS" <<'EOF'
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1])]
assert evs[-1]["evento"] == "fallo" and "senal" in evs[-1]["detalle"], evs
EOF
then ok; else mal "rc=$rc huerfano=$huerfano o evento de cierre ausente"; fi

# ------------------------------------------------------------------------
if [[ "$FALLOS" -eq 0 ]]; then
  echo "smoke: TODOS los casos OK"
else
  echo "smoke: $FALLOS caso(s) FALLARON" >&2
  exit 1
fi
