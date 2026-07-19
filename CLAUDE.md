# Reglas de la Fabrica

## Proceso
- Todo cambio nace en una rama, nunca directo en main.
- Mensajes de commit: formato convencional (tipo: descripcion).
- Antes de commitear: git status y git diff, siempre.

## Estructura
- src/ codigo, tests/ pruebas, migrations/ cambios de BD, docs/ decisiones.
- docs/adr/ para ADRs de arquitectura. docs/ux/ para especificaciones de flujo. docs/producto/ para criterios de aceptacion.

## Contexto de producto
- Cada repo producto DEBE tener `.claude/contexto-producto.md` con: quien es el usuario, en que dispositivo, en que condiciones, que valora, y que restricciones tiene.
- Todo rol lee ese archivo ANTES de actuar. Si no existe, el rol PARA y reporta hallazgo bloqueante.
- Los roles de la Fabrica son genericos: no contienen contexto de producto. El contexto lo pone el repo.

## Roles
- Los archivos de rol viven en `.claude/agents/`: backend, frontend, ux, qa, seguridad, arquitecto, producto.
- Un rol solo actua si esta invocado explicitamente. No hay revision "implicita".
- **Prohibicion dura: quien implementa un PR NO puede ejecutar ni redactar sus propias revisiones qa o seguridad.** Cada revision es una sesion separada del implementador.
- Cada revision (qa, seguridad, arquitecto, producto) deja **comentario firmado** en el PR con: nombre del rol, timestamp, hash del commit revisado, y veredicto. **Sin comentario en el PR, la revision no existio.**

## Pull Requests
- Todo merge a main pasa por Pull Request en GitHub.
- El PR muestra el diff completo: se lee ANTES de aprobar.

## Circuito de revision (cableado por evento)
- **Todo PR de codigo**: recibe revision de `qa` Y `seguridad`, como sesiones separadas del implementador, con comentario firmado en el PR.
- **Cambio de UI**: exige spec de `ux` ANTES del codigo, y aceptacion de `producto` DESPUES del codigo (reproducida desde la pantalla del usuario, sobre datos reales, no seeds).
- **Cambio estructural** (esquema, contratos entre modulos, dependencias nuevas, acoplamiento): exige revision de `arquitecto`.
- Hallazgos criticos o altos bloquean el merge hasta ser resueltos.
- Hallazgos medios y bajos se registran como issues en GitHub y no bloquean.
- Antes de mergear, quien mergea corre `scripts/verificar-firmas.sh <PR>` (mas `--con-arquitecto` / `--con-producto` si corresponde). El script valida que cada revision firmada venga de la cuenta maquina `fabrica-<rol>` real, no solo que el body diga `**Rol**: <rol>`. Sin `verificar-firmas.sh` en verde, el merge no se hace.
- Si los checks estan verdes, `verificar-firmas.sh` pasa, todas las revisiones necesarias dejaron comentario firmado, y no hay bloqueantes: el merge lo hace un rol distinto del implementador.

## Definition of Done
Una feature esta terminada cuando:
1. El PR esta mergeado en main.
2. El codigo esta **desplegado** en el ambiente vivo (proceso corriendo el commit nuevo).
3. Esta **verificada ahi**: smoke test contra el endpoint de salud + verificacion de que el proceso vivo corre el commit desplegado.

Mergeado NO es desplegado. Desplegado NO es verificado. El paso obligatorio es `scripts/deploy.sh`.

### Contrato del endpoint de salud
Cada repo producto expone `/salud` (o el path que declare `HEALTH_URL`) devolviendo HTTP 200 y JSON con al menos:

```json
{ "status": "ok", "commit": "<sha completo del commit que corre el proceso vivo>" }
```

- `status`: solo `"ok"` cuenta como sano. Cualquier otro valor (`"degraded"`, `"starting"`, etc.) es app viva pero no lista, y `scripts/deploy.sh` rechaza el deploy.
- `commit`: sha completo del commit que el proceso esta ejecutando, resuelto en tiempo de arranque (ej: variable de build o `git rev-parse HEAD` embebido). Sin este campo, `deploy.sh` no puede confirmar que el proceso vivo corre lo que se acaba de desplegar y falla.

Este contrato es lo que separa "systemd reinicio algo" de "el commit desplegado esta vivo".

## E2E por UI real
Los tests de interfaz DEBEN ejercitar la UI real (Playwright contra la app viva), nunca solo seeds de base. Un flujo que solo pasa con seeds no cuenta como cubierto.

## Operaciones como codigo
- `scripts/deploy.sh` es el paso obligatorio del DoD. Cada repo producto lo parametriza via `scripts/deploy.env`: git pull --ff-only, migraciones si corresponde, restart del servicio declarado, smoke test que exige `status=ok` en el body de `/salud`, y confirmacion final de que el commit reportado por `/salud` coincide con el commit desplegado.
- `scripts/lanzar-rol.sh` es el mini-lanzador de identidades: recibe rol y prompt/archivo, lanza una sesion claude con el rol y el token correspondiente. Ver `docs/identidades.md` para el layout de tokens y la configuracion de branch protection.
- `scripts/sincronizar-desde-fabrica.sh` es el mecanismo canonico de propagacion. Fabrica publica tags semver; cada repo producto declara la version que consume en `.fabrica-version` y actualiza corriendo este script contra el tag nuevo, abriendo un PR con el diff. Detalle y racional en `docs/adr/001-sync-fabrica-a-repos-producto.md`.

## Versiones
- Los tags de version siguen semver (vMAYOR.MENOR.PARCHE).
