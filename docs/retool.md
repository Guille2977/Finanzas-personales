# Panel en Retool: conexión y consultas

Guía para armar el panel de Retool sobre Supabase con el usuario de permisos mínimos `retool_panel` (`sql/12_rol_retool.sql`). Cada pantalla trae sus consultas SQL listas para pegar, con la sintaxis `{{ componente.value }}` de Retool.

Todas las consultas de este documento se probaron como `retool_panel` en PostgreSQL 16, con `sql/01` a `sql/12` y los datos demo.

**Contenido**
1. [Conexión](#1-conexión)
2. [Reglas para escribir consultas en Retool](#2-reglas-para-escribir-consultas-en-retool)
3. [Consultas compartidas](#3-consultas-compartidas-listas-para-los-desplegables)
4. [Dashboard](#4-dashboard)
5. [Movimientos](#5-movimientos)
6. [Por revisar](#6-por-revisar)
7. [Presupuestos](#7-presupuestos)
8. [Configuración](#8-configuración)
9. [Salud](#9-salud)
10. [Preguntas de entrevista](#10-preguntas-de-entrevista)

---

## 1. Conexión

### Paso 1 · Crear el usuario en Supabase

1. Supabase → **SQL Editor** → pega y ejecuta `sql/12_rol_retool.sql` (antes debe estar `sql/11_alertas.sql`). Debe terminar con `NOTICE: 12_rol_retool: 12/12 pruebas de permisos OK` y dos tablas con los permisos.
2. Genera una contraseña larga. Por ejemplo, en la terminal de Codespaces: `openssl rand -hex 24` (solo letras y números: evita problemas con caracteres especiales). Guárdala en tu gestor de contraseñas.
3. En una pestaña **nueva** del SQL Editor ejecuta (con tu contraseña):

   ```sql
   ALTER ROLE retool_panel WITH PASSWORD 'pega_aqui_la_contraseña';
   ```

   Después **borra esa línea** y no guardes la pestaña como *snippet*: la contraseña no debe quedar en el historial ni en GitHub.

> **Por qué la contraseña no está en el script:** el script va a GitHub. El rol se crea con `LOGIN` pero sin contraseña, y un rol sin contraseña no puede entrar. Es seguro por defecto: hasta que tú la pones, nadie entra.

### Paso 2 · Copiar los datos del Session pooler

Supabase → botón **Connect** (arriba) → pestaña **Connection string** → método **Session pooler**. Toma de ahí:

| Campo | Valor |
|---|---|
| Host | `aws-0-<región>.pooler.supabase.com` (o `aws-1-…`, el que muestre) |
| Puerto | `5432` |
| Base de datos | `postgres` |
| Usuario | `retool_panel.<project-ref>`: el que muestra Supabase es `postgres.<project-ref>`; cambia solo la parte de antes del punto |
| Contraseña | la del paso 1 |

**Por qué Session pooler y no otra opción:**

- La **conexión directa** (`db.<ref>.supabase.co`) es solo IPv6 en el plan gratuito, y Retool Cloud se conecta por IPv4.
- El **Transaction pooler** (puerto 6543) reparte cada transacción a una conexión distinta, así que no admite *prepared statements* (Retool los usa en cada consulta con `{{ }}`) ni conserva los ajustes de sesión del rol (`statement_timeout`, `timezone`).
- El **Session pooler** es IPv4 y te da una conexión completa durante la sesión. Para un panel de un solo usuario es lo correcto.
- El sufijo `.<project-ref>` en el usuario le dice al pooler (compartido entre proyectos) a qué base enviarte.

### Paso 3 · Crear el recurso en Retool

Retool → **Resources** → **Create new** → **Resource** → **PostgreSQL**:

1. **Name:** `supabase_finanzas`.
2. **Host, Port, Database name, Database username, Database password:** los del paso 2.
3. **SSL:** activa *Connect using SSL*. Supabase lo exige.
4. Deja activado el uso de *prepared statements* (viene así por defecto). Si ves la opción *Disable converting queries to prepared statements*, no la marques.
5. **Test connection** → **Create resource**.

### Paso 4 · Comprobar que es el usuario correcto

Crea una consulta en una app nueva y ejecútala:

```sql
SELECT current_user, now() AS hora_lima, current_setting('statement_timeout') AS limite;
```

Debe decir `retool_panel`, la hora de Lima y `15s`. Luego prueba que **no** puede borrar:

```sql
DELETE FROM public.movimientos WHERE false;
```

Debe fallar con `permission denied for table movimientos`. Esa captura sirve para el README: demuestra el mínimo privilegio, no solo lo afirma.

### Qué puede y qué no puede hacer `retool_panel`

| Puede | No puede |
|---|---|
| Leer catálogos, movimientos, correos, ejecuciones, alertas y las vistas `v_*` | Leer `telegram_updates`; escribir en `alertas` o ejecutar `fn_generar_alertas` |
| Corregir de un movimiento: categoría, descripción, contraparte, estado (anular o reactivar) | Cambiar monto, fecha, cuenta u origen; insertar movimientos directo |
| Descartar o restaurar un correo "por revisar" | Marcar un correo "procesado" sin movimiento (lo impide RLS) |
| Resolver un "por revisar" con `fn_resolver_por_revisar` | Hacer `DELETE` o `TRUNCATE` en cualquier tabla |
| Agregar y editar categorías, diccionario, frases, fuentes, presupuestos y umbrales de alerta; cambiar el valor de un parámetro | Crear parámetros nuevos, crear tablas o roles, saltarse RLS |

Si algún día la contraseña se filtra: `ALTER ROLE retool_panel NOLOGIN;` corta el acceso al instante.

---

## 2. Reglas para escribir consultas en Retool

Estas reglas explican detalles que se repiten en todas las consultas.

1. **`{{ }}` es un parámetro, no texto pegado.** Retool convierte cada `{{ x }}` en `$1`, `$2`… y envía el valor aparte (*prepared statement*). Por eso no hay inyección SQL aunque escribas `' OR 1=1 --` en un buscador. Es lo mismo que `sp_executesql` con parámetros en SQL Server. Consecuencia: `{{ }}` solo puede ir donde va un **valor**, no un nombre de tabla o columna.
2. **Castea los parámetros opcionales:** `{{ selCuenta.value }}::int IS NULL`. Sin el `::int`, PostgreSQL no sabe de qué tipo es `$1` y falla con *could not determine data type of parameter $1*. En SQL Server, `sp_executesql` te obliga a declarar los tipos; aquí los declaras con el cast.
3. **Texto vacío no es NULL:** un `TextInput` vacío envía `''`. Usa `NULLIF({{ txt.value }}, '')`.
4. **`NUMERIC` llega a JavaScript como texto** (para no perder precisión). En las consultas para gráficos e indicadores se convierte con `::float8` al final. La base sigue guardando `NUMERIC`, que es exacto.
5. **Fechas:** `movimientos.fecha` es `TIMESTAMPTZ`. Se devuelve tal cual (Retool la muestra en la hora del navegador, que es Lima). Para **agrupar** (por día o mes) se convierte primero a hora de Lima y se devuelve como texto (`'2026-11'`), así Retool no la mueve de zona horaria y el eje del gráfico se lee bien.
6. **Filtra por rango, no por función:** `m.fecha >= desde AND m.fecha < hasta + 1 día` usa el índice `ix_mov_fecha`. `m.fecha::date = …` aplica una función a la columna y obliga a leer toda la tabla (en SQL Server se dice que la condición deja de ser *SARGable*).
7. **Cada consulta de Retool es su propia transacción.** Lo que tiene varios pasos (crear el movimiento y marcar el correo) va en una función de la base (`fn_resolver_por_revisar`), no en dos consultas seguidas.
8. **`query.data` viene por columnas** (`qMeses.data.mes[0]`). Si necesitas filas, usa `formatDataAsArray(query.data)`.
9. Las consultas que **escriben** van con *Run behavior: Manual* y, en *Event handlers → Success*, refrescan las consultas que leen (`qMovimientos.trigger()`).

**Nombres de componentes usados:** prefijo por tipo, como en Retool: `sel` (Select), `txt` (Text input), `num` (Number input), `dt` (Date), `chk` (Checkbox o Switch), `tbl` (Table). Si tus componentes se llaman distinto, cambia solo lo que está dentro de `{{ }}`.

---

## 3. Consultas compartidas (listas para los desplegables)

Créalas a nivel de app (no de una página) para usarlas en todas las pantallas.

**`qCategorias`**: opciones de los Select de categoría (*Value* `id_categoria`, *Label* `etiqueta`).

```sql
SELECT id_categoria,
       nombre,
       tipo,
       coalesce(icono || ' ', '') || nombre AS etiqueta   -- || concatena (≈ + de SQL Server)
FROM public.categorias
WHERE activo
ORDER BY tipo, nombre;
```

**`qCuentas`**

```sql
SELECT id_cuenta, alias
FROM public.cuentas
WHERE activo
ORDER BY alias;
```

**`qMeses`**: opciones de `selMes`. Valor por defecto de `selMes`: `{{ qMeses.data.mes[0] }}` (el mes más reciente).

```sql
SELECT DISTINCT to_char(mes, 'YYYY-MM') AS mes
FROM public.v_movimientos_contables
ORDER BY mes DESC;
```

---

## 4. Dashboard

Componentes: `selMes` (Select con `qMeses`), `selPeriodo` (Select con los valores `day`, `week`, `month` y las etiquetas Día, Semana, Mes), `dtDesde` y `dtHasta` (Date). Valores por defecto sugeridos: `dtDesde` = `{{ moment().subtract(2, 'months').startOf('month').format('YYYY-MM-DD') }}` y `dtHasta` = `{{ moment().format('YYYY-MM-DD') }}`.

**`qKpiMes`**: indicadores del mes elegido frente al mes anterior (4 componentes *Statistic*).

```sql
WITH totales AS (
    SELECT mes,
           sum(monto) FILTER (WHERE sentido = 'ingreso') AS ingresos,   -- FILTER ≈ SUM(CASE WHEN ... END)
           sum(monto) FILTER (WHERE sentido = 'egreso')  AS egresos,
           count(*)                                      AS cantidad
    FROM public.v_movimientos_contables
    WHERE NOT es_transferencia
      AND moneda = 'PEN'
      AND mes IN (to_date({{ selMes.value }}, 'YYYY-MM'),
                  to_date({{ selMes.value }}, 'YYYY-MM') - INTERVAL '1 month')
    GROUP BY mes
)
SELECT coalesce(a.ingresos, 0)::float8                            AS ingresos,
       coalesce(a.egresos, 0)::float8                             AS egresos,
       (coalesce(a.ingresos, 0) - coalesce(a.egresos, 0))::float8 AS balance,
       coalesce(a.cantidad, 0)                                    AS cantidad,
       coalesce(p.egresos, 0)::float8                             AS egresos_mes_anterior,
       round(100.0 * (a.egresos - p.egresos) / nullif(p.egresos, 0), 1)::float8 AS variacion_egresos_pct
FROM (SELECT 1) AS uno                                             -- garantiza 1 fila aunque no haya datos
LEFT JOIN totales a ON a.mes = to_date({{ selMes.value }}, 'YYYY-MM')
LEFT JOIN totales p ON p.mes = to_date({{ selMes.value }}, 'YYYY-MM') - INTERVAL '1 month';
```

En el *Statistic* de egresos: *Value* `{{ qKpiMes.data.egresos[0] }}`, *Secondary value* `{{ qKpiMes.data.variacion_egresos_pct[0] / 100 }}` con formato porcentaje y *Positive trend* hacia abajo (gastar menos es bueno).

**`qGastoCategoria`**: gráfico de barras horizontales (o dona) del gasto del mes por categoría.

```sql
SELECT categoria,
       total::float8 AS total,
       cantidad
FROM public.v_gasto_categoria_mes
WHERE mes = to_date({{ selMes.value }}, 'YYYY-MM')
  AND sentido = 'egreso'
  AND moneda = 'PEN'
ORDER BY total DESC;
```

**`qTendencia`**: ingresos y egresos por día, semana o mes (gráfico de líneas o barras agrupadas).

```sql
SELECT to_char(date_trunc({{ selPeriodo.value }}, fecha_lima),
               CASE {{ selPeriodo.value }}
                    WHEN 'day'  THEN 'YYYY-MM-DD'
                    WHEN 'week' THEN 'IYYY-"S"IW'   -- semana ISO, empieza el lunes: 2026-S47
                    ELSE             'YYYY-MM' END)            AS periodo,
       coalesce(sum(monto) FILTER (WHERE sentido = 'ingreso'), 0)::float8 AS ingresos,
       coalesce(sum(monto) FILTER (WHERE sentido = 'egreso'),  0)::float8 AS egresos
FROM public.v_movimientos_contables
WHERE NOT es_transferencia
  AND moneda = 'PEN'
  AND dia BETWEEN {{ dtDesde.value }}::date AND {{ dtHasta.value }}::date
GROUP BY 1
ORDER BY 1;
```

`date_trunc` recibe la unidad como **valor** (`'week'`), así que sí puede ser un parámetro. En SQL Server no hay equivalente directo: harías un `CASE` con `DATEPART`, o `DATETRUNC` (solo desde SQL Server 2022).

**`qTopComercios`**: los 5 comercios o personas con más gasto del mes (tabla pequeña).

```sql
SELECT coalesce(contraparte, descripcion, '(sin dato)') AS comercio,
       count(*)                AS veces,
       sum(monto)::float8      AS total
FROM public.v_movimientos_contables
WHERE NOT es_transferencia
  AND sentido = 'egreso'
  AND moneda = 'PEN'
  AND mes = to_date({{ selMes.value }}, 'YYYY-MM')
GROUP BY 1
ORDER BY total DESC
LIMIT 5;   -- LIMIT ≈ TOP 5
```

Agrega también al Dashboard la gráfica de `qAvancePresupuesto` (sección 7).

---

## 5. Movimientos

Componentes: `dtDesde`, `dtHasta`, `selCategoria` y `selCuenta` (Select con *Allow clear*, para que vacío = todos), `txtBuscar`, `chkSinCategoria`, `chkAnulados`, y la tabla `tblMovimientos` (*Primary key*: `id_movimiento`).

**`qMovimientos`**

```sql
SELECT m.id_movimiento,
       m.fecha,                                            -- TIMESTAMPTZ: columna tipo "Datetime"
       m.sentido,
       m.monto::float8                       AS monto,
       m.moneda,
       cu.alias                              AS cuenta,
       m.id_categoria,
       coalesce(cat.nombre, 'Sin categoría') AS categoria,
       m.descripcion,
       m.contraparte,
       m.origen,
       m.estado,
       m.numero_operacion,
       m.id_movimiento_vinculado IS NOT NULL AS es_recibo_conciliado
FROM public.movimientos m
JOIN public.cuentas cu          ON cu.id_cuenta     = m.id_cuenta
LEFT JOIN public.categorias cat ON cat.id_categoria = m.id_categoria
-- Rango en hora de Lima, comparando la columna "desnuda" (usa el índice):
WHERE m.fecha >= ({{ dtDesde.value }}::date)::timestamp     AT TIME ZONE 'America/Lima'
  AND m.fecha <  ({{ dtHasta.value }}::date + 1)::timestamp AT TIME ZONE 'America/Lima'
  AND ({{ selCategoria.value }}::int IS NULL OR m.id_categoria = {{ selCategoria.value }}::int)
  AND ({{ selCuenta.value }}::int    IS NULL OR m.id_cuenta    = {{ selCuenta.value }}::int)
  AND (NOT {{ chkSinCategoria.value }}::boolean OR m.id_categoria IS NULL)
  AND ({{ chkAnulados.value }}::boolean OR m.estado = 'activo')
  AND (NULLIF({{ txtBuscar.value }}, '') IS NULL
       OR concat_ws(' ', m.descripcion, m.contraparte) ILIKE '%' || {{ txtBuscar.value }} || '%')  -- ILIKE = sin distinguir mayúsculas
ORDER BY m.fecha DESC
LIMIT 500;
```

`timestamp AT TIME ZONE 'America/Lima'` significa "esta hora es de Lima" y devuelve el instante exacto (`TIMESTAMPTZ`). Así, "hasta el 20/11" incluye un gasto del 20/11 a las 23:30 en Lima, que en UTC ya es 21/11.

### Corregir varias filas a la vez

En `tblMovimientos`, marca como **editables** solo `id_categoria` (tipo de columna *Select*, opciones de `qCategorias`), `descripcion` y `contraparte`. Botón "Guardar cambios" → `qGuardarMovimientos`:

```sql
-- changesetArray = solo las filas y columnas que editaste, más la clave primaria.
-- jsonb_to_recordset convierte ese JSON en filas (≈ OPENJSON ... WITH (...) de SQL Server).
UPDATE public.movimientos m
SET id_categoria = coalesce(c.id_categoria, m.id_categoria),
    descripcion  = coalesce(c.descripcion,  m.descripcion),
    contraparte  = coalesce(c.contraparte,  m.contraparte)
FROM jsonb_to_recordset({{ JSON.stringify(tblMovimientos.changesetArray) }}::jsonb)
     AS c(id_movimiento BIGINT, id_categoria INT, descripcion TEXT, contraparte TEXT)
WHERE m.id_movimiento = c.id_movimiento
RETURNING m.id_movimiento;
```

`coalesce(nuevo, actual)` hace falta porque cada fila del *changeset* trae solo las columnas que cambiaste; sin él, las demás quedarían en NULL. `UPDATE ... FROM` es como `UPDATE m SET ... FROM ... JOIN` de SQL Server. *Success* → `qMovimientos.trigger()` y `tblMovimientos.clearChangeset()`.

Si intentas editar el monto, la base responde `permission denied`: el permiso por columna lo impide aunque alguien marque esa columna como editable en Retool.

### Anular o reactivar (botón sobre la fila seleccionada)

**`qAnularReactivar`**

```sql
UPDATE public.movimientos
SET estado = CASE estado WHEN 'activo' THEN 'anulado' ELSE 'activo' END
WHERE id_movimiento = {{ tblMovimientos.selectedRow.id_movimiento }}::bigint
RETURNING id_movimiento, estado;   -- RETURNING ≈ OUTPUT inserted.* de SQL Server
```

No se borra: un anulado deja de sumar en las vistas pero queda la historia (borrado lógico). `actualizado_en` lo pone el trigger.

---

## 6. Por revisar

Dos bloques: correos que el sistema no pudo registrar solo, y movimientos que quedaron "Sin categoría".

### 6.1 Correos por revisar

**`qPorRevisar`** → tabla `tblPorRevisar` (*Primary key*: `id_correo`). Agrega una columna *Tag* con `etiqueta_ia`.

```sql
SELECT c.id_correo,
       c.fecha_correo,
       c.remitente,
       c.asunto,
       c.estado,
       c.detalle_error                                   AS motivo,
       c.sugerido_por_ia,
       CASE WHEN c.sugerido_por_ia THEN '🤖 Sugerido por IA' END AS etiqueta_ia,
       -- ->> saca un campo del JSON como texto (≈ JSON_VALUE de SQL Server)
       (c.datos_extraidos ->> 'monto')::numeric::float8 AS monto_sugerido,
       coalesce(c.datos_extraidos ->> 'sentido', f.sentido_defecto, 'egreso') AS sentido_sugerido,
       coalesce(c.datos_extraidos ->> 'moneda', 'PEN')   AS moneda_sugerida,
       c.datos_extraidos ->> 'contraparte'               AS contraparte_sugerida,
       c.datos_extraidos ->> 'numeroOperacion'           AS operacion_sugerida,
       cat.id_categoria                                  AS id_categoria_sugerida,
       f.id_cuenta_defecto                               AS id_cuenta_sugerida,
       f.nombre                                          AS fuente,
       left(c.cuerpo, 3000)                              AS cuerpo   -- left ≈ LEFT de SQL Server
FROM public.correos_raw c
LEFT JOIN public.fuentes f      ON f.id_fuente = c.id_fuente
LEFT JOIN public.categorias cat ON cat.nombre  = c.datos_extraidos ->> 'categoria' AND cat.activo
WHERE c.estado IN ('por_revisar', 'error')
ORDER BY c.sugerido_por_ia DESC, c.fecha_correo DESC;
```

Al lado de la tabla, un **Form** con valores por defecto tomados de la fila seleccionada:

| Componente | Valor por defecto |
|---|---|
| `numMonto` | `{{ tblPorRevisar.selectedRow.monto_sugerido }}` |
| `selSentido` (`egreso`, `ingreso`) | `{{ tblPorRevisar.selectedRow.sentido_sugerido }}` |
| `selCuentaRes` (`qCuentas`) | `{{ tblPorRevisar.selectedRow.id_cuenta_sugerida }}` |
| `selCategoriaRes` (`qCategorias`) | `{{ tblPorRevisar.selectedRow.id_categoria_sugerida }}` |
| `txtContraparte` | `{{ tblPorRevisar.selectedRow.contraparte_sugerida }}` |
| `txtOperacion` | `{{ tblPorRevisar.selectedRow.operacion_sugerida }}` |

Muestra el `cuerpo` del correo en un componente *Text* para que compares antes de confirmar. Si la fila dice "🤖 Sugerido por IA", los campos vienen de Gemini: **la IA propone, tú confirmas**.

**`qResolver`**: botón "Registrar movimiento".

```sql
SELECT public.fn_resolver_por_revisar(
           p_id_correo        => {{ tblPorRevisar.selectedRow.id_correo }}::bigint,
           p_monto            => {{ numMonto.value }}::numeric,
           p_sentido          => {{ selSentido.value }}::text,
           p_id_cuenta        => {{ selCuentaRes.value }}::int,
           p_id_categoria     => {{ selCategoriaRes.value }}::int,
           p_contraparte      => {{ txtContraparte.value }}::text,
           p_numero_operacion => {{ txtOperacion.value }}::text
       ) AS id_movimiento;
```

La función hace todo en una transacción: crea el movimiento (`origen = 'correo'`, enlazado al correo) y marca el correo como `procesado`. Si das doble clic, devuelve el mismo movimiento (idempotente). Si la categoría no corresponde al sentido (un egreso en "Otros ingresos"), muestra el error y no guarda nada. *Success* → `qPorRevisar.trigger()`.

**`qDescartar`**: botón "No es un movimiento".

```sql
UPDATE public.correos_raw
SET estado        = 'ignorado',
    detalle_error = concat_ws(' · ', detalle_error, 'Descartado en Retool'),
    procesado_en  = now()
WHERE id_correo = {{ tblPorRevisar.selectedRow.id_correo }}::bigint
  AND estado IN ('por_revisar', 'error')
RETURNING id_correo, estado;
```

Si alguien intenta `SET estado = 'procesado'` sin crear el movimiento, la política RLS lo rechaza (`new row violates row-level security policy`).

### 6.2 Convertir un formato nuevo en fuente

Si el correo es de un remitente que se repetirá, créale una fuente para que la próxima vez se procese solo (configuración en lugar de código).

Componentes: `txtFuenteNombre`, `txtRemitentePatron` (por defecto `{{ (tblPorRevisar.selectedRow.remitente.match(/@([\w.-]+)/) || [])[1]?.replace(/\./g, '\\.') }}`, por ejemplo `tienda-ficticia\.example`), `txtAsuntoPatron`, `selAccion` (`procesar`, `ignorar`), `selCuentaFuente`, `selCategoriaFuente`, `selSentidoFuente`.

**`qProbarPatron`**: probar antes de guardar (se ejecuta al escribir).

```sql
-- ~* = coincide con la expresión regular, sin distinguir mayúsculas.
-- SQL Server no tiene regex nativo (solo LIKE / PATINDEX).
SELECT {{ tblPorRevisar.selectedRow.remitente }}::text ~* {{ txtRemitentePatron.value }}::text AS remitente_coincide,
       coalesce({{ tblPorRevisar.selectedRow.asunto }}::text ~* NULLIF({{ txtAsuntoPatron.value }}, ''), true) AS asunto_coincide;
```

**`qCrearFuente`**

```sql
INSERT INTO public.fuentes
    (nombre, remitente_patron, asunto_patron, accion, extractor,
     id_cuenta_defecto, id_categoria_defecto, sentido_defecto, prioridad)
VALUES
    ({{ txtFuenteNombre.value }},
     {{ txtRemitentePatron.value }},
     NULLIF({{ txtAsuntoPatron.value }}, ''),
     {{ selAccion.value }},
     CASE WHEN {{ selAccion.value }} = 'procesar' THEN 'generico' END,   -- extractor genérico de Extractores.gs
     {{ selCuentaFuente.value }}::int,
     {{ selCategoriaFuente.value }}::int,
     NULLIF({{ selSentidoFuente.value }}, ''),
     CASE WHEN {{ selAccion.value }} = 'ignorar' THEN 10 ELSE 100 END)  -- las de ignorar se evalúan primero
RETURNING id_fuente, nombre;
```

Apps Script evalúa los patrones con `RegExp(..., 'i')` de JavaScript. Para patrones simples (texto y `\.`) se comporta igual que `~*` de PostgreSQL.

### 6.3 Movimientos sin categoría

**`qSinCategoria`**: incluye la sugerencia de `fn_clasificar` con el diccionario **actual** (útil después de agregar palabras).

```sql
SELECT m.id_movimiento,
       m.fecha,
       m.monto::float8 AS monto,
       m.sentido,
       m.descripcion,
       m.contraparte,
       s.id_sugerida,
       cat.nombre      AS categoria_sugerida
FROM public.movimientos m
CROSS JOIN LATERAL (   -- LATERAL ≈ CROSS APPLY: calcula la sugerencia una vez por fila
    SELECT public.fn_clasificar(concat_ws(' ', m.contraparte, m.descripcion), NULL, m.sentido) AS id_sugerida
) s
LEFT JOIN public.categorias cat ON cat.id_categoria = s.id_sugerida
WHERE m.estado = 'activo'
  AND m.id_categoria IS NULL
ORDER BY m.fecha DESC;
```

Para corregir uno por uno, usa la misma tabla editable y `qGuardarMovimientos` (cambia `tblMovimientos` por esta tabla). Botón "Aplicar sugerencias" → **`qAplicarSugerencias`**:

```sql
UPDATE public.movimientos m
SET id_categoria = s.id_sugerida
FROM (SELECT id_movimiento,
             public.fn_clasificar(concat_ws(' ', contraparte, descripcion), NULL, sentido) AS id_sugerida
      FROM public.movimientos
      WHERE estado = 'activo' AND id_categoria IS NULL) s
WHERE m.id_movimiento = s.id_movimiento
  AND s.id_sugerida IS NOT NULL
RETURNING m.id_movimiento;
```

### 6.4 Recibos por conciliar (requiere `sql/13`)

Recibos (Uber, Rappi…) con **más de un** cargo bancario posible: la conciliación automática no adivina y los deja aquí. Tabla `tblConciliar` con **`qConciliarPendientes`**:

```sql
SELECT id_recibo, fecha_recibo, monto::float8 AS monto, contraparte, cuenta, motivo,
       candidatos            -- JSON: [{id_banco, fecha, monto, contraparte, descripcion}, ...]
FROM public.v_conciliacion_por_revisar
ORDER BY fecha_recibo DESC;
```

Debajo, un **Select** `selCargo` con *Data source* `{{ tblConciliar.selectedRow.candidatos }}`, *Value* `{{ item.id_banco }}` y *Label* `{{ item.fecha + ' · S/ ' + item.monto + ' · ' + (item.contraparte || item.descripcion) }}`. Dos botones:

- **"Es este cargo"** → **`qVincular`**: `SELECT public.fn_resolver_conciliacion({{ tblConciliar.selectedRow.id_recibo }}, {{ selCargo.value }});`
- **"No es el mismo gasto"** → **`qNoEsElMismo`**: `SELECT public.fn_resolver_conciliacion({{ tblConciliar.selectedRow.id_recibo }}, NULL);`

En los dos, *On success* → `qConciliarPendientes.trigger()`. La función valida (mismo sentido y moneda, cargo libre) y es idempotente: un doble clic no hace nada malo. Con `NULL` también se **deshace** un vínculo automático equivocado (búscalo en Movimientos: el recibo tiene `id_movimiento_vinculado`).

Para marcar una fuente como recibo: en **Configuración → Fuentes**, columna `es_recibo` (agrégala a la consulta y a `qGuardarFuentes`). Los parámetros `conciliacion_*` y `resumen_*` aparecen solos en **Alertas (umbrales y parámetros)**.

---

## 7. Presupuestos

**`qAvancePresupuesto`**: mes actual (barra de progreso por categoría o gráfico de barras "límite vs gastado").

```sql
SELECT categoria,
       limite::float8     AS limite,
       gastado::float8    AS gastado,
       disponible::float8 AS disponible,
       porcentaje::float8 AS porcentaje,
       estado                               -- ok | alerta (≥ 80 %) | excedido (≥ 100 %)
FROM public.v_avance_presupuesto
ORDER BY porcentaje DESC;
```

En la tabla, colorea `estado` (columna *Tag*): `ok` verde, `alerta` ámbar y `excedido` rojo.

**`qHistorialPresupuesto`**: últimos 6 meses, con el límite que **estaba vigente en cada mes**.

```sql
WITH meses AS (
    SELECT generate_series(date_trunc('month', now() AT TIME ZONE 'America/Lima') - INTERVAL '5 months',
                           date_trunc('month', now() AT TIME ZONE 'America/Lima'),
                           INTERVAL '1 month')::date AS mes          -- ≈ tabla de números / CTE recursivo
)
SELECT to_char(ms.mes, 'YYYY-MM')                                         AS mes,
       cat.nombre                                                         AS categoria,
       p.monto_mensual::float8                                            AS limite,
       coalesce(g.total, 0)::float8                                       AS gastado,
       round(100 * coalesce(g.total, 0) / p.monto_mensual, 1)::float8     AS porcentaje
FROM meses ms
CROSS JOIN public.categorias cat
JOIN LATERAL (                                   -- ≈ CROSS APPLY (SELECT TOP 1 ... ORDER BY ...)
    SELECT pr.monto_mensual
    FROM public.presupuestos pr
    WHERE pr.id_categoria = cat.id_categoria
      AND pr.vigente_desde <= ms.mes
    ORDER BY pr.vigente_desde DESC
    LIMIT 1
) p ON true
LEFT JOIN public.v_gasto_categoria_mes g
       ON g.mes = ms.mes AND g.categoria = cat.nombre AND g.sentido = 'egreso' AND g.moneda = 'PEN'
WHERE cat.activo
ORDER BY ms.mes, cat.nombre;
```

**`qGuardarPresupuesto`**: Form con `selCategoriaPres` (categorías de egreso: en el Select usa `{{ formatDataAsArray(qCategorias.data).filter(c => c.tipo === 'egreso') }}`) y `numLimite`.

```sql
-- Vale desde el mes actual. Los meses pasados conservan su límite de entonces.
-- ON CONFLICT ... DO UPDATE ≈ MERGE ... WHEN MATCHED THEN UPDATE WHEN NOT MATCHED THEN INSERT.
INSERT INTO public.presupuestos (id_categoria, monto_mensual, vigente_desde)
VALUES ({{ selCategoriaPres.value }}::int,
        {{ numLimite.value }}::numeric,
        date_trunc('month', now() AT TIME ZONE 'America/Lima')::date)
ON CONFLICT (id_categoria, vigente_desde)
DO UPDATE SET monto_mensual = EXCLUDED.monto_mensual
RETURNING id_categoria, monto_mensual, vigente_desde;
```

---

## 8. Configuración

Una página con pestañas (*Tabbed container*): Categorías, Diccionario, Frases, Fuentes y Alertas. Todo se **desactiva**, no se borra (el rol no tiene `DELETE`).

### Categorías

**`qCategoriasConfig`**: con cuánto se usa cada una (para decidir si conviene desactivarla).

```sql
SELECT c.id_categoria,
       c.nombre,
       c.tipo,
       c.icono,
       c.activo,
       (SELECT count(*) FROM public.movimientos m WHERE m.id_categoria = c.id_categoria) AS movimientos,
       (SELECT count(*) FROM public.diccionario d WHERE d.id_categoria = c.id_categoria) AS palabras
FROM public.categorias c
ORDER BY c.activo DESC, c.tipo, c.nombre;
```

**`qCrearCategoria`**

```sql
INSERT INTO public.categorias (nombre, tipo, icono)
VALUES (btrim({{ txtCategoriaNombre.value }}),     -- btrim ≈ TRIM
        {{ selCategoriaTipo.value }},              -- egreso | ingreso | transferencia
        NULLIF({{ txtCategoriaIcono.value }}, ''))
RETURNING id_categoria, nombre;
```

**`qActivarCategoria`**: botón de fila (lo mismo sirve para las demás tablas, cambiando nombre y clave).

```sql
UPDATE public.categorias
SET activo = NOT activo
WHERE id_categoria = {{ tblCategorias.selectedRow.id_categoria }}::int
RETURNING id_categoria, activo;
```

### Diccionario

**`qDiccionario`**

```sql
SELECT d.id,
       d.palabra,
       c.nombre   AS categoria,
       d.id_categoria,
       d.origen,                  -- manual | bot (aprendida en Telegram)
       d.activo,
       d.creado_en
FROM public.diccionario d
JOIN public.categorias c ON c.id_categoria = d.id_categoria
WHERE NULLIF({{ txtBuscarPalabra.value }}, '') IS NULL
   OR d.palabra LIKE '%' || public.fn_normalizar({{ txtBuscarPalabra.value }}) || '%'
ORDER BY d.creado_en DESC;
```

**`qGuardarPalabra`**: agrega o reasigna una palabra. Se normaliza en la base con la misma función que usa el clasificador.

```sql
INSERT INTO public.diccionario (palabra, id_categoria)
VALUES (public.fn_normalizar({{ txtPalabra.value }}), {{ selCategoriaPalabra.value }}::int)
ON CONFLICT (palabra)
DO UPDATE SET id_categoria = EXCLUDED.id_categoria, activo = true
RETURNING id, palabra, id_categoria;
```

Si la palabra queda vacía (por ejemplo, solo símbolos), el `CHECK` de la tabla la rechaza.

**`qProbarClasificador`**: escribe un texto como lo escribirías en el bot o como llega de un banco y mira qué categoría le daría el sistema.

```sql
SELECT public.fn_normalizar({{ txtProbar.value }}) AS texto_normalizado,
       coalesce(c.nombre, 'Sin categoría')         AS categoria
FROM (SELECT public.fn_clasificar({{ txtProbar.value }}, NULL, NULLIF({{ selSentidoProbar.value }}, '')) AS id) r
LEFT JOIN public.categorias c ON c.id_categoria = r.id;
```

### Frases de sentido

**`qFrases`**

```sql
SELECT id, frase, sentido, activo, creado_en
FROM public.frases_sentido
ORDER BY sentido, length(frase) DESC, frase;   -- la más larga gana: así se ve el orden real
```

**`qGuardarFrase`**

```sql
INSERT INTO public.frases_sentido (frase, sentido)
VALUES (public.fn_normalizar({{ txtFrase.value }}), {{ selFraseSentido.value }})
ON CONFLICT (frase)
DO UPDATE SET sentido = EXCLUDED.sentido, activo = true
RETURNING id, frase, sentido;
```

El bot relee esta tabla cada 60 s: una frase nueva funciona en Telegram al minuto, sin desplegar nada.

### Fuentes

**`qFuentes`**: con la fecha del último correo de cada una (si una fuente de banco lleva semanas sin correos, quizá cambió el remitente).

```sql
SELECT f.id_fuente,
       f.nombre,
       f.remitente_patron,
       f.asunto_patron,
       f.accion,
       f.extractor,
       cu.alias           AS cuenta_defecto,
       cat.nombre         AS categoria_defecto,
       f.sentido_defecto,
       f.prioridad,
       f.activo,
       u.ultimo_correo,
       u.correos_30d
FROM public.fuentes f
LEFT JOIN public.cuentas cu     ON cu.id_cuenta     = f.id_cuenta_defecto
LEFT JOIN public.categorias cat ON cat.id_categoria = f.id_categoria_defecto
LEFT JOIN LATERAL (
    SELECT max(c.fecha_correo)                                                  AS ultimo_correo,
           count(*) FILTER (WHERE c.fecha_correo >= now() - INTERVAL '30 days') AS correos_30d
    FROM public.correos_raw c
    WHERE c.id_fuente = f.id_fuente
) u ON true
ORDER BY f.prioridad, f.nombre;
```

**`qEditarFuente`**: Form sobre la fila seleccionada (`txtEditRemitente`, `txtEditAsunto`, `numEditPrioridad`). El nombre no se edita: es la clave natural que usan los scripts `sql/0x`.

```sql
UPDATE public.fuentes
SET remitente_patron = {{ txtEditRemitente.value }},
    asunto_patron    = NULLIF({{ txtEditAsunto.value }}, ''),
    prioridad        = {{ numEditPrioridad.value }}::int
WHERE id_fuente = {{ tblFuentes.selectedRow.id_fuente }}::int
RETURNING id_fuente, nombre;
```

Para crear una fuente, usa `qCrearFuente` (sección 6.2).

### Alertas (umbrales y parámetros)

Configuran `fn_generar_alertas` (`sql/11_alertas.sql`). Cambiarlos no requiere tocar Apps Script.

**`qUmbrales`**

```sql
SELECT porcentaje, activo
FROM public.umbrales_presupuesto
ORDER BY porcentaje;
```

**`qGuardarUmbral`**: agrega un umbral (por ejemplo, 50 %) o lo reactiva.

```sql
INSERT INTO public.umbrales_presupuesto (porcentaje)
VALUES ({{ numUmbral.value }}::int)          -- el CHECK de la tabla exige 1 a 300
ON CONFLICT (porcentaje) DO UPDATE SET activo = true
RETURNING porcentaje, activo;
```

**`qActivarUmbral`**

```sql
UPDATE public.umbrales_presupuesto
SET activo = NOT activo
WHERE porcentaje = {{ tblUmbrales.selectedRow.porcentaje }}::int
RETURNING porcentaje, activo;
```

**`qParametros`** → tabla `tblParametros` (*Primary key*: `clave`) con `valor` editable.

```sql
SELECT clave, valor, descripcion
FROM public.parametros
ORDER BY clave;
```

**`qGuardarParametros`**: solo se cambia el **valor**; las claves las definen `sql/11` y `sql/13` porque cada una la lee el código.

```sql
UPDATE public.parametros p
SET valor = btrim(c.valor)
FROM jsonb_to_recordset({{ JSON.stringify(tblParametros.changesetArray) }}::jsonb) AS c(clave TEXT, valor TEXT)
WHERE p.clave = c.clave
  AND c.valor ~ '^\s*([0-9]+(\.[0-9]{1,2})?|true|false)\s*$'   -- enteros, montos (0.10) o true/false (sql/13)
RETURNING p.clave, p.valor;
```

Si escribes algo que no es un número, esa fila no se guarda (el `RETURNING` sale vacío): así un error de tipeo no rompe `fn_generar_alertas`, que hace `valor::int`.

---

## 9. Salud

**`qSalud`**: una fila con 4 *Statistic* y un *Tag* con `estado`.

```sql
SELECT estado,                                        -- ok | revisar: ... | alerta: ...
       ultima_ejecucion,
       ultima_captura,
       horas_sin_ejecucion::float8 AS horas_sin_ejecucion,
       errores_24h,
       por_revisar,
       correos_error_o_pendientes,
       sin_categoria
FROM public.v_salud_sistema;
```

**`qEjecucionesDia`**: últimos 14 días por proceso (gráfico de barras apiladas: `ejecuciones` por `proceso`, más una línea de `errores`).

```sql
SELECT to_char((inicio AT TIME ZONE 'America/Lima')::date, 'YYYY-MM-DD') AS dia,
       proceso,
       count(*)          AS ejecuciones,
       sum(leidos)       AS leidos,
       sum(insertados)   AS insertados,
       sum(por_revisar)  AS por_revisar,
       sum(errores)      AS errores,
       sum(llamadas_ia)  AS llamadas_ia
FROM public.ejecuciones
WHERE inicio >= now() - INTERVAL '14 days'
GROUP BY 1, 2
ORDER BY 1, 2;
```

**`qUltimasEjecuciones`**: tabla con el detalle; filtra a las que tuvieron errores con `chkSoloErrores`.

```sql
SELECT id,
       proceso,
       inicio,
       round(EXTRACT(EPOCH FROM fin - inicio)::numeric, 1)::float8 AS segundos,  -- ≈ DATEDIFF(second, ...)
       leidos, insertados, por_revisar, errores, llamadas_ia,
       detalle
FROM public.ejecuciones
WHERE (NOT {{ chkSoloErrores.value }}::boolean OR errores > 0)
ORDER BY inicio DESC
LIMIT 100;
```

**`qAlertas`**: historial de avisos (tabla). Una alerta con `estado = 'fallida'` agotó sus intentos de envío por Telegram.

```sql
SELECT a.id,
       a.tipo,                               -- presupuesto | error_captura | sin_captura
       a.mensaje,
       a.creada_en,
       a.enviada_en,
       a.intentos,
       a.ultimo_error,
       CASE WHEN a.enviada_en IS NOT NULL THEN 'enviada'
            WHEN EXISTS (SELECT 1 FROM public.v_alertas_pendientes v WHERE v.id = a.id) THEN 'pendiente'
            ELSE 'fallida' END               AS estado
FROM public.alertas a
WHERE a.creada_en >= now() - INTERVAL '30 days'
ORDER BY a.creada_en DESC;
```

**`qCorreosEstado`**: cómo terminó cada correo en los últimos 30 días (dona o tabla pequeña).

```sql
SELECT estado, count(*) AS correos
FROM public.correos_raw
WHERE creado_en >= now() - INTERVAL '30 days'
GROUP BY estado
ORDER BY correos DESC;
```

---

## 10. Preguntas de entrevista

- **¿Por qué no conectaste Retool con el usuario `postgres` o la clave `service_role`?** Por mínimo privilegio. Si alguien obtiene la contraseña del panel, no puede borrar nada, cambiar montos ni leer otras tablas. Lo verifiqué con 12 pruebas de permisos (`sql/12`) y 17 pruebas que entran como el rol e intentan acciones prohibidas (`sql/pruebas/12_rol_retool_pruebas.sql`).
- **¿Para qué RLS si ya tienes GRANT?** El GRANT dice qué comandos y columnas; RLS dice qué filas. Ejemplo: el panel puede cambiar el estado de un correo, pero RLS no le deja marcarlo "procesado" a mano; eso solo lo hace la función, que además crea el movimiento.
- **¿Por qué una función para resolver "Por revisar"?** Son dos escrituras que deben pasar juntas o ninguna. En Retool cada consulta es una transacción aparte. La función es `SECURITY DEFINER` (como `EXECUTE AS OWNER` en SQL Server): el panel tiene permiso de ejecutarla, no de insertar movimientos.
- **¿Cómo evitas inyección SQL en el panel?** Retool envía `{{ }}` como parámetros de un *prepared statement*, no concatena texto.
- **¿Por qué Session pooler?** La conexión directa es solo IPv6 y el Transaction pooler no admite *prepared statements* ni ajustes de sesión.
