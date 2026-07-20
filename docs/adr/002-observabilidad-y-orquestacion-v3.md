# ADR 002: Observabilidad y orquestacion v3

- **Estado**: propuesto (rev 2)
- **Fecha**: 2026-07-20
- **Rev 2 (2026-07-20)**: incorpora la revision qa del PR #44 — H1 (alto:
  definicion explicita de fallo transitorio), H2 (mapeo PR→issue), H3/H4
  (concurrencia y limites del JSONL), H5 (timestamps), H6 (precondicion
  sub-issues), H7/H8 (cleanup de labels y colision de run_id) y las
  ambiguedades de estados senaladas.
- **Origen**: orden del dueño, issue #43. La fabrica funciona pero es opaca en
  runtime (logs de texto plano) y fragil ante fallos (`.fallo` manual siempre,
  sin estados explicitos, sin asignacion visible).

## Contexto

El circuito (issue → rama → PR → qa+seguridad → merge) esta en regimen. Lo que
NO se puede responder hoy sin leer logs a mano:

- ¿Que paso en la corrida de anoche? ¿Cuanto tardo cada estacion? ¿Cuanto costo?
- ¿Que trabajos estan abiertos, en que estado, y quien los tiene?
- ¿Cuantas veces fallo un lanzamiento antes de necesitar al operador?

Ademas, una orden multi-operario (requerimientos → arquitecto → backend/ux/
frontend) no tiene estructura formal: vive en prosa dentro de un issue.

Principio rector heredado de `docs/vigilante.md`: la fabrica define el proceso;
el motor (scripts hoy, bitacora mañana) lo ejecuta. Esta ADR define QUE emite
la fabrica y QUE estados existen — no adopta herramienta externa alguna.

## Opciones consideradas

1. **Orquestador dedicado (Temporal, Prefect)**. Contra: infraestructura nueva,
   curva de aprendizaje, dimensionado para miles de corridas concurrentes que
   no tenemos. Automatizar antes de necesitarlo. Descartada.
2. **Plataforma de observabilidad LLM (Langfuse self-hosted)**. A favor: trazas
   ricas. Contra: servicio nuevo que operar; la bitacora ya existe como destino
   natural de ingesta. Buen paso 2 si el volumen lo pide. Descartada por ahora.
3. **Eventos en git (commitear logs)**. Contra: git versiona artefactos en
   reposo, no eventos en el tiempo; miles de commits de ruido. Descartada.
4. **Eventos JSONL locales + estados como labels de GitHub + tablero como
   vista** (elegida). Cero infraestructura nueva; GitHub ya es la fuente de
   verdad del trabajo; la bitacora ingiere los JSONL cuando exista su tabla.

## Decision

### 1. `run_id` — identidad de cada corrida

Toda sesion lanzada por la fabrica (vigilante o lanzador manual) recibe un
`run_id` unico al inicio:

```
<UTC compacto>-<repo>-<trabajo>-<rol>-<sufijo>
ej: 20260720T153000Z-fabrica-pr44-qa-a3f1
    20260720T160102Z-bitacora-issue129-backend-09be
```

- `trabajo` = `pr<N>` o `issue<N>` segun el disparador.
- `sufijo` = 4 hex aleatorios (`openssl rand -hex 2` o equivalente). Elimina
  colisiones en lanzamientos del mismo segundo (H8).
- El timestamp del `run_id` usa ISO8601 **basico** (sin separadores) a
  proposito: es seguro para nombres de archivo y refs. El campo `ts` de los
  eventos usa ISO8601 **extendido**. Ambos son el mismo reloj UTC; la
  conversion es mecanica y esta es la unica convencion valida (H5).
- Cada reintento es una sesion nueva con `run_id` nuevo. La clave de
  agrupacion para auditar "todas las corridas de qa sobre pr44" es
  `(repo, trabajo, rol)` — queda fijada aqui como contrato de consulta.
- El `run_id` aparece en: cada evento JSONL, el log de la sesion, y el
  comentario firmado que el rol deja en el PR (linea `run: <run_id>`).

### 2. Eventos JSONL — que emite cada corrida

Cada paso emite UNA linea JSON en `~/.fabrica-vigilante/eventos.jsonl`:

```json
{"ts":"2026-07-20T15:30:00Z","run_id":"...","repo":"fabrica","trabajo":"pr44",
 "rol":"qa","evento":"inicio|fin|fallo|reintento","resultado":"ok|fallo|null",
 "duracion_s":312,"costo_usd":0.41,"detalle":"texto corto"}
```

Reglas:

- `evento:inicio` al lanzar; `evento:fin` con `resultado` y `duracion_s` al
  terminar; `evento:fallo` con `detalle` del error; `evento:reintento` con el
  numero de intento.
- Campos de costo/duracion: best effort — si la sesion no los reporta, `null`.
  Nunca bloquean la corrida.
- **Concurrencia (H3)**: todo append se hace bajo `flock` sobre
  `~/.fabrica-vigilante/eventos.lock` (mismo mecanismo que ya usa el
  vigilante), y cada linea tiene un maximo de **4 KiB**. Ambas cosas juntas
  garantizan lineas atomicas y JSONL parseable.
- **`detalle` (H4)**: maximo **1 KiB**; se trunca con `…` al final; los
  saltos de linea se reemplazan por ` | ` antes de escribir. Un traceback
  completo va al log de la sesion, no al evento.
- **Fallo de emision**: si el archivo de eventos no se puede abrir o escribir
  (disco lleno, permisos), la corrida **continua** y el error se loguea a
  stderr del vigilante. La observabilidad nunca bloquea la produccion.
- **Rotacion**: el archivo activo se llama siempre `eventos.jsonl`. El
  operador rota renombrando a `eventos-YYYYMMDD.jsonl`; la ingesta de
  bitacora lee el activo y los rotados por patron de nombre. Retencion
  minima antes de borrar: 3 meses.
- El archivo es append-only, local del operador, fuera del repo.
  **La tabla de ingesta y su migracion pertenecen al repo bitacora** (orden
  aparte alla). Este ADR fija el contrato del formato; la bitacora consume.

### 3. Maquina de estados por trabajo — labels de GitHub

Fuente de verdad: labels `estado:*` en el **issue** del trabajo. El tablero de
Projects es SOLO una vista; si tablero y labels difieren, ganan los labels.

```
pendiente → en-curso → terminada (= issue cerrado, sin label)
                │
                ├─ fallo-1 → en-curso (reintento)
                ├─ fallo-2 → en-curso (reintento)
                └─ bloqueada (fallo persistente o 3er fallo: requiere operador)
```

- Quien lanza (vigilante / lanzar-rol) escribe los labels via `gh issue edit`.
- **Mapeo PR→issue (H2)**: los roles de revision se disparan sobre PRs, pero
  los labels viven en el issue. La regla: todo PR de la fabrica DEBE
  referenciar su issue en el body (`Cierra #N` / `Refs #N`); el vigilante
  resuelve el issue via `gh pr view --json closingIssuesReferences` (o
  parseando la referencia) y actualiza ESE issue. Un PR sin issue referenciado
  emite eventos igual (con `trabajo:pr<N>`) pero no toca labels — y es ademas
  una violacion de proceso que qa debe señalar en su revision.
- `bloqueada` es terminal hasta que el operador interviene. **Al re-etiquetar
  `pendiente` (H7): se remueven los labels `fallo-*` y el contador arranca de
  cero.** La intervencion humana resetea el historial de reintentos — si el
  operador toco algo, el contexto del fallo cambio.
- **Mientras el autor corrige un REQUEST_CHANGES**, el issue permanece
  `en-curso`: sigue siendo trabajo activo. REQUEST_CHANGES no es fallo ni
  pausa — es el circuito funcionando.
- Los PRs no llevan labels de estado: su estado ya lo da GitHub (open/draft/
  merged) y el circuito de revisiones.

### 4. Reintentos con limite

- Fallo **transitorio**: hasta 2 reintentos automaticos, uno por pasada
  siguiente del vigilante (el timer de 2 min actua de espera natural).
  Labels `fallo-1`, `fallo-2`.
- Tercer fallo o fallo **no transitorio**: label `bloqueada` + se conserva el
  marker `.fallo` actual como testigo. El operador decide.

#### Que se considera transitorio (H1)

Criterio rector: **transitorio = la sesion no llego a producir su artefacto
(el comentario firmado / entregable) por causa EXTERNA al contenido del
trabajo.** Clasificacion por exit code + patron de log; la tabla exacta de
exit codes la fija el PR del vigilante contra la version de la CLI en uso,
dentro de estas categorias:

**Transitorio (reintenta):**
- Timeout o expiracion de la sesion (la CLI corto por tiempo).
- Error de red / API no disponible / rate limit.
- Proceso de la CLI caido o matado (exit != 0 sin veredicto en el PR).
- Señal observable comun: la sesion termino SIN dejar comentario firmado.

**NO transitorio (directo a `bloqueada`):**
- Autenticacion fallida: PAT invalido, expirado o sin permisos (401/403).
- Error del lanzador: rol inexistente, archivo de prompt ausente, argumentos
  invalidos.
- Repo o PR inaccesible (borrado, permisos revocados).

**NO es fallo (no reintenta, no bloquea):**
- Sesion completa con veredicto del rol, incluido REQUEST_CHANGES.
- Hallazgos bloqueantes en la revision: eso es el circuito, no un error.

**Default ante ambiguedad: NO transitorio → `bloqueada`.** Es fail-safe: un
falso bloqueo cuesta una mirada del operador; un falso reintento en loop
cuesta dinero sin control.

### 5. Assignee — quien trabaja que

Al tomar un trabajo, el lanzador asigna el issue a la cuenta maquina del rol:
`gh issue edit <N> --add-assignee <cuenta-rol>`. Al terminar (o bloquear), el
assignee queda como registro de quien lo trabajo. Vista por operario en el
tablero = group by Assignees.

### 6. Ordenes multi-operario — issue padre + sub-issues

- **Precondicion (H6)**: verificar que la feature de sub-issues este
  habilitada en el repo/org antes del PR que documente esta convencion en
  `CLAUDE.md`. Fallback si no esta disponible: task-list de issues linkeados
  en el cuerpo del padre (`- [ ] #N`), que GitHub tambien trackea.
- La orden es un **issue padre**: contiene los artefactos de las estaciones
  tempranas (requerimientos destilados, links a mockups) y avanza por ellas.
- El rol `arquitecto` comenta su plan en el padre y lo parte en **sub-issues**,
  uno por rol ejecutor, cada uno con su ciclo issue → rama → PR completo y su
  propio estado/assignee. El `arquitecto` queda como assignee del PADRE hasta
  su cierre: es el responsable del conjunto.
- El padre cierra cuando cierran todos los hijos. GitHub muestra el progreso
  en la tarjeta del padre.
- **Si un sub-issue queda `bloqueada`, el padre NO cambia automaticamente**:
  el padre refleja progreso, no estado agregado. El operador ve el bloqueo en
  el hijo (tablero / labels) y decide si el conjunto se frena.
- Regla de encadenamiento de PRs hijos: aplica la leccion del issue #28
  (retarget antes de mergear el padre).

## Alcance de implementacion (PRs separados, en orden)

1. `lanzar-rol.sh`: genera `run_id`, emite eventos JSONL (flock + limites),
   asigna assignee.
2. `vigilante-revisiones.sh`: resuelve PR→issue, lee/escribe labels de estado,
   reintenta con limite segun la clasificacion de transitorios, marca
   `bloqueada`. Actualiza `docs/vigilante.md` en el mismo PR.
3. `CLAUDE.md`: documenta la convencion padre/sub-issues (previa verificacion
   de la precondicion H6) y los labels de estado.
4. Repo bitacora (orden aparte): migracion de tabla de eventos + ingesta de
   `eventos.jsonl` activo y rotados.

## Que NO cambia

- El circuito de revision, las identidades, branch protection: intactos.
- El tablero de Projects: opcional, es una vista humana; ningun script depende
  de el.
