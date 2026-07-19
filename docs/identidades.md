# Identidades por rol

Cada rol revisor de la Fabrica (`qa`, `seguridad`, `arquitecto`, `producto`) opera como una identidad distinta del implementador. Este documento describe el layout esperado de tokens, las cuentas maquina de GitHub, los permisos minimos del PAT y como se configura branch protection para exigir aprobacion no-autor.

Este repo **no crea** los tokens ni las cuentas. Los crea el operador con permisos de root y de administrador del repo en GitHub, fuera del arbol de git. Este documento es el contrato: describe que debe existir para que `scripts/lanzar-rol.sh` funcione.

## Layout de tokens

Los tokens viven fuera del repo, con permisos estrictos:

```
/etc/fabrica/tokens/qa.token
/etc/fabrica/tokens/seguridad.token
/etc/fabrica/tokens/arquitecto.token
/etc/fabrica/tokens/producto.token
```

- Dueno y grupo: `root:root`.
- Permisos: `600` (solo root lee).
- Contenido: un unico PAT de GitHub por rol, sin saltos de linea al final.
- Nadie mas que root puede leer estos archivos. `scripts/lanzar-rol.sh` los lee via `sudo` cuando corresponda, o se ejecuta como un servicio que ya tiene permiso de lectura.

## Cuentas maquina de GitHub

Cada rol revisor tiene una cuenta maquina propia en GitHub, distinta de la cuenta del implementador:

- `fabrica-qa`
- `fabrica-seguridad`
- `fabrica-arquitecto`
- `fabrica-producto`

El PAT que vive en `/etc/fabrica/tokens/<rol>.token` pertenece a la cuenta maquina correspondiente. **Nunca** a la cuenta del implementador.

## Permisos minimos del PAT

Cada PAT tiene EL MINIMO necesario para revisar:

- `repo:read` — leer contenido, commits y diffs.
- `pull_request:read` — leer PRs, comentarios, reviews.
- `pull_request:write` — solo para dejar comentario firmado y aprobar/pedir cambios.

Y nada mas. Sin `repo:write` (no debe poder pushear codigo). Sin `workflow`. Sin `admin`. Sin `packages`. Sin `delete`.

Si un PAT tiene mas de lo listado, es un hallazgo bloqueante y `seguridad` debe reportarlo.

## Branch protection para exigir aprobacion no-autor

En cada repo producto, `main` esta protegida con la siguiente configuracion:

- Require pull request reviews before merging: **si**.
- Require approval from someone other than the last pusher: **si**. (Esto impide que el implementador aprueba su propio PR.)
- Dismiss stale pull request approvals when new commits are pushed: **si**.
- Require review from Code Owners: **si**. Los `CODEOWNERS` listan las cuentas maquina como duenas de los paths relevantes (por ejemplo, `docs/adr/` es dueno de `fabrica-arquitecto`).
- Restrict who can dismiss pull request reviews: solo administradores.
- Require status checks to pass before merging: **si**.
- Do not allow bypassing the above settings: **si**.

Esto cierra la puerta a que el implementador se autoaprueba: GitHub exige que la aprobacion venga de otra cuenta, y las cuentas revisoras son las de rol.

## Verificacion tecnica de la firma (author.login)

La firma textual (`**Rol**: qa`, `**Rol**: seguridad`, etc.) es solo formato de lectura. **No prueba nada por si sola**: cualquiera con `pull_request:write` puede escribir esos strings.

La prueba real es que el `author.login` del comentario en la API de GitHub sea la cuenta maquina esperada:

| Rol declarado en el body | `author.login` esperado |
|--------------------------|-------------------------|
| `qa`                     | `fabrica-qa`            |
| `seguridad`              | `fabrica-seguridad`     |
| `arquitecto`             | `fabrica-arquitecto`    |
| `producto`               | `fabrica-producto`      |

## Enforcement de identidad: nativo de GitHub, no de scripts

El enforcement de que "solo la cuenta maquina de un rol puede aprobar/comentar como ese rol" NO se hace con scripts locales. Se hace con la configuracion nativa de GitHub. La combinacion de cuatro mecanismos ya activos deja la puerta cerrada:

1. **Branch protection + "Require approval from someone other than the last pusher"**: GitHub bloquea el merge si la unica aprobacion viene de quien pusheo el ultimo commit. El implementador **no puede aprobar su propio PR**, sin importar que comente en el body.

2. **Branch protection + "Require review from Code Owners"**: los `CODEOWNERS` del repo listan las cuentas maquina como duenas de los paths criticos. Un PR que toque esos paths exige aprobacion (no solo comentario) de la cuenta maquina correspondiente.

3. **PATs restringidos por cuenta**: el PAT con `pull_request:write` vive solo en las cuentas maquina de rol. El PAT del implementador NO tiene esas cuentas ni puede simularlas. Un comentario o aprobacion "firmado" como `qa` que venga de otra cuenta queda visible en `author.login` en la UI de GitHub y en la API — no puede falsificarse desde otro token.

4. **Branch protection + "Do not allow bypassing"**: nadie (incluido admin) puede saltear las reglas anteriores sin dejar rastro. Ninguna cuenta maquina de rol figura en la "Bypass list": los revisores aprueban, **no bypasean**. Esto se audita en la revision de `seguridad` de cualquier PR que toque configuracion del repo.

Con esos cuatro mecanismos activos, la firma textual (`**Rol**: qa`) queda como convencion para lectura humana; la garantia real de identidad la da GitHub, no un script. Quien mergea confirma visualmente que cada comentario firmado necesario aparece con `author` = cuenta maquina esperada — no necesita ejecutar nada.

### Por que este repo NO trae un script de verificacion

Una version previa de este circuito proponia un `scripts/verificar-firmas.sh` que consultara la API de GitHub y comparara `author.login` contra la cuenta esperada antes del merge. Se descarto por dos razones:

1. **Duplicaria lo que GitHub ya hace nativamente**. Los cuatro mecanismos de arriba ya impiden que una identidad falsa apruebe. Un script cliente que ademas grepea comentarios agrega superficie sin cerrar nada nuevo.
2. **El enforcement en cliente es esquivable por diseno**. Cualquier chequeo local se salta con no correrlo. El enforcement de politica tiene que vivir donde no se pueda esquivar — el servidor de GitHub, via branch protection + CODEOWNERS. Cualquier "gate" que dependa de que el operador humano se acuerde de correr un script es honor system, no enforcement.

Si en el futuro se necesita un chequeo automatizado adicional (por ejemplo, "el PR debe tener un comentario firmado de `fabrica-qa` antes de habilitar el merge"), va como **GitHub Action** en el mismo repo, no como script local. Una Action corre siempre y se ve en los required status checks — no se puede omitir.

## Endpoint de salud

El contrato del endpoint `/salud` que cierra la Definition of Done ("desplegado y verificado") vive en [`docs/salud-endpoint.md`](salud-endpoint.md). Ese documento incluye:

- El JSON minimo que debe devolver (`status` + `commit`).
- Las cinco condiciones que `scripts/deploy.sh` valida antes de aceptar el deploy.
- **Guia de migracion para servicios existentes** que ya tienen `/salud` pero aun no reportan el campo `commit` (tres pasos: capturar el SHA en build/arranque, exponerlo en el JSON, verificar con `deploy.sh`).

Este archivo (`identidades.md`) declara el contrato de identidades y credenciales; `salud-endpoint.md` declara el contrato del endpoint de salud. Ambos son parte del contrato general que fabrica exige a cada repo producto.

## Que hace `scripts/lanzar-rol.sh`

1. Verifica que exista `.claude/agents/<rol>.md` en el repo actual.
2. Verifica que exista y sea legible `/etc/fabrica/tokens/<rol>.token`.
3. Inyecta el token via variable de entorno `GITHUB_TOKEN` (no lo escribe a disco).
4. Lanza `claude -p` con el prompt del rol concatenado al prompt/archivo del usuario.

Si el token o el archivo de rol no existen, el script **falla claro** y no lanza sesion. No hay "fallback" silencioso.

## Que NO hace este script (y por que)

- No crea tokens (eso es del operador con root).
- No configura branch protection (eso es del administrador del repo en GitHub).
- No auditariza los PATs (eso es del rol `seguridad` en cada PR).
- No hace merge (eso lo hace un rol distinto del implementador, con las revisiones firmadas ya en el PR).
