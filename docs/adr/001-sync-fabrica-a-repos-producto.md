# ADR 001: Sincronizacion Fabrica -> repos producto

- **Estado**: aceptado (rev 2)
- **Fecha**: 2026-07-18
- **Rev 2 (2026-07-18)**: reemplazo el esquema de tags semver por pin a commit SHA. Reemplazo el "copiado por directorios con rm -rf" por una allowlist explicita de archivos que jamas borra ni sobreescribe archivos propios del repo producto. Cambio motivado por la revision de seguridad + qa del PR #12 sobre esta misma decision (altos a, d, e).
- **Contexto original del hallazgo**: PR #12 revision qa, hallazgo [alto] "Fabrica es el repo canonico de roles pero el PR no define el mecanismo de propagacion a los repos producto".

## Contexto

Este repo (fabrica) es la fuente de verdad de:
- `CLAUDE.md` (reglas de proceso).
- `.claude/agents/*.md` (7 roles genericos).
- `scripts/deploy.sh`, `scripts/lanzar-rol.sh`, `scripts/sincronizar-desde-fabrica.sh` (operaciones como codigo).
- `docs/identidades.md` (contrato de identidades y enforcement de GitHub).
- `docs/salud-endpoint.md` (contrato del endpoint de salud + guia de migracion).

Los repos producto (bitacora, y los que vengan) consumen esos artefactos para funcionar bajo las mismas reglas. Sin un mecanismo explicito, el proximo cambio de politica aca queda desalineado silenciosamente contra los repos producto.

## Opciones consideradas

1. **Submodule de git**. Contra: cada operador tiene que entender submodules, `git clone --recurse-submodules`, y el estado del submodule es HEAD flotante por default. Rompe el principio "el proceso vive en el repo" — el repo producto no es autosuficiente.
2. **Symlink al checkout local**. Contra: no viaja en `git clone`. Solo funciona en la maquina del operador. Descartada.
3. **Vendoring por tag semver** (rev 1, descartada en rev 2). Contra: un tag semver es un contrato humano (yo prometo que este cambio es MENOR o PARCHE) y los errores de clasificacion son comunes y silenciosos; ademas los tags son mutables (`git tag -f`) y el consumidor no se entera. Introducimos disciplina de release sin beneficio real cuando el consumidor de todos modos revisa el diff en su PR de sync.
4. **Vendoring por commit SHA con allowlist explicita** (elegida en rev 2).
5. **GitHub Action reactiva**: cuando fabrica cambia, una Action abre PR en cada repo producto. A favor: automatico. Contra: requiere lista central de repos consumidores y credenciales cross-repo. Buen paso 2 despues de que haya 3+ repos consumiendo.

## Decision

**Vendoring por commit SHA, con version pinned en cada repo producto, con allowlist explicita de archivos.**

Reglas:

1. Fabrica NO publica tags. La referencia canonica es el commit SHA en `main`.
2. Cada repo producto tiene en su raiz un archivo `FABRICA_VERSION` con una sola linea: el SHA completo (40 hex minusculas) del commit consumido.
3. La actualizacion se hace con `scripts/sincronizar-desde-fabrica.sh <sha>`, que:
   - Descarga el tarball del commit desde GitHub (`https://github.com/<owner>/fabrica/archive/<sha>.tar.gz`).
   - Copia UN A UNO los archivos declarados en la allowlist del propio script.
   - Actualiza `FABRICA_VERSION` al SHA nuevo.
4. La allowlist vive al principio del script como constante readonly. Cambiarla es un cambio de proceso que requiere PR + qa + seguridad + arquitecto.
5. **Que NUNCA toca el sync**:
   - `docs/adr/` — cada repo producto es dueno de sus propios ADRs.
   - `.claude/contexto-producto.md` — el contexto de usuario del producto lo pone el repo.
   - Cualquier archivo no listado en el allowlist.
6. **Que NUNCA hace el sync**:
   - `rm -rf` o cualquier borrado recursivo.
   - Copia de directorios completos (solo copia archivo por archivo).
   - Aceptar override del repo de origen via variable de entorno. El path de fabrica es hardcodeado en el script y auditable en el diff.
7. El resultado se abre como PR en el repo producto. Ese PR pasa por el mismo circuito (`qa` + `seguridad`, y `arquitecto` si toca contratos), porque cambia el proceso.
8. Los archivos vendored quedan committeados en el repo producto: el repo es autosuficiente, sin dependencia de red para lanzar sesion o desplegar.

## Por que SHA y no semver

- Un tag semver es un contrato humano; los errores de clasificacion (marcar como PARCHE algo que rompe consumidores) son comunes y silenciosos. Un SHA es factual: apunta a un commit especifico revisable en el diff.
- El SHA no puede ser reescrito. Un tag puede moverse (`git tag -f`) y el consumidor no se entera; el SHA cambia si el contenido cambia.
- El SHA no requiere disciplina de release: fabrica cambia → el repo producto elige cuando pinnar al SHA nuevo y abre PR. No hay "publicar version" separado del merge.
- El diff del PR de sync en el repo producto muestra exactamente que cambio del SHA anterior al nuevo. La revision es sobre el diff real, no sobre un numero de version.

## Por que allowlist explicita, no copia por directorios

La version anterior (rev 1) copiaba directorios enteros (`.claude/agents/`, `docs/adr/`), lo cual implica dos problemas:

1. **Riesgo de borrado**: para "reemplazar" un directorio hay que borrar el destino primero. Un `rm -rf` en un script de sync es una amenaza permanente: un bug o un tarball malformado puede borrar archivos legitimos del repo producto.
2. **Riesgo de invasion de propiedad**: `docs/adr/` en fabrica y `docs/adr/` en un repo producto NO son el mismo directorio conceptualmente. Fabrica no debe pisar los ADRs del producto. La copia por directorio no distingue.

Con allowlist explicita:
- Fabrica declara exactamente que archivos propaga.
- Ninguna copia jamas borra archivos del repo producto.
- Agregar/quitar archivos propagables es un cambio visible en el diff del script, revisable con lente de arquitectura.

## Consecuencias

- Cada repo producto declara explicitamente que commit de fabrica corre. El drift es visible en el diff del PR de actualizacion.
- Un cambio en fabrica no impacta a los repos producto hasta que ellos hagan el sync. Es un feature, no un bug: la actualizacion se acepta con revision, no se pisa silenciosamente.
- Un rol nuevo (o el rename de uno existente) requiere: (a) cambio en fabrica → (b) actualizar allowlist del sync si es un archivo nuevo → (c) PR de sync en cada repo producto con el nuevo SHA → (d) merge tras revision.
- Los repos producto conservan la propiedad total de `docs/adr/`, `.claude/contexto-producto.md` y todo lo que no este en el allowlist.
- El archivo legacy `.fabrica-version` (rev 1) se reemplaza por `FABRICA_VERSION` (rev 2). Los repos producto que aun tengan `.fabrica-version` lo migran en el PR de adopcion de rev 2.

## Notas

- El paso "GitHub Action reactiva" queda como evolucion cuando haya 3+ repos consumiendo. No se implementa hoy.
- Hasta que exista el segundo repo consumiendo, el "sync" es manual y bitacora es el unico target. El script se estrena ahi.
