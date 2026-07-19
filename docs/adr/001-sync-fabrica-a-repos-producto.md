# ADR 001: Sincronizacion Fabrica -> repos producto

- **Estado**: aceptado
- **Fecha**: 2026-07-18
- **Contexto del hallazgo**: PR #12 revision qa, hallazgo [alto] "Fabrica es el repo canonico de roles pero el PR no define el mecanismo de propagacion a los repos producto".

## Contexto

Este repo (fabrica) es la fuente de verdad de:
- `CLAUDE.md` (reglas de proceso).
- `.claude/agents/*.md` (7 roles genericos).
- `scripts/deploy.sh` y `scripts/lanzar-rol.sh` (operaciones como codigo).
- `docs/identidades.md` y este directorio `docs/adr/`.

Los repos producto (bitacora, y los que vengan) consumen esos artefactos para funcionar bajo las mismas reglas. Sin un mecanismo explicito, el proximo cambio de politica aca queda desalineado silenciosamente contra los repos producto.

## Opciones consideradas

1. **Submodule de git**. Contra: cada operador tiene que entender submodules, `git clone --recurse-submodules`, y el estado del submodule es HEAD flotante por default. Rompe el principio "el proceso vive en el repo" — el repo producto no es autosuficiente.
2. **Symlink al checkout local**. Contra: no viaja en `git clone`. Solo funciona en la maquina del operador. Descartada.
3. **Vendoring por tag semver** (elegida).
4. **GitHub Action reactiva**: cuando fabrica publica un tag, una Action abre PR en cada repo producto actualizando `.claude/agents/`. A favor: automatico. Contra: requiere lista central de repos consumidores y credenciales cross-repo. Buen paso 2 despues de que haya mas de un repo consumiendo.

## Decision

**Vendoring por tag semver, con version pinned en cada repo producto.**

Reglas:

1. Fabrica publica versiones etiquetadas semver (`vMAYOR.MENOR.PARCHE`) cuando se hace un cambio que los repos producto tienen que adoptar.
2. Cada repo producto tiene en su raiz un archivo `.fabrica-version` con una sola linea: el tag consumido (por ejemplo `v0.2.0`).
3. La actualizacion se hace con `scripts/sincronizar-desde-fabrica.sh <tag>`, que:
   - Descarga el tarball del tag desde GitHub.
   - Reemplaza en el repo producto: `CLAUDE.md`, `.claude/agents/*.md`, `scripts/deploy.sh`, `scripts/lanzar-rol.sh`, `docs/identidades.md`, `docs/adr/*.md` referenciados.
   - Actualiza `.fabrica-version` al tag nuevo.
4. El resultado se abre como PR en el repo producto. Ese PR pasa por el mismo circuito (`qa` + `seguridad`, y `arquitecto` si toca contratos), porque cambia el proceso.
5. Los archivos vendored quedan committeados en el repo producto: el repo es autosuficiente, sin dependencia de red para lanzar sesion o desplegar.

## Consecuencias

- Cada repo producto declara explicitamente que version de la fabrica corre. El drift es visible en el diff del PR de actualizacion.
- Un cambio en fabrica no impacta a los repos producto hasta que ellos hagan el sync. Es un feature, no un bug: la actualizacion se acepta con revision, no se pisa silenciosamente.
- La fabrica publica el script canonico `scripts/sincronizar-desde-fabrica.sh` — cada repo producto lo copia una vez y lo mantiene actualizado como cualquier otro archivo vendored.
- Un rol nuevo (o el rename de uno existente) requiere: tag en fabrica -> PR de sync en cada repo producto -> merge tras revision. No hay shortcut.

## Notas

- El paso 4 (GitHub Action reactiva) queda como evolucion cuando haya 3+ repos consumiendo. No se implementa hoy.
- Hasta que exista el segundo repo consumiendo, el "sync" es manual y bitacora es el unico target. El script se estrena ahi.
