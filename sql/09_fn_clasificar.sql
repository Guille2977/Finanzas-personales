-- =====================================================================
-- 09_fn_clasificar.sql · Una sola regla de clasificación para correos y bot
-- Requiere: 01 a 08. Idempotente (CREATE OR REPLACE). Solo AGREGA
-- funciones: no cambia tablas, datos, vistas ni Retool.
--
-- Antes: normalizar + buscar en el diccionario estaba escrito dos veces
-- (Categorias.gs para correos y logica.ts para el bot). Si se corregía
-- uno y no el otro, el mismo texto podía caer en categorías distintas.
-- Ahora ambos llaman a fn_clasificar por la API (POST /rest/v1/rpc/...).
--
-- Reglas, en orden:
--   1. Manda la fuente: si la fuente tiene categoría por defecto, esa.
--   2. Diccionario: palabra COMPLETA dentro del texto normalizado.
--      Si hay varias, gana la más larga (la más específica: "menu ejecutivo"
--      antes que "menu"); empate → orden alfabético, para que sea determinista.
--   3. Si se pasa p_sentido, solo categorías de ese tipo (un ingreso no
--      cae en "Comida"). Los correos no lo pasan (igual que antes).
--   4. Nada coincide → NULL ("Sin categoría", se corrige en Retool o Telegram).
--
-- PostgreSQL vs SQL Server:
--   · LANGUAGE sql + una sola consulta ≈ inline table-valued function: el
--     planificador puede "abrirla" dentro de la consulta que la llama. Las
--     funciones escalares T-SQL clásicas se ejecutan fila por fila (SQL
--     Server 2019 recién las "inlinea" en algunos casos).
--   · IMMUTABLE / STABLE le dicen al planificador qué tan pura es la función:
--       IMMUTABLE = mismo resultado siempre con los mismos argumentos
--                   (fn_normalizar: solo transforma texto).
--       STABLE    = mismo resultado dentro de una consulta, pero lee tablas
--                   (fn_clasificar lee diccionario y fuentes).
--     En SQL Server lo más parecido es WITH SCHEMABINDING / determinismo.
--   · Parámetros con DEFAULT y llamada por nombre (p_texto => '...'): SQL
--     Server también tiene defaults, pero exige escribir DEFAULT al llamar.
--   · SET search_path = '' : la función no depende del esquema de quien la
--     llama (evita que alguien "suplante" una tabla); por eso todo va con
--     public.  Es lo que recomienda el linter de seguridad de Supabase.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- fn_normalizar: igual que el CHECK de diccionario.palabra.
-- Minúsculas, sin tildes (conserva la ñ), solo letras/números separados
-- por un espacio. No se usa la extensión unaccent porque convierte ñ → n.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_normalizar(p_texto TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = ''
AS $$
    SELECT btrim(regexp_replace(
               translate(lower(coalesce(p_texto, '')),
                         'áàäâãåéèëêíìïîóòöôõúùüûç',
                         'aaaaaaeeeeiiiiooooouuuuc'),
               '[^a-zñ0-9]+', ' ', 'g'));
$$;

COMMENT ON FUNCTION public.fn_normalizar(TEXT) IS
    'Normaliza texto como diccionario.palabra: minúsculas, sin tildes (conserva ñ), solo letras y números.';

-- ---------------------------------------------------------------------
-- fn_clasificar: devuelve id_categoria o NULL.
--   p_texto     contraparte + descripción (correos) o el mensaje (bot)
--   p_id_fuente fuente del correo (NULL en el bot)
--   p_sentido   'egreso' | 'ingreso' para filtrar por tipo (NULL = sin filtro)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_clasificar(
    p_texto     TEXT,
    p_id_fuente INT  DEFAULT NULL,
    p_sentido   TEXT DEFAULT NULL
)
RETURNS INT
LANGUAGE sql
STABLE
PARALLEL SAFE
SET search_path = ''
AS $$
    SELECT coalesce(
        -- 1. Manda la fuente.
        (SELECT f.id_categoria_defecto
         FROM public.fuentes f
         WHERE f.id_fuente = p_id_fuente),
        -- 2. Diccionario (palabra completa; la más larga gana).
        (SELECT d.id_categoria
         FROM public.diccionario d
         JOIN public.categorias c ON c.id_categoria = d.id_categoria
         WHERE d.activo
           AND c.activo
           AND (p_sentido IS NULL OR c.tipo = p_sentido)
           -- ' menu ejecutivo ' LIKE '% menu %' → palabra completa.
           -- (No se usa ~ con \m...\M para no interpretar la palabra como regex.)
           AND ' ' || public.fn_normalizar(p_texto) || ' ' LIKE '% ' || d.palabra || ' %'
         ORDER BY length(d.palabra) DESC, d.palabra
         LIMIT 1)
    );
$$;

COMMENT ON FUNCTION public.fn_clasificar(TEXT, INT, TEXT) IS
    'Regla única de clasificación (correos y bot): categoría de la fuente → diccionario (palabra completa, la más larga) → NULL.';

-- Seguridad: en PostgreSQL toda función nueva se puede ejecutar por PUBLIC
-- (en SQL Server, por defecto nadie tiene EXECUTE). Se quita y se da solo
-- a service_role, igual que las tablas.
REVOKE ALL ON FUNCTION public.fn_normalizar(TEXT)            FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_clasificar(TEXT, INT, TEXT) FROM PUBLIC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT EXECUTE ON FUNCTION public.fn_normalizar(TEXT)            TO service_role;
        GRANT EXECUTE ON FUNCTION public.fn_clasificar(TEXT, INT, TEXT) TO service_role;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.fn_normalizar(TEXT)            FROM anon, authenticated;
        REVOKE ALL ON FUNCTION public.fn_clasificar(TEXT, INT, TEXT) FROM anon, authenticated;
    END IF;
END
$$;

-- La API (PostgREST) guarda en caché qué funciones existen: se le avisa.
NOTIFY pgrst, 'reload schema';

COMMIT;

-- =====================================================================
-- Pruebas (solo leen). Cada fila debe decir ok = true.
-- Usan palabras del diccionario semilla (02, 06, 07).
-- =====================================================================
SELECT prueba, obtenido, esperado, obtenido IS NOT DISTINCT FROM esperado AS ok
FROM (VALUES
    ('normaliza tildes y conserva ñ',
        public.fn_normalizar('  Menú  ÑANDÚ!'), 'menu ñandu'),
    ('correo: diccionario por contraparte',
        (SELECT c.nombre FROM public.categorias c
         WHERE c.id_categoria = public.fn_clasificar('KFC MIRAFLORES Consumo')), 'Comida'),
    ('palabra completa: "steamgames" no es "steam"',
        (SELECT c.nombre FROM public.categorias c
         WHERE c.id_categoria = public.fn_clasificar('WWW.STEAMGAMES.COM')), 'Entretenimiento'),
    ('bot: frase libre',
        (SELECT c.nombre FROM public.categorias c
         WHERE c.id_categoria = public.fn_clasificar('galletas gaseosa', p_sentido => 'egreso')), 'Comida'),
    ('bot: un ingreso no cae en Comida',
        public.fn_clasificar('almuerzo', p_sentido => 'ingreso')::TEXT, NULL),
    ('sin coincidencia → NULL',
        public.fn_clasificar('xyz qwerty')::TEXT, NULL),
    ('texto NULL → NULL',
        public.fn_clasificar(NULL)::TEXT, NULL)
) AS t(prueba, obtenido, esperado);

-- "Manda la fuente": la fuente con categoría por defecto gana al diccionario.
SELECT f.nombre AS fuente,
       public.fn_clasificar('KFC', f.id_fuente) = f.id_categoria_defecto AS ok
FROM public.fuentes f
WHERE f.id_categoria_defecto IS NOT NULL;

-- Así lo llama la API (equivale a POST /rest/v1/rpc/fn_clasificar):
--   SELECT public.fn_clasificar(p_texto => 'RAPPI PERU Consumo', p_id_fuente => 3);
