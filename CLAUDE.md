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
- Si los checks estan verdes, todas las revisiones necesarias dejaron comentario firmado, y no hay bloqueantes: el merge lo hace un rol distinto del implementador.

## Definition of Done
Una feature esta terminada cuando:
1. El PR esta mergeado en main.
2. El codigo esta **desplegado** en el ambiente vivo (proceso corriendo el commit nuevo).
3. Esta **verificada ahi**: smoke test contra el endpoint de salud + verificacion de que el proceso vivo corre el commit nuevo (comparacion de timestamps o hash).

Mergeado NO es desplegado. Desplegado NO es verificado. El paso obligatorio es `scripts/deploy.sh`.

## E2E por UI real
Los tests de interfaz DEBEN ejercitar la UI real (Playwright contra la app viva), nunca solo seeds de base. Un flujo que solo pasa con seeds no cuenta como cubierto.

## Operaciones como codigo
- `scripts/deploy.sh` es el paso obligatorio del DoD. Cada repo producto lo parametriza via `scripts/deploy.env`: git pull --ff-only, migraciones si corresponde, restart del servicio declarado, smoke test contra endpoint de salud, y verificacion de que el proceso vivo corre el commit nuevo (comparacion de timestamps).
- `scripts/lanzar-rol.sh` es el mini-lanzador de identidades: recibe rol y prompt/archivo, lanza una sesion claude con el rol y el token correspondiente. Ver `docs/identidades.md` para el layout de tokens y la configuracion de branch protection.

## Versiones
- Los tags de version siguen semver (vMAYOR.MENOR.PARCHE).
