# ADR 002: Observabilidad y orquestacion v3

- **Estado**: propuesto
- **Fecha**: 2026-07-20
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
<UTC compacto>-<repo>-<trabajo>-<rol>
ej: 20260720T153000Z-fabrica-pr44-qa
    20260720T160102Z-bitacora-issue129-backend
```

- `trabajo` = `pr<N>` o `issue<N>` segun el disparador.
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
- El archivo es append-only, local del operador, fuera del repo (mismo
  directorio de estado que ya usa el vigilante). Rotacion: el operador archiva
  cuando pese; la fabrica no borra.
- **La tabla de ingesta y su migracion pertenecen al repo bitacora** (orden
  aparte alla). Este ADR fija el contrato del formato; la bitacora consume.

### 3. Maquina de estados por trabajo — labels de GitHub

Fuente de verdad: labels `estado:*` en el issue del trabajo. El tablero de
Projects es SOLO una vista; si tablero y labels difieren, ganan los labels.

```
pendiente → en-curso → terminada (= issue cerrado, sin label)
                │
                ├─ fallo-1 → en-curso (reintento)
                ├─ fallo-2 → en-curso (reintento)
                └─ bloqueada (fallo persistente o 3er fallo: requiere operador)
```

- Quien lanza (vigilante / lanzar-rol) escribe los labels via `gh issue edit`.
- `bloqueada` es terminal hasta que el operador interviene y re-etiqueta
  `pendiente`.
- Los PRs no llevan labels de estado: su estado ya lo da GitHub (open/draft/
  merged) y el circuito de revisiones.

### 4. Reintentos con limite

- Fallo **transitorio** (sesion que expira, error de red, claude CLI caido):
  hasta 2 reintentos automaticos, uno por pasada siguiente del vigilante
  (el timer de 2 min actua de espera natural). Labels `fallo-1`, `fallo-2`.
- Tercer fallo o fallo **no transitorio**: label `bloqueada` + se conserva el
  marker `.fallo` actual como testigo. El operador decide.
- Un REQUEST_CHANGES de una revision NO es fallo: es el circuito funcionando.
- Esto reemplaza el "NO se reintenta solo" de `docs/vigilante.md` — la
  experiencia mostro que la mayoria de los `.fallo` son transitorios y el
  costo del loop se acota con el limite de 2.

### 5. Assignee — quien trabaja que

Al tomar un trabajo, el lanzador asigna el issue a la cuenta maquina del rol:
`gh issue edit <N> --add-assignee <cuenta-rol>`. Al terminar (o bloquear), el
assignee queda como registro de quien lo trabajo. Vista por operario en el
tablero = group by Assignees.

### 6. Ordenes multi-operario — issue padre + sub-issues

- La orden es un **issue padre**: contiene los artefactos de las estaciones
  tempranas (requerimientos destilados, links a mockups) y avanza por ellas.
- El rol `arquitecto` comenta su plan en el padre y lo parte en **sub-issues**
  (funcionalidad nativa de GitHub), uno por rol ejecutor, cada uno con su
  ciclo issue → rama → PR completo y su propio estado/assignee.
- El padre cierra cuando cierran todos los hijos. GitHub muestra el progreso
  en la tarjeta del padre.
- Regla de encadenamiento de PRs hijos: aplica la leccion del issue #28
  (retarget antes de mergear el padre).

## Alcance de implementacion (PRs separados, en orden)

1. `lanzar-rol.sh`: genera `run_id`, emite eventos JSONL, asigna assignee.
2. `vigilante-revisiones.sh`: lee/escribe labels de estado, reintenta con
   limite, marca `bloqueada`.
3. `CLAUDE.md`: documenta la convencion padre/sub-issues y los labels.
4. Repo bitacora (orden aparte): migracion de tabla de eventos + ingesta.

## Que NO cambia

- El circuito de revision, las identidades, branch protection: intactos.
- El tablero de Projects: opcional, es una vista humana; ningun script depende
  de el.
- `docs/vigilante.md` se actualiza en el PR que implemente los reintentos,
  no antes.
