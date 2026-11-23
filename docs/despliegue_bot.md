# Desplegar el bot con Supabase CLI

Hasta ahora el bot se desplegaba copiando `index.ts` y `logica.ts` en el editor web de Supabase. Funciona, pero tiene tres problemas: lo desplegado puede no coincidir con lo que está en GitHub, nada impide desplegar con una prueba rota, y un descuido en el panel (activar "Verify JWT") tumba el bot. Con la CLI, **lo que está en el repo es lo que corre**, y un solo comando hace pruebas, despliegue y verificación.

| Archivo | Para qué |
|---|---|
| `supabase/config.toml` | `verify_jwt = false` para `telegram-webhook`, versionado (no depende de un clic en el panel) |
| `supabase/secretos.env.ejemplo` | Lista de secretos del bot, **sin valores** |
| `scripts/desplegar_bot.sh` | Pruebas → despliegue → verificación. Si una prueba falla, no despliega |
| `.github/workflows/bot.yml` | Pruebas en cada push; despliegue solo a mano desde Actions (opcional) |

## Antes de empezar (una sola vez)

**Confirma que el repo tiene la versión que corre hoy.** Desplegar reemplaza el código de la función por el del repo. Si alguna vez editaste en el panel sin copiar al repo, compara primero: Edge Functions → telegram-webhook → Code, contra `supabase/functions/telegram-webhook/`.

**Los secretos del bot ya están en Supabase y no hay que tocarlos.** Desplegar código no borra secretos. En especial, no cambies `TELEGRAM_SECRETO`: tiene que ser igual al `secret_token` con el que registraste el webhook.

## Paso 1 · Dos credenciales como secretos de Codespaces

1. Supabase → **Account → Access Tokens → Generate token**. Nombre: `codespaces-finanzas`, vence en 30 días, acceso solo a **este proyecto** y un único permiso: **Edge Functions → Read & write** (todo lo demás en *None*, incluido *Edge Function Secrets*). Cópialo (empieza con `sbp_`).
   - **Por qué tan poco:** si el token se filtra, solo sirve para desplegar funciones de este proyecto; no puede leer tus secretos, la base ni otros proyectos. Si un día un comando pide más, se agrega ese permiso y nada más.
2. Tu *project ref* es la parte de la URL: `https://<ref>.supabase.co`.
3. GitHub → avatar → **Settings → Codespaces → Secrets → New secret**:
   - `SUPABASE_ACCESS_TOKEN` = el token.
   - `SUPABASE_PROJECT_REF` = el ref.
   - En "Repository access" elige solo `Finanzas-personales`.
4. Si el Codespace ya estaba abierto, recárgalo (aparece un aviso para hacerlo) para que vea los secretos.

**Por qué así:** la CLI lee `SUPABASE_ACCESS_TOKEN` sola, sin `supabase login` ni archivos con el token en disco. El token queda cifrado en GitHub y solo se inyecta en *tus* Codespaces de *este* repo. Si se filtra, lo revocas en Supabase sin tocar nada más.

## Paso 2 · Probar sin desplegar

En la terminal del Codespace, desde la raíz del repo:

```bash
bash scripts/desplegar_bot.sh --pruebas
```

Debe terminar con `45/45 pruebas OK`. Usa Deno si existe, si no Node ≥ 22.6, y si no `tsx`.

## Paso 3 · Desplegar

```bash
bash scripts/desplegar_bot.sh
```

Lo que pasa:
1. **Pruebas.** Si una falla, se detiene y no toca Supabase.
2. **Despliegue** con `npx supabase@3 functions deploy telegram-webhook --remote=<ref> --no-verify-jwt --use-api`. La CLI te pide confirmar porque cambia producción: elige **Yes** con la flecha ← y Enter (viene marcado "No" para que un Enter accidental no toque producción).
   - `--no-verify-jwt`: Telegram no envía JWT; la seguridad es la cabecera secreta. Está también en `config.toml` (doble seguro).
   - `--use-api`: Supabase empaqueta el código en su servidor, así no hace falta Docker.
3. **Verificación** contra la función ya desplegada:
   - `GET` → `200 ok`: el código arrancó y "Verify JWT" está apagado. Si estuviera encendido, el gateway respondería 401 antes de llegar al código.
   - `POST` sin secreto → `401 no autorizado`: la protección sigue funcionando. Ese texto lo escribe *nuestro* código, así se distingue de un 401 del gateway.

Prueba final: escribe `/hoy` al bot. Responde sin registrar nada.

Opcional: si exportas `TELEGRAM_TOKEN` en la terminal antes de verificar, el script también consulta `getWebhookInfo` (pendientes y último error) sin imprimir el token:

```bash
read -rs TELEGRAM_TOKEN && export TELEGRAM_TOKEN   # pega el token; no se ve ni queda en el historial
bash scripts/desplegar_bot.sh --verificar
```

## Si algo sale mal

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `Falta SUPABASE_ACCESS_TOKEN` | El Codespace no recargó los secretos | Recargar el Codespace (paso 1.4) |
| `Unauthorized` / `401` al desplegar | Token revocado o mal copiado | Generar otro y actualizar el secreto |
| GET → `401` | Verify JWT quedó activado | Panel → Edge Functions → telegram-webhook → Details → apagar "Verify JWT", o volver a correr el script |
| GET → `500` / `503` | La función no arranca (error de código o de import) | Panel → Edge Functions → telegram-webhook → Logs |
| El bot no responde pero la verificación pasa | Webhook o secreto distintos | `getWebhookInfo` (arriba): mirar `último error` |

**Volver atrás:** el código anterior está en git. `git checkout <commit-anterior> -- supabase/functions/telegram-webhook` y vuelve a desplegar; luego `git checkout main -- supabase/functions/telegram-webhook` para regresar.

## Secretos del bot (solo si montas el proyecto desde cero)

```bash
cp supabase/secretos.env.ejemplo supabase/.env   # supabase/.env está en .gitignore
# completar los valores en supabase/.env
npx supabase@3 secrets set --env-file supabase/.env --remote=$SUPABASE_PROJECT_REF
rm supabase/.env
```

## Opcional · Desplegar desde GitHub Actions

`.github/workflows/bot.yml` ya corre las pruebas en cada push que toque `supabase/`. Para desplegar desde GitHub:

1. Repo → **Settings → Secrets and variables → Actions → New repository secret**: `SUPABASE_ACCESS_TOKEN` y `SUPABASE_PROJECT_REF` (son secretos distintos de los de Codespaces).
2. **Actions → Bot de Telegram → Run workflow** (rama `main`).

**Por qué el despliegue es manual:** un push con un error no debe poder tumbar el bot. Las pruebas son automáticas; poner en producción es una decisión. Además: permisos mínimos (`contents: read`), los secretos del bot nunca pasan por GitHub, y `concurrency` evita dos despliegues a la vez.

## Para la entrevista

- **Infraestructura reproducible:** el despliegue es un comando versionado, no una secuencia de clics que hay que recordar.
- **Configuración en lugar de código, y versionada:** `verify_jwt = false` vive en `config.toml`, con el motivo escrito al lado.
- **Pruebas como barrera:** nada llega a producción si falla una de las 45 pruebas.
- **Verificar, no suponer:** después de desplegar, el script comprueba dos cosas: que el bot está vivo y que sigue protegido.
- **Secretos fuera del código y con el mínimo alcance:** token de Supabase en secretos de Codespaces/Actions (limitado a este repo); secretos del bot solo en Supabase.
