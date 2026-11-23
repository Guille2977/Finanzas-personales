# Apps Script · Finanzas automatizadas

Proyecto NUEVO (independiente). El antiguo "Registro de movimientos" sigue igual hasta que este funcione.

## Archivos (un módulo por tarea)
| Archivo | Qué hace |
|---|---|
| Config.gs | Constantes y lectura de claves (Propiedades del script) |
| BaseDatos.gs | Única capa que habla con Supabase (REST, reintentos) |
| Lectura.gs | Lee Gmail (solo lectura) |
| Fuentes.gs | Identifica la fuente con la tabla `fuentes` |
| Extractores.gs | Extrae monto, moneda, operación… (tus regex) |
| Categorias.gs | Clasifica llamando a `fn_clasificar` en Supabase (misma regla que el bot); si falla, categoría de la fuente o sin categoría |
| Monitoreo.gs | Registra cada corrida en `ejecuciones` |
| Alertas.gs | Cada 15 min: concilia recibos con cargos del banco y genera el resumen mensual (`sql/13`), y envía por Telegram los avisos que decide la base (`sql/11`): presupuesto 80 %/100 %, errores de captura, captura detenida y resumen del mes |
| Main.gs | Funciones a ejecutar + pipeline de captura |
| Migracion.gs | Migra la hoja de cálculo anterior a Supabase (una sola vez) |
| IA.gs | Gemini propone los campos de un correo que las reglas no entienden; va a "Por revisar" con la etiqueta *sugerido por IA* |
| Pruebas.gs | Pruebas de la lógica (sin Gmail ni Supabase) |
| PruebasIA.gs | Pruebas de IA.gs con Gemini simulado (sin red) |
| PruebasResumen.gs | Pruebas de las tareas previas de Alertas.gs (conciliación y resumen; base simulada) |

## Instalación (en orden)
1. script.google.com → **Nuevo proyecto** → nómbralo "Finanzas automatizadas".
2. ⚙️ Configuración del proyecto → marca **Mostrar el archivo de manifiesto "appsscript.json"** → pega `appsscript.json`.
3. Crea cada archivo `.gs` (botón **+ → Secuencia de comandos**, sin escribir ".gs") y pega su contenido. Borra `Código.gs` vacío.
4. ⚙️ → **Propiedades del script** → agrega:
   - `SUPABASE_URL` = Project URL (Supabase → Project Settings → API / Data API)
   - `SUPABASE_KEY` = clave **service_role** (o *secret*), nunca la anon
   - `HOJA_ID` = el ID de la URL de la hoja "Movimientos bancarios"
5. Ejecuta en este orden (selector de función → ▶ Ejecutar), revisando el registro:
   1. `probarTodo` → 51/51 pruebas OK.
   2. `probarConexion` → "✅ Conexión OK". (La primera vez pide permisos.)
   3. `migrarHoja` → muestra insertados / ya_existian / errores.
   4. `capturarCorreos` → captura los últimos 10 días.
   5. `crearActivador` → captura automática cada 15 min.
6. Verifica en Supabase (SQL Editor):
   ```sql
   SELECT estado, COUNT(*) FROM correos_raw GROUP BY estado;
   SELECT * FROM ejecuciones ORDER BY id DESC LIMIT 5;
   SELECT * FROM v_gasto_mensual ORDER BY mes;
   ```
7. Cuando confirmes que todo cuadra, en el proyecto antiguo borra su activador diario (⏰ Activadores).

Volver a ejecutar cualquier paso no duplica datos.

## Reconstruir todo desde los correos (Reconstruccion.gs)
1. Vuelve a pegar **Main.gs** (cambió) y crea **Reconstruccion.gs**.
2. (Opcional) Propiedad `RECONSTRUIR_DIAS` = días hacia atrás (por defecto 90).
3. Ejecuta `reconstruirPrueba` → no escribe nada; lee el reporte (insertaría, reemplazaría, anularía, huérfanos).
4. Si cuadra, ejecuta `reconstruirAplicar`. Si se acaba el tiempo, sigue sola cada minuto hasta terminar (mira Ejecuciones).
5. Para detenerla: `cancelarReconstruccion`.

## Clasificación en SQL (17/11)
La regla (fuente → diccionario → sin categoría) ya no está en Apps Script: vive en
`sql/09_fn_clasificar.sql` y la comparten correos y bot. Ejecuta ese SQL **antes** de pegar
`Categorias.gs`, `BaseDatos.gs`, `Main.gs`, `Migracion.gs`, `Reconstruccion.gs` y `Pruebas.gs`.
Si lo pegas antes, nada se rompe: los correos se guardan "Sin categoría" (o con la de la fuente)
y en el registro aparece `fn_clasificar falló; se usa el respaldo`.

## Bot de Telegram → ya no está aquí
El bot vive en **`supabase/functions/telegram-webhook`** (Edge Function de Supabase): responde en < 1 s.
La versión en Apps Script quedó en `archivo_bot_apps_script/` con el porqué del cambio.
Apps Script se encarga solo de la **captura de correos** (activador cada 15 min).
Apps Script se encarga también de **enviar las alertas** (ver abajo); el token del bot se guarda en ambos lados.

## Alertas por Telegram (Alertas.gs, 20/11)
Qué avisar lo decide la base (`sql/11_alertas.sql` → `fn_generar_alertas`); Apps Script solo envía y marca.
1. Supabase → SQL Editor → ejecuta `sql/11_alertas.sql` (al final debe decir *Alertas: 12/12 pruebas OK*).
2. ⚙️ → Propiedades del script → agrega `TELEGRAM_TOKEN` y `TELEGRAM_CHAT_ID` (los mismos de la Edge Function).
3. Crea **Alertas.gs**; en **Config.gs** agrega `MINUTOS_ALERTAS: 15` y `MAX_ALERTAS_POR_CORRIDA: 20` dentro de `CONFIG`; reemplaza **Pruebas.gs**.
4. Ejecuta: `probarTodo` (28/28) → `probarAlertaTelegram` (te llega un mensaje) → `revisarAlertas` → `crearActivadorAlertas`.
5. Historial y pendientes: `SELECT * FROM alertas ORDER BY id DESC;`. Umbrales y tiempos: tablas `umbrales_presupuesto` y `parametros` (sin tocar código).

## IA para correos desconocidos (IA.gs, 21/11)
Si las reglas no entienden un correo (sin monto válido, o fuente desconocida con tipo "Otro"/sin contraparte),
Gemini propone monto, moneda, sentido, contraparte y categoría. El correo queda en **Por revisar** con
`sugerido_por_ia = true` y tú confirmas en Retool. **Nunca se registra solo.** No requiere SQL nuevo.
1. ⚙️ → Propiedades del script → agrega `GEMINI_KEY` (la misma de la Edge Function). Opcional: `GEMINI_MODELO`.
   Sin la clave todo funciona como antes.
2. Crea **IA.gs** y **PruebasIA.gs**; reemplaza **Main.gs**, **Reconstruccion.gs** y **Pruebas.gs**.
3. Ejecuta `probarTodo` (todas OK; no llama a Gemini). No pide permisos nuevos: `script.external_request` ya está en `appsscript.json`.
4. Si Gemini no estaba disponible (cuota, red), el motivo dice "IA: no disponible": ejecuta `reintentarSugerenciasIA` más tarde.
5. Uso: `SELECT inicio, llamadas_ia, detalle FROM ejecuciones WHERE llamadas_ia > 0 ORDER BY id DESC;`

## Conciliación y resumen mensual (sql/13, 21/11)
La regla vive en la base (`sql/13_conciliacion_resumen.sql`); Alertas.gs solo la llama antes de enviar.
1. Supabase → SQL Editor → ejecuta `sql/13_conciliacion_resumen.sql` (al final: *Conciliación y resumen: 21/21 pruebas OK*). **Primero el SQL**: si pegas Alertas.gs antes, `revisarAlertas` sigue enviando las alertas, pero termina en error ("no existe fn_conciliar_movimientos").
2. Reemplaza **Alertas.gs**, crea **PruebasResumen.gs** y agrega en **Pruebas.gs**, debajo de `casos.push(...casosIA_());`, la línea `casos.push(...casosResumen_());`.
3. Ejecuta `probarTodo` (51/51). No hace falta un activador nuevo: usa el de `revisarAlertas`.
4. Probar el resumen ya (sin esperar al día 1): `SELECT fn_generar_resumen_mensual('2026-10-01');` en Supabase y luego `revisarAlertas`.
5. Para que un recibo se concilie, su fuente debe tener `es_recibo = true` (Retool → Fuentes) y la consulta de Gmail debe incluir ese remitente (propiedad `GMAIL_CONSULTA`).

