-- ============================================================
-- 04_vistas.sql
-- Vistas de consulta (plan de implementacion, seccion 4).
-- Re-ejecutable: todas usan CREATE OR REPLACE VIEW.
-- Depende solo de las tablas de 02_tablas.sql.
-- Autor: <nombre>   Fecha: 2026-11-18
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- Convencion de vigencia: intervalo semiabierto [fecha_inicio, fecha_fin).
-- fecha_fin NULL = vigente.

-- ------------------------------------------------------------
-- 1. Reglas vigentes en este momento
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_regla_vigente AS
SELECT r.id_regla,
       tr.codigo           AS codigo_regla,
       tr.familia,
       tv.nombre           AS tipo_vehiculo,
       c.nombre            AS combustible,
       p.codigo            AS periodo,
       r.solo_fronteriza,
       r.valor,
       r.valor_secundario,
       r.gravedad,
       r.fecha_inicio
  FROM regla r
  JOIN tipo_regla tr         ON tr.id_tipo_regla    = r.id_tipo_regla
  LEFT JOIN tipo_vehiculo tv ON tv.id_tipo_vehiculo = r.id_tipo_vehiculo
  LEFT JOIN combustible c    ON c.id_combustible    = r.id_combustible
  LEFT JOIN tipo_periodo p   ON p.id_tipo_periodo   = r.id_tipo_periodo
 WHERE r.fecha_inicio <= SYSDATE
   AND (r.fecha_fin IS NULL OR SYSDATE < r.fecha_fin);

-- ------------------------------------------------------------
-- 2. Precio vigente por combustible y tipo de precio
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 3. Beneficios vigentes (vehiculo - titular)
-- ------------------------------------------------------------
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
       tr.codigo                            AS codigo_regla,
       r.valor                              AS max_vehiculos_persona,
       b.fecha_inicio
  FROM registro_beneficio b
  JOIN vehiculo v    ON v.id_vehiculo     = b.id_vehiculo
  JOIN persona p     ON p.id_persona      = b.id_persona
  JOIN regla r       ON r.id_regla        = b.id_regla
  JOIN tipo_regla tr ON tr.id_tipo_regla  = r.id_tipo_regla
 WHERE b.fecha_inicio <= SYSDATE
   AND (b.fecha_fin IS NULL OR SYSDATE < b.fecha_fin);

-- ------------------------------------------------------------
-- 4. Historial de cargas: una fila por transaccion, aplanada
--    (cantidad subvencionada / internacional y monto salen del detalle)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_historial_carga AS
SELECT t.id_transaccion,
       t.fecha_hora,
       t.tipo_transaccion,
       e.id_estacion,
       e.nombre            AS estacion,
       e.es_fronteriza,
       m.nombre            AS municipio,
       d.nombre            AS departamento,
       s.codigo            AS surtidor,
       v.id_vehiculo,
       v.placa,
       v.pais_placa,
       c.nombre            AS combustible,
       u.simbolo           AS unidad,
       p.id_persona,
       REGEXP_REPLACE(TRIM(p.nombres || ' ' || p.apellido_paterno || ' ' || p.apellido_materno),
                      ' +', ' ')            AS persona,
       t.huella_verificada,
       t.cantidad_total,
       NVL(dt.cantidad_subvencionada, 0)    AS cantidad_subvencionada,
       NVL(dt.cantidad_internacional, 0)    AS cantidad_internacional,
       NVL(dt.monto_bs, 0)                  AS monto_bs,
       cb.nro_recipientes
  FROM transaccion t
  JOIN surtidor s            ON s.id_surtidor    = t.id_surtidor
  JOIN estacion e            ON e.id_estacion    = s.id_estacion
  JOIN municipio m           ON m.id_municipio   = e.id_municipio
  JOIN departamento d        ON d.id_departamento = m.id_departamento
  JOIN combustible c         ON c.id_combustible = t.id_combustible
  JOIN unidad_medida u       ON u.id_unidad      = c.id_unidad
  LEFT JOIN persona p        ON p.id_persona     = t.id_persona
  LEFT JOIN carga_vehicular cv ON cv.id_transaccion = t.id_transaccion
  LEFT JOIN vehiculo v       ON v.id_vehiculo    = cv.id_vehiculo
  LEFT JOIN compra_bidon cb  ON cb.id_transaccion = t.id_transaccion
  LEFT JOIN (
        SELECT dtr.id_transaccion,
               SUM(CASE WHEN pc.tipo_precio = 'SUBVENCIONADO' THEN dtr.cantidad ELSE 0 END) AS cantidad_subvencionada,
               SUM(CASE WHEN pc.tipo_precio = 'INTERNACIONAL' THEN dtr.cantidad ELSE 0 END) AS cantidad_internacional,
               SUM(dtr.cantidad * pc.precio_unitario)                                      AS monto_bs
          FROM detalle_transaccion dtr
          JOIN precio_combustible pc ON pc.id_precio = dtr.id_precio
         GROUP BY dtr.id_transaccion
       ) dt ON dt.id_transaccion = t.id_transaccion;

-- ------------------------------------------------------------
-- 5. Consumo por vehiculo, dia y combustible (solo cargas vehiculares)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_consumo_vehiculo_dia AS
SELECT v.id_vehiculo,
       v.placa,
       v.pais_placa,
       TRUNC(t.fecha_hora)            AS dia,
       c.nombre                       AS combustible,
       COUNT(*)                       AS nro_cargas,
       COUNT(DISTINCT s.id_estacion)  AS nro_estaciones,
       SUM(t.cantidad_total)          AS cantidad_total
  FROM carga_vehicular cv
  JOIN transaccion t ON t.id_transaccion = cv.id_transaccion
  JOIN vehiculo v    ON v.id_vehiculo    = cv.id_vehiculo
  JOIN surtidor s    ON s.id_surtidor    = t.id_surtidor
  JOIN combustible c ON c.id_combustible = t.id_combustible
 GROUP BY v.id_vehiculo, v.placa, v.pais_placa, TRUNC(t.fecha_hora), c.nombre;

-- ------------------------------------------------------------
-- 6. Todas las alertas con su contexto
--    La estacion sale de la alerta (conciliacion) o de la transaccion.
--    orden_gravedad: 1 = ALTA, 2 = MEDIA, 3 = BAJA (para ordenar).
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_alerta_detalle AS
SELECT a.id_alerta,
       tr.codigo                AS codigo_regla,
       tr.familia,
       r.gravedad,
       CASE r.gravedad WHEN 'ALTA' THEN 1 WHEN 'MEDIA' THEN 2 WHEN 'BAJA' THEN 3 END AS orden_gravedad,
       a.estado_revision,
       a.resultado_revision,
       a.fecha_deteccion,
       a.fecha_revision,
       a.id_transaccion,
       t.fecha_hora             AS fecha_hora_transaccion,
       e.id_estacion,
       e.nombre                 AS estacion,
       e.es_fronteriza,
       v.placa,
       a.descripcion
  FROM alerta a
  JOIN regla r                 ON r.id_regla       = a.id_regla
  JOIN tipo_regla tr           ON tr.id_tipo_regla = r.id_tipo_regla
  LEFT JOIN transaccion t      ON t.id_transaccion = a.id_transaccion
  LEFT JOIN surtidor s         ON s.id_surtidor    = t.id_surtidor
  LEFT JOIN estacion e         ON e.id_estacion    = COALESCE(a.id_estacion, s.id_estacion)
  LEFT JOIN carga_vehicular cv ON cv.id_transaccion = a.id_transaccion
  LEFT JOIN vehiculo v         ON v.id_vehiculo    = cv.id_vehiculo;

-- ------------------------------------------------------------
-- 7. Alertas pendientes, ALTA primero y mas antiguas primero
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_alertas_pendientes AS
SELECT id_alerta, codigo_regla, familia, gravedad, orden_gravedad, estado_revision,
       resultado_revision, fecha_deteccion, fecha_revision, id_transaccion,
       fecha_hora_transaccion, id_estacion, estacion, es_fronteriza, placa, descripcion
  FROM v_alerta_detalle
 WHERE estado_revision = 'PENDIENTE'
 ORDER BY orden_gravedad, fecha_deteccion;

-- ------------------------------------------------------------
-- 8. Conciliacion YPFB: recibido vs vendido por estacion, combustible
--    y semana ISO (lunes). diferencia = recibido - vendido.
--    porcentaje_vendido = vendido / recibido * 100 (NULL si no hubo recepcion).
--    Limite conocido: el modelo no guarda stock inicial.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_conciliacion_estacion AS
SELECT e.id_estacion,
       e.nombre                                   AS estacion,
       c.id_combustible,
       c.nombre                                   AS combustible,
       x.semana,
       x.recibido,
       x.vendido,
       x.recibido - x.vendido                     AS diferencia,
       ROUND(x.vendido / NULLIF(x.recibido, 0) * 100, 2) AS porcentaje_vendido
  FROM (
        SELECT COALESCE(rc.id_estacion, vn.id_estacion)       AS id_estacion,
               COALESCE(rc.id_combustible, vn.id_combustible) AS id_combustible,
               COALESCE(rc.semana, vn.semana)                 AS semana,
               NVL(rc.recibido, 0)                            AS recibido,
               NVL(vn.vendido, 0)                             AS vendido
          FROM (
                SELECT id_estacion, id_combustible,
                       TRUNC(CAST(fecha_hora AS DATE), 'IW') AS semana,
                       SUM(cantidad)                         AS recibido
                  FROM recepcion_combustible
                 GROUP BY id_estacion, id_combustible, TRUNC(CAST(fecha_hora AS DATE), 'IW')
               ) rc
          FULL OUTER JOIN (
                SELECT s.id_estacion, t.id_combustible,
                       TRUNC(CAST(t.fecha_hora AS DATE), 'IW') AS semana,
                       SUM(t.cantidad_total)                   AS vendido
                  FROM transaccion t
                  JOIN surtidor s ON s.id_surtidor = t.id_surtidor
                 GROUP BY s.id_estacion, t.id_combustible, TRUNC(CAST(t.fecha_hora AS DATE), 'IW')
               ) vn
            ON rc.id_estacion = vn.id_estacion
           AND rc.id_combustible = vn.id_combustible
           AND rc.semana = vn.semana
       ) x
  JOIN estacion e    ON e.id_estacion    = x.id_estacion
  JOIN combustible c ON c.id_combustible = x.id_combustible;

-- ------------------------------------------------------------
-- 9. Ranking de vehiculos con mas alertas (alertas de transaccion)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_ranking_vehiculos_alertas AS
SELECT v.id_vehiculo,
       v.placa,
       v.pais_placa,
       COUNT(*)                                          AS nro_alertas,
       SUM(CASE WHEN r.gravedad = 'ALTA' THEN 1 ELSE 0 END) AS nro_alertas_altas,
       MAX(a.fecha_deteccion)                            AS ultima_alerta
  FROM alerta a
  JOIN carga_vehicular cv ON cv.id_transaccion = a.id_transaccion
  JOIN vehiculo v         ON v.id_vehiculo     = cv.id_vehiculo
  JOIN regla r            ON r.id_regla        = a.id_regla
 GROUP BY v.id_vehiculo, v.placa, v.pais_placa
 ORDER BY nro_alertas DESC, nro_alertas_altas DESC, ultima_alerta DESC;

-- ------------------------------------------------------------
-- Verificacion: las 9 vistas deben existir y poder consultarse
-- (aunque devuelvan cero filas antes de cargar datos).
-- ------------------------------------------------------------
-- Se usa all_views + esquema actual (y no user_views) para que funcione
-- tanto si el script corre como SYS (arranque del contenedor, con
-- CURRENT_SCHEMA = combustible) como conectado directamente como combustible.
DECLARE
  l_n      NUMBER;
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
BEGIN
  FOR r IN (SELECT view_name FROM all_views
             WHERE owner = l_schema AND view_name LIKE 'V\_%' ESCAPE '\'
             ORDER BY view_name) LOOP
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || l_schema || '.' || r.view_name INTO l_n;
    DBMS_OUTPUT.PUT_LINE(RPAD(r.view_name, 32) || l_n || ' filas');
  END LOOP;
  SELECT COUNT(*) INTO l_n FROM all_views
   WHERE owner = l_schema AND view_name LIKE 'V\_%' ESCAPE '\';
  IF l_n <> 9 THEN
    RAISE_APPLICATION_ERROR(-20999, '04_vistas: se esperaban 9 vistas y hay ' || l_n);
  END IF;
END;
/
