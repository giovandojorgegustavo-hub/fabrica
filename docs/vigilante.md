# El vigilante — punto 4: forzar el trabajo

`scripts/vigilante-revisiones.sh` es el motor que hace que la fabrica trabaje
sola. El candado de GitHub (branch protection + identidades, ver
[`identidades.md`](identidades.md)) fuerza el RESULTADO: sin dos aprobaciones
no hay merge. El vigilante fuerza el TRABAJO: detecta PRs abiertos sin la
revision de cada rol y lanza a los trabajadores. El operador (director) no
enciende maquinas — abre PRs, lee revisiones terminadas y mergea.

## Flujo

```
PR abierto ──> timer (cada 2 min) ──> vigilante
                                        │ ¿falta review de qa/seguridad
                                        │  sobre el HEAD actual?
                                        ▼
                              lanzar-rol.sh <rol> "<prompt>"
                                        │ (token de la cuenta maquina,
                                        │  sesion restringida a gh)
                                        ▼
                          review firmada en el PR (approve /
                          request-changes) con author.login del rol
                                        ▼
                       branch protection exige 2 aprobaciones
                                        ▼
                            el operador lee y mergea
```

## Instalacion (operador, una vez)

1. Lista de repos vigilados (paths de checkouts locales del operador):

```
sudo sh -c 'printf "%s\n" "/home/fiax/fabrica" > /etc/fabrica/vigilante.repos'
sudo chown root:root /etc/fabrica/vigilante.repos
sudo chmod 644 /etc/fabrica/vigilante.repos
```

Dueno root a proposito: quien escribe esa lista decide sobre que repos se
lanzan sesiones con tokens de rol. El operador la lee, root la edita.

2. Unit + timer de systemd (como root):

```ini
# /etc/systemd/system/fabrica-vigilante.service
[Unit]
Description=Vigilante de revisiones de la fabrica (punto 4)

[Service]
Type=oneshot
User=fiax
ExecStart=/home/fiax/fabrica/scripts/vigilante-revisiones.sh
```

```ini
# /etc/systemd/system/fabrica-vigilante.timer
[Unit]
Description=Corre el vigilante de revisiones cada 2 minutos

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
```

```
sudo systemctl daemon-reload
sudo systemctl enable --now fabrica-vigilante.timer
```

3. Verificar: `systemctl list-timers fabrica-vigilante.timer` y
   `journalctl -u fabrica-vigilante.service -n 20`.

## Requisitos

- `gh` autenticado como el operador (listar PRs usa SU identidad; las
  revisiones usan los tokens de rol que inyecta `lanzar-rol.sh`).
- `claude` CLI instalado y autenticado para el usuario del servicio.
- Tokens de rol en `/etc/fabrica/tokens/` segun `identidades.md`.
- El repo vigilado debe tener `scripts/lanzar-rol.sh` y `.claude/agents/`.

## Permisos de la sesion revisora

El vigilante lanza cada rol con `--allowedTools "Bash(gh:*)"`: la sesion
headless SOLO puede ejecutar `gh`. No puede tocar el working tree, correr
otros comandos ni leer fuera de su sandbox de sesion. Esto implementa la
mitigacion del vector de prompt injection documentado en `identidades.md`:
aunque el contenido del PR logre inyectar instrucciones, la superficie
ejecutable de la sesion es gh y nada mas.

## Estado y reintentos (v3 — ADR 002)

- `~/.fabrica-vigilante/lock` — flock: una pasada a la vez.
- `~/.fabrica-vigilante/<repo>-pr<N>-<head12>-<rol>` — marker de lanzamiento:
  evita relanzar mientras la review no aparece. Un push nuevo cambia el head
  y genera marker nuevo (la review vieja queda descartada por branch
  protection y por el chequeo del vigilante).
- **Reintentos automaticos con limite**: un fallo TRANSITORIO (timeout de
  sesion rc=124, red caida, CLI muerta — la sesion no llego a dejar su
  review por causa externa) se reintenta solo hasta 2 veces, una por pasada
  del timer (la cadencia de 2 min es la espera entre reintentos). El
  contador vive en `<marker>.intentos`. Un fallo NO transitorio (exit 2/3/4
  de lanzar-rol: argumentos, rol inexistente, token invalido) o el tercer
  fallo marcan el trabajo `bloqueada`.
- `<marker>.fallo` — testigo del ultimo fallo (para el log y la autopsia).
  Ya NO frena reintentos por si solo.
- `<marker>.bloqueada` — el gate real: requiere operador. Mirar
  `vigilante.log`, corregir la causa, y **borrar el `.bloqueada`** para
  rehabilitar (el contador de intentos arranca de cero — coherente con el
  ADR: la intervencion humana resetea el historial).
- **Labels de estado** en el issue del trabajo (resuelto del PR via
  `closingIssuesReferences`): `estado:en-curso` al lanzar,
  `estado:fallo-N` en reintento, `estado:bloqueada` al bloquear. El tablero
  de Projects es solo vista: si difieren, ganan los labels.
- **Eventos JSONL** en `~/.fabrica-vigilante/eventos.jsonl` (los emite
  lanzar-rol): `inicio`, `reintento`, `fin`, `fallo` — con `run_id`,
  duracion y exit code. Contrato de formato en el ADR 002; la bitacora los
  ingiere cuando exista su tabla.
- Contrato de entorno vigilante → lanzar-rol: `FABRICA_TRABAJO=pr<N>`,
  `FABRICA_ISSUE=<issue>`, `FABRICA_INTENTO=<n>`.
- `~/.fabrica-vigilante/vigilante.log` — stdout/stderr de las sesiones.
  Los tokens no aparecen ahi (lanzar-rol no los imprime).

## Que NO hace

- No mergea, no cierra PRs, no comenta como el operador.
- No toca el working tree de los repos vigilados.
- No lanza roles sin cuenta maquina (arquitecto/producto firman por
  convencion — ver tabla en `identidades.md`).
- No reintenta fallos NO transitorios ni mas de 2 veces: `bloqueada` es
  decision del operador, siempre (ADR 002 §4).

## Relacion con la bitacora

El vigilante es el motor MINIMO del punto 4 — un timer y un script. Cuando
la bitacora nueva exista, puede absorber este rol con orquestacion completa
(trazas en vivo, historial, colas). El contrato queda: la fabrica define el
proceso; el motor — este script hoy, la bitacora manana — lo ejecuta.
