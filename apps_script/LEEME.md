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
| Alertas.gs | Envía por Telegram los avisos que decide la base (`sql/11`): presupuesto 80 %/100 %, errores de captura y captura detenida |
| Main.gs | Funciones a ejecutar + pipeline de captura |
| Migracion.gs | Migra la hoja de cálculo anterior a Supabase (una sola vez) |
| Pruebas.gs | Pruebas de la lógica (sin Gmail ni Supabase) |

## Instalación (en orden)
1. script.google.com → **Nuevo proyecto** → nómbralo "Finanzas automatizadas".
2. ⚙️ Configuración del proyecto → marca **Mostrar el archivo de manifiesto "appsscript.json"** → pega `appsscript.json`.
3. Crea cada archivo `.gs` (botón **+ → Secuencia de comandos**, sin escribir ".gs") y pega su contenido. Borra `Código.gs` vacío.
4. ⚙️ → **Propiedades del script** → agrega:
   - `SUPABASE_URL` = Project URL (Supabase → Project Settings → API / Data API)
   - `SUPABASE_KEY` = clave **service_role** (o *secret*), nunca la anon
   - `HOJA_ID` = el ID de la URL de la hoja "Movimientos bancarios"
5. Ejecuta en este orden (selector de función → ▶ Ejecutar), revisando el registro:
   1. `probarTodo` → 28/28 pruebas OK.
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
