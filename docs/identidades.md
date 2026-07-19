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
