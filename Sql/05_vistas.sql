-- ============================================================
-- 05_vistas.sql
-- Vistas de consulta, analiticas (dashboard y examen) y vistas
-- materializadas. Re-ejecutable: CREATE OR REPLACE VIEW y las vistas
-- materializadas se borran y se vuelven a crear.
-- Depende de 02_tablas.sql y de pkg_reglas (04_pkg_reglas.sql).
-- Reglas comunes:
--   * consumo, ventas y saldos solo cuentan transacciones APROBADA
--     (una BLOQUEADA no despacho combustible)
--   * vigencia semiabierta [fecha_inicio, fecha_fin); NULL = vigente
--   * semanas ISO (lunes); dia de semana 1 = lunes ... 7 = domingo
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ============================================================
-- A. REGLAS, PRECIOS Y MAESTROS
-- ============================================================

-- A1. Reglas vigentes hoy, con su ambito legible y si bloquean
CREATE OR REPLACE VIEW v_regla_vigente AS
SELECT r.id_regla,
       tr.codigo            AS codigo_regla,
       tr.familia,
       tr.evaluacion,
       tv.nombre            AS tipo_vehiculo,
       c.nombre             AS combustible,
       p.codigo             AS periodo,
       r.solo_fronteriza,
       cc.codigo            AS categoria_cilindrada,
       d.nombre             AS departamento,
       r.valor,
       r.valor_secundario,
       r.gravedad,
       CASE WHEN tr.familia = 'ANOMALIA' AND tr.evaluacion = 'TRANSACCION'
                 AND r.gravedad = 'ALTA' THEN 'S' ELSE 'N' END AS bloqueante,
       r.fecha_inicio
  FROM regla r
  JOIN tipo_regla tr                ON tr.id_tipo_regla          = r.id_tipo_regla
  LEFT JOIN tipo_vehiculo tv        ON tv.id_tipo_vehiculo       = r.id_tipo_vehiculo
  LEFT JOIN combustible c           ON c.id_combustible          = r.id_combustible
  LEFT JOIN tipo_periodo p          ON p.id_tipo_periodo         = r.id_tipo_periodo
  LEFT JOIN categoria_cilindrada cc ON cc.id_categoria_cilindrada = r.id_categoria_cilindrada
  LEFT JOIN departamento d          ON d.id_departamento         = r.id_departamento
 WHERE r.fecha_inicio <= SYSDATE
   AND (r.fecha_fin IS NULL OR SYSDATE < r.fecha_fin);

-- A2. Precio vigente hoy por combustible y tipo de precio
CREATE OR REPLACE VIEW v_precio_vigente AS
SELECT pc.id_precio,
       c.nombre            AS combustible,
       u.simbolo           AS unidad,
       pc.tipo_precio,
       pc.precio_unitario,
       pc.fecha_inicio
  FROM precio_combustible pc
  JOIN combustible c   ON c.id_combustible = pc.id_combustible
  JOIN unidad_medida u ON u.id_unidad      = c.id_unidad
 WHERE pc.fecha_inicio <= SYSDATE
   AND (pc.fecha_fin IS NULL OR SYSDATE < pc.fecha_fin);

-- A3. Beneficios vigentes hoy (vehiculo - titular)
CREATE OR REPLACE VIEW v_beneficio_vigente AS
SELECT b.id_beneficio,
       v.id_vehiculo,
       v.placa,
       v.pais_placa,
       p.id_persona,
       REGEXP_REPLACE(TRIM(p.nombres || ' ' || p.apellido_paterno || ' ' || p.apellido_materno),
                      ' +', ' ')            AS titular,
       p.tipo_documento,
       p.nro_documento,
       r.valor                              AS max_vehiculos_persona,
       b.fecha_inicio
  FROM registro_beneficio b
  JOIN vehiculo v ON v.id_vehiculo = b.id_vehiculo
  JOIN persona p  ON p.id_persona  = b.id_persona
  JOIN regla r    ON r.id_regla    = b.id_regla
 WHERE b.fecha_inicio <= SYSDATE
   AND (b.fecha_fin IS NULL OR SYSDATE < b.fecha_fin);

-- A4. Vehiculo con sus datos tecnicos, categoria de cilindrada (derivada)
--     y propietario RUAT vigente
CREATE OR REPLACE VIEW v_vehiculo_detalle AS
SELECT v.id_vehiculo,
       v.placa,
       v.pais_placa,
       CASE WHEN v.id_ficha IS NULL THEN 'S' ELSE 'N' END AS es_extranjero,
       tv.id_tipo_vehiculo,
       tv.nombre                AS tipo_vehiculo,
       f.marca,
       f.modelo,
       f.anio_fabricacion,
       f.cilindrada,
       cc.id_categoria_cilindrada,
       cc.codigo                AS categoria_cilindrada,
       f.capacidad_tanque,
       cf.nombre                AS combustible_ficha,
       ru.id_persona            AS id_propietario,
       REGEXP_REPLACE(TRIM(p.nombres || ' ' || p.apellido_paterno || ' ' || p.apellido_materno),
                      ' +', ' ') AS propietario,
       CASE WHEN EXISTS (SELECT 1 FROM registro_beneficio b
                          WHERE b.id_vehiculo = v.id_vehiculo
                            AND b.fecha_inicio <= SYSDATE
                            AND (b.fecha_fin IS NULL OR SYSDATE < b.fecha_fin))
            THEN 'S' ELSE 'N' END AS con_beneficio,
       v.fecha_registro
  FROM vehiculo v
  JOIN tipo_vehiculo tv             ON tv.id_tipo_vehiculo = v.id_tipo_vehiculo
  LEFT JOIN ficha_aduana f          ON f.id_ficha          = v.id_ficha
  LEFT JOIN combustible cf          ON cf.id_combustible   = f.id_combustible
  LEFT JOIN categoria_cilindrada cc ON f.cilindrada >= cc.cc_min
                                   AND (cc.cc_max IS NULL OR f.cilindrada <= cc.cc_max)
  LEFT JOIN registro_ruat ru        ON ru.id_vehiculo = v.id_vehiculo AND ru.fecha_baja IS NULL
  LEFT JOIN persona p               ON p.id_persona   = ru.id_persona;

-- ============================================================
-- B. OPERACIONES Y CONSUMO
-- ============================================================

-- B1. Historial: una fila por transaccion (APROBADA o BLOQUEADA), aplanada
CREATE OR REPLACE VIEW v_historial_carga AS
SELECT t.id_transaccion,
       t.nro_ticket,
       t.fecha_hora,
       t.tipo_transaccion,
       t.estado,
       e.id_estacion,
       e.nombre            AS estacion,
       e.zona,
       e.es_fronteriza,
       m.nombre            AS municipio,
       d.nombre            AS departamento,
       s.codigo            AS surtidor,
       vd.id_vehiculo,
       vd.placa,
       vd.pais_placa,
       vd.tipo_vehiculo,
       vd.categoria_cilindrada,
       c.id_combustible,
       c.nombre            AS combustible,
       u.simbolo           AS unidad,
       p.id_persona,
       REGEXP_REPLACE(TRIM(p.nombres || ' ' || p.apellido_paterno || ' ' || p.apellido_materno),
                      ' +', ' ')            AS persona,
       t.huella_verificada,
       cv.rfid_leido,
       t.cantidad_total,
       NVL(dt.cantidad_subvencionada, 0)    AS cantidad_subvencionada,
       NVL(dt.cantidad_internacional, 0)    AS cantidad_internacional,
       NVL(dt.monto_bs, 0)                  AS monto_bs,
       cb.nro_recipientes,
       cb.id_permiso
  FROM transaccion t
  JOIN surtidor s              ON s.id_surtidor     = t.id_surtidor
  JOIN estacion e              ON e.id_estacion     = s.id_estacion
  JOIN municipio m             ON m.id_municipio    = e.id_municipio
  JOIN departamento d          ON d.id_departamento = m.id_departamento
  JOIN combustible c           ON c.id_combustible  = t.id_combustible
  JOIN unidad_medida u         ON u.id_unidad       = c.id_unidad
  LEFT JOIN persona p          ON p.id_persona      = t.id_persona
  LEFT JOIN carga_vehicular cv ON cv.id_transaccion = t.id_transaccion
  LEFT JOIN v_vehiculo_detalle vd ON vd.id_vehiculo = cv.id_vehiculo
  LEFT JOIN compra_bidon cb    ON cb.id_transaccion = t.id_transaccion
  LEFT JOIN (
        SELECT dtr.id_transaccion,
               SUM(CASE WHEN pc.tipo_precio = 'SUBVENCIONADO' THEN dtr.cantidad ELSE 0 END) AS cantidad_subvencionada,
               SUM(CASE WHEN pc.tipo_precio = 'INTERNACIONAL' THEN dtr.cantidad ELSE 0 END) AS cantidad_internacional,
               SUM(dtr.cantidad * pc.precio_unitario)                                      AS monto_bs
          FROM detalle_transaccion dtr
          JOIN precio_combustible pc ON pc.id_precio = dtr.id_precio
         GROUP BY dtr.id_transaccion
       ) dt ON dt.id_transaccion = t.id_transaccion;

-- B2. Consumo por vehiculo, dia y combustible (solo APROBADA)
CREATE OR REPLACE VIEW v_consumo_vehiculo_dia AS
SELECT v.id_vehiculo,
       v.placa,
       v.pais_placa,
       tv.nombre                      AS tipo_vehiculo,
       TRUNC(CAST(t.fecha_hora AS DATE)) AS dia,
       c.nombre                       AS combustible,
       COUNT(*)                       AS nro_cargas,
       COUNT(DISTINCT s.id_estacion)  AS nro_estaciones,
       SUM(t.cantidad_total)          AS cantidad_total
  FROM carga_vehicular cv
  JOIN transaccion t    ON t.id_transaccion   = cv.id_transaccion
  JOIN vehiculo v       ON v.id_vehiculo      = cv.id_vehiculo
  JOIN tipo_vehiculo tv ON tv.id_tipo_vehiculo = v.id_tipo_vehiculo
  JOIN surtidor s       ON s.id_surtidor      = t.id_surtidor
  JOIN combustible c    ON c.id_combustible   = t.id_combustible
 WHERE t.estado = 'APROBADA'
 GROUP BY v.id_vehiculo, v.placa, v.pais_placa, tv.nombre,
          TRUNC(CAST(t.fecha_hora AS DATE)), c.nombre;

-- B3. Consumo por propietario y mes: suma lo cargado por los vehiculos de
--     los que era propietario RUAT en el momento de cada carga
CREATE OR REPLACE VIEW v_consumo_propietario_mes AS
SELECT p.id_persona,
       REGEXP_REPLACE(TRIM(p.nombres || ' ' || p.apellido_paterno || ' ' || p.apellido_materno),
                      ' +', ' ')                 AS propietario,
       p.tipo_documento,
       p.nro_documento,
       TRUNC(CAST(t.fecha_hora AS DATE), 'MM')   AS mes,
       COUNT(DISTINCT cv.id_vehiculo)            AS nro_vehiculos,
       COUNT(*)                                  AS nro_cargas,
       SUM(t.cantidad_total)                     AS cantidad_total
  FROM carga_vehicular cv
  JOIN transaccion t    ON t.id_transaccion = cv.id_transaccion
  JOIN registro_ruat ru ON ru.id_vehiculo   = cv.id_vehiculo
                       AND ru.fecha_alta   <= CAST(t.fecha_hora AS DATE)
                       AND (ru.fecha_baja IS NULL OR CAST(t.fecha_hora AS DATE) < ru.fecha_baja)
  JOIN persona p        ON p.id_persona     = ru.id_persona
 WHERE t.estado = 'APROBADA'
 GROUP BY p.id_persona, p.nombres, p.apellido_paterno, p.apellido_materno,
          p.tipo_documento, p.nro_documento, TRUNC(CAST(t.fecha_hora AS DATE), 'MM');

-- B4. Vehiculos distintos que usa una misma persona (quien carga) por semana
--     (concentracion de compras; examen: "mas de tres vehiculos en una semana")
CREATE OR REPLACE VIEW v_uso_vehiculos_persona_semana AS
SELECT p.id_persona,
       REGEXP_REPLACE(TRIM(p.nombres || ' ' || p.apellido_paterno || ' ' || p.apellido_materno),
                      ' +', ' ')                 AS persona,
       TRUNC(CAST(t.fecha_hora AS DATE), 'IW')   AS semana,
       COUNT(DISTINCT cv.id_vehiculo)            AS nro_vehiculos,
       COUNT(*)                                  AS nro_cargas,
       SUM(t.cantidad_total)                     AS cantidad_total
  FROM transaccion t
  JOIN carga_vehicular cv ON cv.id_transaccion = t.id_transaccion
  JOIN persona p          ON p.id_persona      = t.id_persona
 WHERE t.estado = 'APROBADA'
 GROUP BY p.id_persona, p.nombres, p.apellido_paterno, p.apellido_materno,
          TRUNC(CAST(t.fecha_hora AS DATE), 'IW');

-- B5. Consumo real vs esperado por vehiculo y mes.
--     esperado = CONSUMO_ESPERADO diario (por tipo y cilindrada) * dias del
--     mes transcurridos. supera_50 = 'S' si el real supera en mas de 50 %.
CREATE OR REPLACE VIEW v_consumo_esperado_vs_real AS
SELECT x.id_vehiculo,
       x.placa,
       x.tipo_vehiculo,
       x.categoria_cilindrada,
       x.cilindrada,
       x.mes,
       x.nro_cargas,
       x.consumo_real,
       x.esperado_dia,
       x.dias,
       x.esperado_dia * x.dias                                   AS consumo_esperado,
       x.consumo_real - x.esperado_dia * x.dias                  AS diferencia,
       ROUND((x.consumo_real / NULLIF(x.esperado_dia * x.dias, 0) - 1) * 100, 2) AS porcentaje_sobre_esperado,
       CASE WHEN x.consumo_real > x.esperado_dia * x.dias * 1.5 THEN 'S' ELSE 'N' END AS supera_50
  FROM (SELECT c.id_vehiculo,
               vd.placa,
               vd.tipo_vehiculo,
               vd.categoria_cilindrada,
               vd.cilindrada,
               c.mes,
               c.nro_cargas,
               c.consumo_real,
               pkg_reglas.f_consumo_esperado_dia(c.id_vehiculo, CAST(c.mes AS TIMESTAMP)) AS esperado_dia,
               LEAST(ADD_MONTHS(c.mes, 1), TRUNC(SYSDATE) + 1) - c.mes                 AS dias
          FROM (SELECT cv.id_vehiculo,
                       TRUNC(CAST(t.fecha_hora AS DATE), 'MM') AS mes,
                       COUNT(*)                                AS nro_cargas,
                       SUM(t.cantidad_total)                   AS consumo_real
                  FROM carga_vehicular cv
                  JOIN transaccion t ON t.id_transaccion = cv.id_transaccion
                 WHERE t.estado = 'APROBADA'
                 GROUP BY cv.id_vehiculo, TRUNC(CAST(t.fecha_hora AS DATE), 'MM')) c
          JOIN v_vehiculo_detalle vd ON vd.id_vehiculo = c.id_vehiculo) x;

-- B6. Consumo por tipo de vehiculo y categoria de cilindrada por mes:
--     promedio diario por vehiculo, real vs esperado
CREATE OR REPLACE VIEW v_consumo_cilindrada AS
SELECT tipo_vehiculo,
       NVL(categoria_cilindrada, 'SIN_FICHA')               AS categoria_cilindrada,
       mes,
       COUNT(*)                                             AS nro_vehiculos,
       SUM(consumo_real)                                    AS consumo_real,
       SUM(consumo_esperado)                                AS consumo_esperado,
       SUM(consumo_real) - SUM(consumo_esperado)            AS diferencia,
       ROUND(SUM(consumo_real) / SUM(dias), 2)              AS promedio_diario_real,
       ROUND(SUM(consumo_esperado) / SUM(dias), 2)          AS promedio_diario_esperado,
       SUM(CASE WHEN supera_50 = 'S' THEN 1 ELSE 0 END)     AS vehiculos_sobre_50
  FROM v_consumo_esperado_vs_real
 GROUP BY tipo_vehiculo, NVL(categoria_cilindrada, 'SIN_FICHA'), mes;

-- ============================================================
-- C. ESTACIONES: BALANCE, CONCILIACION, AUTONOMIA, VENTAS
-- ============================================================

-- C1. Balance diario por estacion y combustible desde el saldo inicial:
--     saldo_estimado = saldo_inicial + acumulado(recibido - vendido).
--     Un saldo negativo es una inconsistencia (se vendio mas de lo que habia).
CREATE OR REPLACE VIEW v_balance_estacion_dia AS
WITH mov AS (
  SELECT id_estacion, id_combustible,
         TRUNC(CAST(fecha_hora AS DATE)) AS dia,
         cantidad AS recibido, 0 AS vendido
    FROM recepcion_combustible
  UNION ALL
  SELECT s.id_estacion, t.id_combustible,
         TRUNC(CAST(t.fecha_hora AS DATE)),
         0, t.cantidad_total
    FROM transaccion t
    JOIN surtidor s ON s.id_surtidor = t.id_surtidor
   WHERE t.estado = 'APROBADA'
), por_dia AS (
  SELECT id_estacion, id_combustible, dia,
         SUM(recibido) AS recibido, SUM(vendido) AS vendido
    FROM mov
   GROUP BY id_estacion, id_combustible, dia
)
SELECT te.id_estacion,
       e.nombre                AS estacion,
       te.id_combustible,
       c.nombre                AS combustible,
       pd.dia,
       pd.recibido,
       pd.vendido,
       te.saldo_inicial + SUM(pd.recibido - pd.vendido)
         OVER (PARTITION BY te.id_estacion, te.id_combustible
               ORDER BY pd.dia ROWS UNBOUNDED PRECEDING)  AS saldo_estimado,
       te.capacidad
  FROM por_dia pd
  JOIN tanque_estacion te ON te.id_estacion    = pd.id_estacion
                         AND te.id_combustible = pd.id_combustible
                         AND pd.dia           >= te.fecha_saldo_inicial
  JOIN estacion e         ON e.id_estacion     = te.id_estacion
  JOIN combustible c      ON c.id_combustible  = te.id_combustible;

-- C2. Conciliacion semanal YPFB: disponible (saldo al inicio + recibido)
--     contra vendido. exceso > 0 = se vendio mas de lo disponible.
CREATE OR REPLACE VIEW v_conciliacion_estacion AS
SELECT id_estacion,
       estacion,
       id_combustible,
       combustible,
       semana,
       saldo_inicio,
       recibido,
       vendido,
       saldo_fin,
       saldo_inicio + recibido                                    AS disponible,
       vendido - (saldo_inicio + recibido)                        AS exceso,
       ROUND(vendido / NULLIF(saldo_inicio + recibido, 0) * 100, 2) AS porcentaje_vendido
  FROM (SELECT id_estacion, estacion, id_combustible, combustible,
               TRUNC(dia, 'IW')                                                         AS semana,
               MAX(saldo_estimado - recibido + vendido) KEEP (DENSE_RANK FIRST ORDER BY dia) AS saldo_inicio,
               SUM(recibido)                                                            AS recibido,
               SUM(vendido)                                                             AS vendido,
               MAX(saldo_estimado) KEEP (DENSE_RANK LAST ORDER BY dia)                  AS saldo_fin
          FROM v_balance_estacion_dia
         GROUP BY id_estacion, estacion, id_combustible, combustible, TRUNC(dia, 'IW'));

-- C3. Autonomia estimada: saldo actual / promedio diario vendido en los
--     ultimos 7 dias completos
CREATE OR REPLACE VIEW v_autonomia_estacion AS
SELECT id_estacion,
       estacion,
       id_combustible,
       combustible,
       capacidad,
       ultimo_movimiento,
       saldo_actual,
       ROUND(saldo_actual / capacidad * 100, 2)            AS porcentaje_ocupacion,
       ROUND(promedio_diario_7d, 3)                        AS promedio_diario_7d,
       ROUND(saldo_actual / NULLIF(promedio_diario_7d, 0), 1) AS dias_autonomia
  FROM (SELECT id_estacion, estacion, id_combustible, combustible, capacidad,
               MAX(dia)                                                AS ultimo_movimiento,
               MAX(saldo_estimado) KEEP (DENSE_RANK LAST ORDER BY dia) AS saldo_actual,
               SUM(CASE WHEN dia >= TRUNC(SYSDATE) - 7 AND dia < TRUNC(SYSDATE)
                        THEN vendido ELSE 0 END) / 7                   AS promedio_diario_7d
          FROM v_balance_estacion_dia
         WHERE dia <= TRUNC(SYSDATE)
         GROUP BY id_estacion, estacion, id_combustible, combustible, capacidad);

-- C4. Ventas semanales por estacion vs su promedio de las 4 semanas previas
--     (incrementos inusuales respecto al historico)
CREATE OR REPLACE VIEW v_variacion_ventas_estacion AS
SELECT id_estacion,
       estacion,
       combustible,
       semana,
       vendido,
       ROUND(promedio_4_semanas, 3)                                 AS promedio_4_semanas,
       ROUND((vendido / NULLIF(promedio_4_semanas, 0) - 1) * 100, 2) AS variacion_porcentaje
  FROM (SELECT e.id_estacion,
               e.nombre                                   AS estacion,
               c.nombre                                   AS combustible,
               w.semana,
               w.vendido,
               AVG(w.vendido) OVER (PARTITION BY w.id_estacion, w.id_combustible
                                    ORDER BY w.semana
                                    ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS promedio_4_semanas
          FROM (SELECT s.id_estacion, t.id_combustible,
                       TRUNC(CAST(t.fecha_hora AS DATE), 'IW') AS semana,
                       SUM(t.cantidad_total)                   AS vendido
                  FROM transaccion t
                  JOIN surtidor s ON s.id_surtidor = t.id_surtidor
                 WHERE t.estado = 'APROBADA'
                 GROUP BY s.id_estacion, t.id_combustible, TRUNC(CAST(t.fecha_hora AS DATE), 'IW')) w
          JOIN estacion e    ON e.id_estacion    = w.id_estacion
          JOIN combustible c ON c.id_combustible = w.id_combustible);

-- C5. Rendimiento operativo por estacion, combustible y mes
CREATE OR REPLACE VIEW v_rendimiento_estacion AS
SELECT id_estacion,
       estacion,
       departamento,
       combustible,
       TRUNC(CAST(fecha_hora AS DATE), 'MM')                              AS mes,
       SUM(CASE WHEN estado = 'APROBADA'  THEN 1 ELSE 0 END)              AS operaciones_aprobadas,
       SUM(CASE WHEN estado = 'BLOQUEADA' THEN 1 ELSE 0 END)              AS operaciones_bloqueadas,
       SUM(CASE WHEN estado = 'APROBADA'  THEN cantidad_total ELSE 0 END) AS cantidad_despachada,
       SUM(cantidad_subvencionada)                                        AS cantidad_subvencionada,
       SUM(cantidad_internacional)                                        AS cantidad_internacional,
       SUM(monto_bs)                                                      AS monto_bs
  FROM v_historial_carga
 GROUP BY id_estacion, estacion, departamento, combustible, TRUNC(CAST(fecha_hora AS DATE), 'MM');

-- ============================================================
-- D. ALERTAS
-- ============================================================

-- D1. Todas las alertas con su contexto. estado_gestion usa el vocabulario
--     del enunciado: PENDIENTE / ATENDIDA (confirmada) / DESCARTADA.
--     orden_gravedad: 1 = ALTA, 2 = MEDIA, 3 = BAJA.
CREATE OR REPLACE VIEW v_alerta_detalle AS
SELECT a.id_alerta,
       tr.codigo                AS codigo_regla,
       tr.familia,
       tr.evaluacion,
       r.gravedad,
       CASE r.gravedad WHEN 'ALTA' THEN 1 WHEN 'MEDIA' THEN 2 WHEN 'BAJA' THEN 3 END AS orden_gravedad,
       CASE WHEN tr.familia = 'ANOMALIA' AND tr.evaluacion = 'TRANSACCION'
                 AND r.gravedad = 'ALTA' THEN 'S' ELSE 'N' END AS bloqueante,
       a.estado_revision,
       a.resultado_revision,
       CASE WHEN a.estado_revision = 'PENDIENTE'          THEN 'PENDIENTE'
            WHEN a.resultado_revision = 'CONFIRMADA'      THEN 'ATENDIDA'
            ELSE 'DESCARTADA' END                         AS estado_gestion,
       a.fecha_deteccion,
       a.valor_observado,
       a.valor_umbral,
       a.periodo_inicio,
       a.id_transaccion,
       t.nro_ticket,
       t.estado                 AS estado_transaccion,
       t.fecha_hora             AS fecha_hora_transaccion,
       e.id_estacion,
       e.nombre                 AS estacion,
       e.es_fronteriza,
       d.nombre                 AS departamento,
       cv.id_vehiculo,
       v.placa,
       t.id_persona,
       ua.username              AS revisado_por,
       a.fecha_revision,
       a.observacion_revision,
       a.descripcion
  FROM alerta a
  JOIN regla r                 ON r.id_regla        = a.id_regla
  JOIN tipo_regla tr           ON tr.id_tipo_regla  = r.id_tipo_regla
  LEFT JOIN transaccion t      ON t.id_transaccion  = a.id_transaccion
  LEFT JOIN surtidor s         ON s.id_surtidor     = t.id_surtidor
  LEFT JOIN estacion e         ON e.id_estacion     = COALESCE(a.id_estacion, s.id_estacion)
  LEFT JOIN municipio m        ON m.id_municipio    = e.id_municipio
  LEFT JOIN departamento d     ON d.id_departamento = m.id_departamento
  LEFT JOIN carga_vehicular cv ON cv.id_transaccion = a.id_transaccion
  LEFT JOIN vehiculo v         ON v.id_vehiculo     = cv.id_vehiculo
  LEFT JOIN usuario_app ua     ON ua.id_usuario     = a.id_usuario_revision;

-- D2. Alertas pendientes, ALTA primero y mas antiguas primero
CREATE OR REPLACE VIEW v_alertas_pendientes AS
SELECT *
  FROM v_alerta_detalle
 WHERE estado_revision = 'PENDIENTE'
 ORDER BY orden_gravedad, fecha_deteccion;

-- D3. Vehiculos reincidentes: alertas en mas de un dia distinto
CREATE OR REPLACE VIEW v_alertas_reincidentes AS
SELECT id_vehiculo,
       placa,
       COUNT(*)                                                   AS nro_alertas,
       COUNT(DISTINCT TRUNC(CAST(fecha_hora_transaccion AS DATE))) AS dias_con_alerta,
       COUNT(DISTINCT codigo_regla)                               AS reglas_distintas,
       SUM(CASE WHEN estado_gestion = 'PENDIENTE'  THEN 1 ELSE 0 END) AS pendientes,
       SUM(CASE WHEN estado_gestion = 'ATENDIDA'   THEN 1 ELSE 0 END) AS atendidas,
       SUM(CASE WHEN estado_gestion = 'DESCARTADA' THEN 1 ELSE 0 END) AS descartadas,
       SUM(CASE WHEN estado_transaccion = 'BLOQUEADA' THEN 1 ELSE 0 END) AS en_cargas_bloqueadas,
       MIN(fecha_deteccion)                                       AS primera_alerta,
       MAX(fecha_deteccion)                                       AS ultima_alerta
  FROM v_alerta_detalle
 WHERE id_vehiculo IS NOT NULL
 GROUP BY id_vehiculo, placa
HAVING COUNT(DISTINCT TRUNC(CAST(fecha_hora_transaccion AS DATE))) > 1;

-- D4. Comportamiento temporal: dia de semana y hora de las operaciones
--     con alerta
CREATE OR REPLACE VIEW v_alertas_temporal AS
SELECT TRUNC(CAST(fecha_hora_transaccion AS DATE))
         - TRUNC(CAST(fecha_hora_transaccion AS DATE), 'IW') + 1 AS dia_semana,
       EXTRACT(HOUR FROM fecha_hora_transaccion)                AS hora,
       codigo_regla,
       gravedad,
       COUNT(*)                                                 AS nro_alertas,
       COUNT(DISTINCT id_transaccion)                           AS nro_operaciones,
       SUM(CASE WHEN estado_transaccion = 'BLOQUEADA' THEN 1 ELSE 0 END) AS en_cargas_bloqueadas
  FROM v_alerta_detalle
 WHERE id_transaccion IS NOT NULL
 GROUP BY TRUNC(CAST(fecha_hora_transaccion AS DATE))
            - TRUNC(CAST(fecha_hora_transaccion AS DATE), 'IW') + 1,
          EXTRACT(HOUR FROM fecha_hora_transaccion),
          codigo_regla, gravedad;

-- D5. Resumen de anomalias por mes y regla, segun su gestion
CREATE OR REPLACE VIEW v_resumen_anomalias AS
SELECT TRUNC(CAST(fecha_deteccion AS DATE), 'MM')                    AS mes,
       codigo_regla,
       gravedad,
       bloqueante,
       COUNT(*)                                                     AS total,
       SUM(CASE WHEN estado_gestion = 'PENDIENTE'  THEN 1 ELSE 0 END) AS pendientes,
       SUM(CASE WHEN estado_gestion = 'ATENDIDA'   THEN 1 ELSE 0 END) AS atendidas,
       SUM(CASE WHEN estado_gestion = 'DESCARTADA' THEN 1 ELSE 0 END) AS descartadas,
       SUM(CASE WHEN estado_transaccion = 'BLOQUEADA' THEN 1 ELSE 0 END) AS en_cargas_bloqueadas
  FROM v_alerta_detalle
 GROUP BY TRUNC(CAST(fecha_deteccion AS DATE), 'MM'), codigo_regla, gravedad, bloqueante;

-- D6. Ranking de vehiculos con mas alertas
CREATE OR REPLACE VIEW v_ranking_vehiculos_alertas AS
SELECT id_vehiculo,
       placa,
       COUNT(*)                                              AS nro_alertas,
       SUM(CASE WHEN gravedad = 'ALTA' THEN 1 ELSE 0 END)    AS nro_alertas_altas,
       SUM(CASE WHEN estado_transaccion = 'BLOQUEADA' THEN 1 ELSE 0 END) AS en_cargas_bloqueadas,
       MAX(fecha_deteccion)                                  AS ultima_alerta,
       DENSE_RANK() OVER (ORDER BY COUNT(*) DESC)            AS puesto
  FROM v_alerta_detalle
 WHERE id_vehiculo IS NOT NULL
 GROUP BY id_vehiculo, placa
 ORDER BY nro_alertas DESC, nro_alertas_altas DESC, ultima_alerta DESC;

-- ============================================================
-- E. CALIDAD
-- ============================================================

-- E1. Reclamos por estacion, combustible, lote y mes
CREATE OR REPLACE VIEW v_reclamos_calidad AS
SELECT e.id_estacion,
       e.nombre                                   AS estacion,
       c.nombre                                   AS combustible,
       rc.nro_lote,
       TRUNC(CAST(q.fecha_hora AS DATE), 'MM')    AS mes,
       q.tipo_reclamo,
       COUNT(*)                                   AS nro_reclamos,
       SUM(CASE WHEN q.estado <> 'CERRADO' THEN 1 ELSE 0 END)     AS abiertos,
       SUM(CASE WHEN q.resultado = 'CONFIRMADO' THEN 1 ELSE 0 END) AS confirmados,
       SUM(CASE WHEN q.resultado = 'DESCARTADO' THEN 1 ELSE 0 END) AS descartados
  FROM reclamo_calidad q
  JOIN estacion e                     ON e.id_estacion    = q.id_estacion
  JOIN combustible c                  ON c.id_combustible = q.id_combustible
  LEFT JOIN recepcion_combustible rc  ON rc.id_recepcion  = q.id_recepcion
 GROUP BY e.id_estacion, e.nombre, c.nombre, rc.nro_lote,
          TRUNC(CAST(q.fecha_hora AS DATE), 'MM'), q.tipo_reclamo;

-- ============================================================
-- F. VISTAS MATERIALIZADAS (dashboard: agregados pesados precalculados)
-- Refresco completo bajo demanda: al terminar la carga de datos y por
-- un job programado (seguridad/operacion). Se borran y recrean para que
-- el script sea re-ejecutable.
-- ============================================================
BEGIN
  FOR m IN (SELECT 'MV_VENTAS_ESTACION_DIA' AS n FROM dual
            UNION ALL SELECT 'MV_CONSUMO_VEHICULO_MES' FROM dual) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW ' || m.n;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE <> -12003 THEN  -- ORA-12003: la vista materializada no existe
          RAISE;
        END IF;
    END;
  END LOOP;
END;
/

-- F1. Ventas diarias por estacion y combustible
CREATE MATERIALIZED VIEW mv_ventas_estacion_dia
  BUILD IMMEDIATE
  REFRESH COMPLETE ON DEMAND
AS
SELECT s.id_estacion,
       t.id_combustible,
       TRUNC(CAST(t.fecha_hora AS DATE)) AS dia,
       COUNT(*)                          AS nro_operaciones,
       SUM(t.cantidad_total)             AS vendido
  FROM transaccion t
  JOIN surtidor s ON s.id_surtidor = t.id_surtidor
 WHERE t.estado = 'APROBADA'
 GROUP BY s.id_estacion, t.id_combustible, TRUNC(CAST(t.fecha_hora AS DATE));

-- F2. Consumo mensual por vehiculo
CREATE MATERIALIZED VIEW mv_consumo_vehiculo_mes
  BUILD IMMEDIATE
  REFRESH COMPLETE ON DEMAND
AS
SELECT cv.id_vehiculo,
       TRUNC(CAST(t.fecha_hora AS DATE), 'MM') AS mes,
       COUNT(*)                                AS nro_cargas,
       SUM(t.cantidad_total)                   AS consumo
  FROM carga_vehicular cv
  JOIN transaccion t ON t.id_transaccion = cv.id_transaccion
 WHERE t.estado = 'APROBADA'
 GROUP BY cv.id_vehiculo, TRUNC(CAST(t.fecha_hora AS DATE), 'MM');

-- ------------------------------------------------------------
-- Verificacion: las 22 vistas y las 2 vistas materializadas existen,
-- son validas y se pueden consultar (aunque devuelvan 0 filas antes
-- de cargar datos).
-- Se usa all_* + esquema actual para que funcione como SYS (arranque
-- del contenedor) o conectado como combustible.
-- ------------------------------------------------------------
DECLARE
  l_n      NUMBER;
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
BEGIN
  FOR r IN (SELECT object_name FROM all_objects
             WHERE owner = l_schema
               AND object_type IN ('VIEW', 'MATERIALIZED VIEW')
             ORDER BY object_type DESC, object_name) LOOP
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || l_schema || '.' || r.object_name INTO l_n;
    DBMS_OUTPUT.PUT_LINE(RPAD(r.object_name, 34) || l_n || ' filas');
  END LOOP;

  SELECT COUNT(*) INTO l_n FROM all_views WHERE owner = l_schema;
  IF l_n <> 22 THEN
    RAISE_APPLICATION_ERROR(-20999, '05_vistas: se esperaban 22 vistas y hay ' || l_n);
  END IF;
  SELECT COUNT(*) INTO l_n FROM all_mviews WHERE owner = l_schema;
  IF l_n <> 2 THEN
    RAISE_APPLICATION_ERROR(-20999, '05_vistas: se esperaban 2 vistas materializadas y hay ' || l_n);
  END IF;
  SELECT COUNT(*) INTO l_n FROM all_objects
   WHERE owner = l_schema AND object_type IN ('VIEW', 'MATERIALIZED VIEW') AND status <> 'VALID';
  IF l_n > 0 THEN
    RAISE_APPLICATION_ERROR(-20999, '05_vistas: hay ' || l_n || ' vistas invalidas');
  END IF;
  DBMS_OUTPUT.PUT_LINE('OK    22 vistas y 2 vistas materializadas validas');
END;
/
