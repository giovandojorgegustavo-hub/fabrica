# Reglas de la Fabrica

## Proceso
- Todo cambio nace en una rama, nunca directo en main.
- Mensajes de commit: formato convencional (tipo: descripcion).
- Antes de commitear: git status y git diff, siempre.

## Estructura
- src/ codigo, tests/ pruebas, migrations/ cambios de BD, docs/ decisiones.

## Pull Requests
- Todo merge a main pasa por Pull Request en GitHub.
- El PR muestra el diff completo: se lee ANTES de aprobar.

## Circuito de revision
- Todo PR de codigo recibe revision adversarial de los agentes qa y seguridad antes del merge.
- Hallazgos criticos o altos bloquean el merge hasta ser resueltos.
- Hallazgos medios y bajos se registran como issues en GitHub y no bloquean.
- La revision se corre por PR con gh; si los checks dan verde y no hay bloqueantes, el merge lo hace el mismo agente.

## Versiones
- Los tags de version siguen semver (vMAYOR.MENOR.PARCHE).
