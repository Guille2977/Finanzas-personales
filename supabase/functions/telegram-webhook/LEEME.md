# telegram-webhook · Bot de Telegram (Edge Function de Supabase)

| Archivo | Qué hace |
|---|---|
| index.ts | Recibe el webhook, valida el secreto, responde 200 al instante y procesa: registrar, botones, comandos, IA |
| logica.ts | Reglas puras: interpretar "pasaje 3", validar la respuesta de la IA, fechas en Lima |
| logica_test.ts | 45 pruebas de logica.ts (`deno run logica_test.ts`) |

## Despliegue (panel de Supabase)
1. SQL Editor → `sql/08_bot_edge.sql`, `sql/09_fn_clasificar.sql` y `sql/10_frases_sentido.sql`.
2. Edge Functions → `telegram-webhook` → Code: reemplaza `index.ts` y agrega `logica.ts` (Add File). Deploy.
3. "Verify JWT" desactivado (Telegram no envía JWT; la seguridad es el secreto en la cabecera).
4. Edge Functions → Secrets: `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`, `TELEGRAM_SECRETO`, `GEMINI_KEY`
   (opcional `GEMINI_MODELO`). `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` ya existen.
5. Webhook de Telegram → `https://<proyecto>.supabase.co/functions/v1/telegram-webhook` con `secret_token`.

## Monitoreo
Cada mensaje deja una fila en `ejecuciones` (proceso `bot`) con "atendido en X ms" en `detalle`.
Logs de la función: Edge Functions → telegram-webhook → Logs.

## Clasificación
La categoría la decide `public.fn_clasificar` (sql/09), la misma función que usan los correos.
El bot la llama con `db.rpc("fn_clasificar", { p_texto, p_sentido })`. Si falla, el gasto se
registra "Sin categoría" y el bot pregunta con botones; el error queda en los Logs.

## Ingreso o gasto
Lo decide la tabla `frases_sentido` (sql/10): frase completa, gana la más larga, sin frase → gasto.
"me han yapeado 5" → ingreso; "se me cayó 10" → gasto (le gana a "me cayó").
Para enseñarle una frase nueva: `INSERT INTO frases_sentido (frase, sentido) VALUES (fn_normalizar('...'), 'ingreso')`.
No hace falta redesplegar: el bot recarga las frases cada 60 s. Si la tabla falla, usa la lista corta `BOT.INGRESO`.
