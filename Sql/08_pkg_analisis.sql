-- ============================================================
-- 08_pkg_analisis.sql
-- Paquete pkg_analisis: consumo acumulado y esperado, analisis del
-- historial de un vehiculo, generacion de alertas por exceso de consumo,
-- reporte estadistico, clasificacion de alertas y refresco de vistas
-- materializadas (ejemplos 1, 2, 3, 5, 8 y 10 del enunciado, 3.9).
-- Re-ejecutable (CREATE OR REPLACE). El paquete NO hace COMMIT ni
-- ROLLBACK, salvo p_refrescar_vistas_materializadas (DBMS_MVIEW.REFRESH
-- confirma la transaccion por su cuenta).
-- Rangos de fechas: semiabiertos [p_desde, p_hasta).
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ------------------------------------------------------------
-- Especificacion (contrato del plan v2, seccion 5.4)
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE pkg_analisis AS
  -- Ejemplo 1: cantidad APROBADA cargada por el vehiculo en [p_desde, p_hasta)
  FUNCTION f_consumo_acumulado(p_id_vehiculo IN NUMBER, p_desde IN DATE, p_hasta IN DATE) RETURN NUMBER;

  -- Suma del consumo esperado diario (regla CONSUMO_ESPERADO vigente cada
  -- dia) en [p_desde, p_hasta). NULL si el vehiculo no tiene consumo esperado.
  FUNCTION f_consumo_esperado(p_id_vehiculo IN NUMBER, p_desde IN DATE, p_hasta IN DATE) RETURN NUMBER;

  -- Ejemplo 5: real - esperado (positivo = consumio de mas). NULL sin esperado.
  FUNCTION f_diferencia_consumo(p_id_vehiculo IN NUMBER, p_desde IN DATE, p_hasta IN DATE) RETURN NUMBER;

  -- Ejemplo 2: historial dia por dia (dia, cargas_aprobadas, cargas_bloqueadas,
  -- estaciones, cantidad, esperado_dia, alertas). Con p_imprimir = 'S'
  -- ademas escribe un resumen con DBMS_OUTPUT.
  PROCEDURE p_analizar_historial(
    p_id_vehiculo IN  NUMBER,
    p_desde       IN  DATE,
    p_hasta       IN  DATE,
    p_resultado   OUT SYS_REFCURSOR,
    p_imprimir    IN  CHAR DEFAULT 'S');

  -- Ejemplo 3: reevalua EXCESO_VOLUMEN y CONSUMO_VS_ESPERADO sobre las cargas
  -- APROBADA del rango (por ejemplo, despues de crear una version nueva de
  -- la regla) y agrega solo las alertas que falten.
  PROCEDURE p_generar_alertas_exceso_consumo(
    p_desde  IN  DATE,
    p_hasta  IN  DATE,
    p_nuevas OUT NUMBER);

  -- Ejemplo 8: indicadores del periodo (orden, indicador, valor)
  PROCEDURE p_reporte_estadistico(
    p_desde     IN  DATE,
    p_hasta     IN  DATE,
    p_resultado OUT SYS_REFCURSOR);

  -- Ejemplo 10: DESCARTADA (falso positivo) o BAJA / MEDIA / ALTA segun la
  -- gravedad de la regla, subiendo un nivel (hasta CRITICA) si hay
  -- reincidencia: el mismo vehiculo con 2 o mas alertas en los 30 dias
  -- previos, o la misma estacion con otra alerta en las 8 semanas previas.
  FUNCTION f_clasificar_alerta(p_id_alerta IN NUMBER) RETURN VARCHAR2;

  -- Refresco completo de las vistas materializadas (hace COMMIT)
  PROCEDURE p_refrescar_vistas_materializadas;
END pkg_analisis;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Cuerpo
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE BODY pkg_analisis AS

  FUNCTION fmt(p_n IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_n IS NULL THEN
      RETURN '-';
    END IF;
    RETURN RTRIM(RTRIM(TO_CHAR(ROUND(p_n, 3), 'FM9999999999990.000'), '0'), '.');
  END fmt;

  FUNCTION f_consumo_acumulado(p_id_vehiculo IN NUMBER, p_desde IN DATE, p_hasta IN DATE) RETURN NUMBER IS
    l_n NUMBER;
  BEGIN
    SELECT NVL(SUM(t.cantidad_total), 0)
      INTO l_n
      FROM carga_vehicular cv
      JOIN transaccion t ON t.id_transaccion = cv.id_transaccion
     WHERE cv.id_vehiculo = p_id_vehiculo
       AND t.estado       = 'APROBADA'
       AND t.fecha_hora  >= p_desde
       AND t.fecha_hora   < p_hasta;
    RETURN l_n;
  END f_consumo_acumulado;

  FUNCTION f_consumo_esperado(p_id_vehiculo IN NUMBER, p_desde IN DATE, p_hasta IN DATE) RETURN NUMBER IS
    l_total NUMBER := 0;
    l_hay   BOOLEAN := FALSE;
    l_dia   DATE := TRUNC(p_desde);
    l_esp   NUMBER;
  BEGIN
    WHILE l_dia < p_hasta LOOP
      l_esp := pkg_reglas.f_consumo_esperado_dia(p_id_vehiculo, CAST(l_dia AS TIMESTAMP));
      IF l_esp IS NOT NULL THEN
        l_total := l_total + l_esp;
        l_hay   := TRUE;
      END IF;
      l_dia := l_dia + 1;
    END LOOP;
    RETURN CASE WHEN l_hay THEN l_total END;
  END f_consumo_esperado;

  FUNCTION f_diferencia_consumo(p_id_vehiculo IN NUMBER, p_desde IN DATE, p_hasta IN DATE) RETURN NUMBER IS
    l_esp NUMBER := f_consumo_esperado(p_id_vehiculo, p_desde, p_hasta);
  BEGIN
    IF l_esp IS NULL THEN
      RETURN NULL;
    END IF;
    RETURN f_consumo_acumulado(p_id_vehiculo, p_desde, p_hasta) - l_esp;
  END f_diferencia_consumo;

  PROCEDURE p_analizar_historial(
    p_id_vehiculo IN  NUMBER,
    p_desde       IN  DATE,
    p_hasta       IN  DATE,
    p_resultado   OUT SYS_REFCURSOR,
    p_imprimir    IN  CHAR DEFAULT 'S') IS
    l_placa    vehiculo.placa%TYPE;
    l_real     NUMBER;
    l_esperado NUMBER;
    l_dias     NUMBER;
  BEGIN
    BEGIN
      SELECT placa INTO l_placa FROM vehiculo WHERE id_vehiculo = p_id_vehiculo;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20003, 'Vehiculo inexistente: ' || p_id_vehiculo);
    END;

    OPEN p_resultado FOR
      SELECT d.dia,
             d.cargas_aprobadas,
             d.cargas_bloqueadas,
             d.estaciones,
             d.cantidad,
             pkg_reglas.f_consumo_esperado_dia(p_id_vehiculo, CAST(d.dia AS TIMESTAMP)) AS esperado_dia,
             d.alertas
        FROM (SELECT TRUNC(CAST(t.fecha_hora AS DATE))                                   AS dia,
                     SUM(CASE WHEN t.estado = 'APROBADA'  THEN 1 ELSE 0 END)             AS cargas_aprobadas,
                     SUM(CASE WHEN t.estado = 'BLOQUEADA' THEN 1 ELSE 0 END)             AS cargas_bloqueadas,
                     COUNT(DISTINCT s.id_estacion)                                       AS estaciones,
                     SUM(CASE WHEN t.estado = 'APROBADA' THEN t.cantidad_total ELSE 0 END) AS cantidad,
                     SUM(NVL(al.n, 0))                                                   AS alertas
                FROM carga_vehicular cv
                JOIN transaccion t ON t.id_transaccion = cv.id_transaccion
                JOIN surtidor s    ON s.id_surtidor    = t.id_surtidor
                LEFT JOIN (SELECT id_transaccion, COUNT(*) AS n
                             FROM alerta
                            WHERE id_transaccion IS NOT NULL
                            GROUP BY id_transaccion) al ON al.id_transaccion = t.id_transaccion
               WHERE cv.id_vehiculo = p_id_vehiculo
                 AND t.fecha_hora  >= p_desde
                 AND t.fecha_hora   < p_hasta
               GROUP BY TRUNC(CAST(t.fecha_hora AS DATE))) d
       ORDER BY d.dia;

    IF p_imprimir = 'S' THEN
      l_real     := f_consumo_acumulado(p_id_vehiculo, p_desde, p_hasta);
      l_esperado := f_consumo_esperado(p_id_vehiculo, p_desde, p_hasta);
      l_dias     := p_hasta - p_desde;
      DBMS_OUTPUT.PUT_LINE('Historial de ' || l_placa || ' del ' || TO_CHAR(p_desde, 'YYYY-MM-DD')
                           || ' al ' || TO_CHAR(p_hasta - 1, 'YYYY-MM-DD') || ' (' || fmt(l_dias) || ' dias)');
      DBMS_OUTPUT.PUT_LINE('  Consumo real:     ' || fmt(l_real)
                           || ' (promedio diario ' || fmt(l_real / NULLIF(l_dias, 0)) || ')');
      DBMS_OUTPUT.PUT_LINE('  Consumo esperado: ' || fmt(l_esperado)
                           || ' (diferencia ' || fmt(l_real - l_esperado) || ', '
                           || fmt(ROUND((l_real / NULLIF(l_esperado, 0) - 1) * 100, 1)) || ' %)');
      FOR r IN (SELECT tr.codigo, COUNT(*) AS n
                  FROM alerta a
                  JOIN transaccion t      ON t.id_transaccion  = a.id_transaccion
                  JOIN carga_vehicular cv ON cv.id_transaccion = t.id_transaccion
                  JOIN regla r            ON r.id_regla        = a.id_regla
                  JOIN tipo_regla tr      ON tr.id_tipo_regla  = r.id_tipo_regla
                 WHERE cv.id_vehiculo = p_id_vehiculo
                   AND t.fecha_hora  >= p_desde
                   AND t.fecha_hora   < p_hasta
                 GROUP BY tr.codigo
                 ORDER BY 2 DESC, 1) LOOP
        DBMS_OUTPUT.PUT_LINE('  Alertas ' || RPAD(r.codigo, 26) || r.n);
      END LOOP;
    END IF;
  END p_analizar_historial;

  PROCEDURE p_generar_alertas_exceso_consumo(
    p_desde  IN  DATE,
    p_hasta  IN  DATE,
    p_nuevas OUT NUMBER) IS
    l_n NUMBER;
  BEGIN
    p_nuevas := 0;
    FOR t IN (SELECT id_transaccion
                FROM transaccion
               WHERE tipo_transaccion = 'VEHICULAR'
                 AND estado           = 'APROBADA'
                 AND fecha_hora      >= p_desde
                 AND fecha_hora       < p_hasta
               ORDER BY fecha_hora, id_transaccion) LOOP
      pkg_deteccion.p_reevaluar_transaccion(t.id_transaccion, 'EXCESO_VOLUMEN,CONSUMO_VS_ESPERADO', l_n);
      p_nuevas := p_nuevas + l_n;
    END LOOP;
  END p_generar_alertas_exceso_consumo;

  PROCEDURE p_reporte_estadistico(
    p_desde     IN  DATE,
    p_hasta     IN  DATE,
    p_resultado OUT SYS_REFCURSOR) IS
  BEGIN
    OPEN p_resultado FOR
      WITH op AS (
        SELECT * FROM v_historial_carga
         WHERE fecha_hora >= p_desde AND fecha_hora < p_hasta
      ), al AS (
        SELECT * FROM v_alerta_detalle
         WHERE fecha_deteccion >= p_desde AND fecha_deteccion < p_hasta
      ), tot AS (
        SELECT SUM(CASE WHEN estado = 'APROBADA' THEN cantidad_total ELSE 0 END) AS despachado,
               SUM(cantidad_subvencionada) AS subvencionado
          FROM op
      )
      SELECT 1 AS orden, 'Operaciones aprobadas' AS indicador,
             (SELECT COUNT(*) FROM op WHERE estado = 'APROBADA') AS valor FROM dual
      UNION ALL
      SELECT 2, 'Operaciones bloqueadas', (SELECT COUNT(*) FROM op WHERE estado = 'BLOQUEADA') FROM dual
      UNION ALL
      SELECT 3, 'Volumen despachado', (SELECT NVL(despachado, 0) FROM tot) FROM dual
      UNION ALL
      SELECT 4, 'Volumen subvencionado', (SELECT NVL(subvencionado, 0) FROM tot) FROM dual
      UNION ALL
      SELECT 5, 'Porcentaje subvencionado',
             (SELECT ROUND(100 * subvencionado / NULLIF(despachado, 0), 2) FROM tot) FROM dual
      UNION ALL
      SELECT 6, 'Monto total (Bs)', (SELECT NVL(ROUND(SUM(monto_bs), 2), 0) FROM op) FROM dual
      UNION ALL
      SELECT 7, 'Vehiculos distintos', (SELECT COUNT(DISTINCT id_vehiculo) FROM op) FROM dual
      UNION ALL
      SELECT 8, 'Estaciones con operaciones', (SELECT COUNT(DISTINCT id_estacion) FROM op) FROM dual
      UNION ALL
      SELECT 9, 'Alertas generadas', (SELECT COUNT(*) FROM al) FROM dual
      UNION ALL
      SELECT 10, 'Alertas de gravedad ALTA', (SELECT COUNT(*) FROM al WHERE gravedad = 'ALTA') FROM dual
      UNION ALL
      SELECT 11, 'Alertas pendientes', (SELECT COUNT(*) FROM al WHERE estado_gestion = 'PENDIENTE') FROM dual
      UNION ALL
      SELECT 12, 'Alertas atendidas', (SELECT COUNT(*) FROM al WHERE estado_gestion = 'ATENDIDA') FROM dual
      UNION ALL
      SELECT 13, 'Alertas descartadas', (SELECT COUNT(*) FROM al WHERE estado_gestion = 'DESCARTADA') FROM dual
      UNION ALL
      SELECT 14, 'Porcentaje de falsos positivos',
             (SELECT ROUND(100 * SUM(CASE WHEN estado_gestion = 'DESCARTADA' THEN 1 ELSE 0 END)
                           / NULLIF(SUM(CASE WHEN estado_gestion <> 'PENDIENTE' THEN 1 ELSE 0 END), 0), 2)
                FROM al) FROM dual
      UNION ALL
      SELECT 15, 'Estaciones con desbalance YPFB',
             (SELECT COUNT(DISTINCT id_estacion) FROM al WHERE codigo_regla = 'DESBALANCE_YPFB') FROM dual
      UNION ALL
      SELECT 16, 'Reclamos de calidad',
             (SELECT COUNT(*) FROM reclamo_calidad WHERE fecha_hora >= p_desde AND fecha_hora < p_hasta) FROM dual
      ORDER BY 1;
  END p_reporte_estadistico;

  FUNCTION f_clasificar_alerta(p_id_alerta IN NUMBER) RETURN VARCHAR2 IS
    l_id_regla   NUMBER;
    l_gravedad   regla.gravedad%TYPE;
    l_resultado  alerta.resultado_revision%TYPE;
    l_fecha      TIMESTAMP;
    l_vehiculo   NUMBER;
    l_estacion   NUMBER;
    l_nivel      NUMBER;
    l_otras      NUMBER := 0;
  BEGIN
    SELECT a.id_regla, r.gravedad, a.resultado_revision, a.fecha_deteccion, cv.id_vehiculo, a.id_estacion
      INTO l_id_regla, l_gravedad, l_resultado, l_fecha, l_vehiculo, l_estacion
      FROM alerta a
      JOIN regla r                 ON r.id_regla        = a.id_regla
      LEFT JOIN carga_vehicular cv ON cv.id_transaccion = a.id_transaccion
     WHERE a.id_alerta = p_id_alerta;

    IF l_resultado = 'FALSO_POSITIVO' THEN
      RETURN 'DESCARTADA';
    END IF;

    l_nivel := CASE l_gravedad WHEN 'ALTA' THEN 3 WHEN 'MEDIA' THEN 2 ELSE 1 END;

    IF l_vehiculo IS NOT NULL THEN
      SELECT COUNT(*) INTO l_otras
        FROM alerta a
        JOIN carga_vehicular cv ON cv.id_transaccion = a.id_transaccion
       WHERE cv.id_vehiculo     = l_vehiculo
         AND a.id_alerta       <> p_id_alerta
         AND NVL(a.resultado_revision, 'X') <> 'FALSO_POSITIVO'
         AND a.fecha_deteccion >= l_fecha - NUMTODSINTERVAL(30, 'DAY')
         AND a.fecha_deteccion <= l_fecha;
      IF l_otras >= 2 THEN
        l_nivel := l_nivel + 1;
      END IF;
    ELSIF l_estacion IS NOT NULL THEN
      SELECT COUNT(*) INTO l_otras
        FROM alerta a
       WHERE a.id_estacion      = l_estacion
         AND a.id_alerta       <> p_id_alerta
         AND NVL(a.resultado_revision, 'X') <> 'FALSO_POSITIVO'
         AND a.fecha_deteccion >= l_fecha - NUMTODSINTERVAL(56, 'DAY')
         AND a.fecha_deteccion <= l_fecha;
      IF l_otras >= 1 THEN
        l_nivel := l_nivel + 1;
      END IF;
    END IF;

    RETURN CASE LEAST(l_nivel, 4)
             WHEN 4 THEN 'CRITICA'
             WHEN 3 THEN 'ALTA'
             WHEN 2 THEN 'MEDIA'
             ELSE 'BAJA'
           END;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END f_clasificar_alerta;

  PROCEDURE p_refrescar_vistas_materializadas IS
  BEGIN
    DBMS_MVIEW.REFRESH(
      list           => $$PLSQL_UNIT_OWNER || '.MV_VENTAS_ESTACION_DIA,'
                        || $$PLSQL_UNIT_OWNER || '.MV_CONSUMO_VEHICULO_MES',
      method         => 'CC',
      atomic_refresh => TRUE);
  END p_refrescar_vistas_materializadas;

END pkg_analisis;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Verificacion sobre un escenario de prueba (SAVEPOINT, se deshace).
-- p_refrescar_vistas_materializadas NO se ejecuta aqui porque hace
-- COMMIT y guardaria los datos de prueba; solo se verifica que compila.
-- ------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  l_n      NUMBER;
  l_gas    NUMBER;
  l_auto   NUMBER;
  l_est_a  NUMBER;
  l_sur_a  NUMBER;
  l_mu     NUMBER;
  l_p1     NUMBER;
  l_ficha  NUMBER;
  l_v1     NUMBER;
  l_tx     NUMBER;
  l_tk     NUMBER;
  l_est    VARCHAR2(10);
  l_cur    SYS_REFCURSOR;
  l_alerta NUMBER;
  -- columnas de p_analizar_historial
  l_dia DATE; l_ap NUMBER; l_bl NUMBER; l_es NUMBER; l_ca NUMBER; l_ed NUMBER; l_al NUMBER;
  -- columnas de p_reporte_estadistico
  l_orden NUMBER; l_ind VARCHAR2(100); l_val NUMBER; l_aprob NUMBER;
  l_reglas_antes NUMBER;

  PROCEDURE chequear(p_nombre IN VARCHAR2, p_ok IN BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      DBMS_OUTPUT.PUT_LINE('OK    ' || p_nombre);
    ELSE
      RAISE_APPLICATION_ERROR(-20999, '08_pkg_analisis: FALLO ' || p_nombre);
    END IF;
  END chequear;

  PROCEDURE carga(p_cant IN NUMBER, p_ts IN TIMESTAMP) IS
  BEGIN
    pkg_transacciones.p_registrar_carga_vehicular(
      p_id_surtidor => l_sur_a, p_id_vehiculo => l_v1, p_id_persona => l_p1,
      p_id_combustible => l_gas, p_cantidad => p_cant, p_fecha_hora => p_ts,
      p_id_transaccion => l_tx, p_nro_ticket => l_tk, p_estado => l_est);
  END carga;
BEGIN
  SELECT COUNT(*) INTO l_n FROM all_objects
   WHERE owner = l_schema AND object_name = 'PKG_ANALISIS' AND status = 'VALID';
  chequear('pkg_analisis (especificacion y cuerpo) VALID', l_n = 2);

  SELECT COUNT(*) INTO l_reglas_antes FROM regla;
  SAVEPOINT sp_08;
  SELECT id_combustible   INTO l_gas  FROM combustible   WHERE nombre = 'Gasolina Especial';
  SELECT id_tipo_vehiculo INTO l_auto FROM tipo_vehiculo WHERE nombre = 'AUTO';
  SELECT id_municipio     INTO l_mu   FROM municipio     WHERE nombre = 'Cochabamba';

  -- Escenario: estacion A, persona P1, auto de 1.600 cc (esperado 8 L/dia) con beneficio
  INSERT INTO estacion (id_municipio, nombre, nit, zona, latitud, longitud, es_fronteriza)
    VALUES (l_mu, 'TST-A', 'NIT-TST-A', 'Prueba', -17, -66, 'N') RETURNING id_estacion INTO l_est_a;
  INSERT INTO surtidor (id_estacion, codigo) VALUES (l_est_a, 'S1') RETURNING id_surtidor INTO l_sur_a;
  INSERT INTO persona (tipo_documento, nro_documento, nombres, nacionalidad, fecha_registro)
    VALUES ('CI', 'TST-P1', 'Prueba', 'BOLIVIANA', DATE '2026-01-01') RETURNING id_persona INTO l_p1;
  -- huella ACTIVA: el trigger de beneficios la exige
  INSERT INTO huella_digital (id_persona, plantilla, fecha_enrolamiento)
    VALUES (l_p1, TO_BLOB(HEXTORAW('00')), DATE '2026-01-01');
  INSERT INTO ficha_aduana (nro_chasis, id_combustible, marca, modelo, anio_fabricacion, cilindrada, capacidad_tanque)
    VALUES ('CH-TST-001', l_gas, 'Toyota', 'Corolla', 2018, 1600, 50) RETURNING id_ficha INTO l_ficha;
  INSERT INTO vehiculo (id_tipo_vehiculo, id_ficha, placa, codigo_rfid, fecha_registro)
    VALUES (l_auto, l_ficha, 'TST-001', 'RFID-TST-001', DATE '2026-01-01') RETURNING id_vehiculo INTO l_v1;
  INSERT INTO registro_ruat (id_vehiculo, id_persona, clase, servicio, fecha_alta)
    VALUES (l_v1, l_p1, 'AUTOMOVIL', 'PARTICULAR', DATE '2026-01-01');
  INSERT INTO registro_beneficio (id_vehiculo, id_persona, id_regla, fecha_inicio)
    VALUES (l_v1, l_p1, pkg_reglas.f_id_regla_vigente('MAX_VEHICULOS_PERSONA', TIMESTAMP '2026-11-16 00:00:00'),
            DATE '2026-01-01');

  -- Lunes 25 + 25 L, martes 20 L (con la regla de 80 L/dia no hay alertas)
  carga(25, TIMESTAMP '2026-11-16 08:00:00');
  carga(25, TIMESTAMP '2026-11-16 14:00:00');
  carga(20, TIMESTAMP '2026-11-17 08:00:00');
  SELECT COUNT(*) INTO l_n FROM alerta a JOIN carga_vehicular cv ON cv.id_transaccion = a.id_transaccion
   WHERE cv.id_vehiculo = l_v1;
  chequear('cargas normales sin alertas', l_n = 0);

  -- Ejemplos 1 y 5
  chequear('consumo acumulado lunes-martes = 70',
           pkg_analisis.f_consumo_acumulado(l_v1, DATE '2026-11-16', DATE '2026-11-18') = 70);
  chequear('consumo acumulado lunes = 50',
           pkg_analisis.f_consumo_acumulado(l_v1, DATE '2026-11-16', DATE '2026-11-17') = 50);
  chequear('consumo esperado semana = 56 (8 x 7)',
           pkg_analisis.f_consumo_esperado(l_v1, DATE '2026-11-16', DATE '2026-11-23') = 56);
  chequear('diferencia semana = 14 (70 - 56)',
           pkg_analisis.f_diferencia_consumo(l_v1, DATE '2026-11-16', DATE '2026-11-23') = 14);

  -- Ejemplo 2
  pkg_analisis.p_analizar_historial(l_v1, DATE '2026-11-16', DATE '2026-11-23', l_cur, 'N');
  l_n := 0;
  LOOP
    FETCH l_cur INTO l_dia, l_ap, l_bl, l_es, l_ca, l_ed, l_al;
    EXIT WHEN l_cur%NOTFOUND;
    l_n := l_n + 1;
    IF l_dia = DATE '2026-11-16' THEN
      chequear('historial lunes: 2 cargas, 50 L, esperado 8', l_ap = 2 AND l_ca = 50 AND l_ed = 8);
    END IF;
  END LOOP;
  CLOSE l_cur;
  chequear('historial con 2 dias', l_n = 2);

  -- Ejemplo 3: una version mas estricta (30 L/dia desde 2026-11-01) y regenerar
  pkg_reglas.p_crear_version_regla('EXCESO_VOLUMEN', l_auto, l_gas, pkg_reglas.f_id_tipo_periodo('DIA'),
                                   NULL, NULL, NULL, 30, NULL, 'MEDIA', DATE '2026-11-01');
  pkg_analisis.p_generar_alertas_exceso_consumo(DATE '2026-11-16', DATE '2026-11-18', l_n);
  chequear('regenerar con regla de 30 L -> 1 alerta nueva (lunes 50 L)', l_n = 1);
  pkg_analisis.p_generar_alertas_exceso_consumo(DATE '2026-11-16', DATE '2026-11-18', l_n);
  chequear('regenerar otra vez -> 0 alertas nuevas', l_n = 0);

  -- Ejemplo 10
  SELECT MAX(a.id_alerta) INTO l_alerta
    FROM alerta a JOIN carga_vehicular cv ON cv.id_transaccion = a.id_transaccion
   WHERE cv.id_vehiculo = l_v1;
  chequear('clasificacion de alerta MEDIA sin reincidencia',
           pkg_analisis.f_clasificar_alerta(l_alerta) = 'MEDIA');
  chequear('clasificacion de alerta inexistente = NULL',
           pkg_analisis.f_clasificar_alerta(-1) IS NULL);

  -- Ejemplo 8
  pkg_analisis.p_reporte_estadistico(DATE '2026-11-16', DATE '2026-11-18', l_cur);
  l_n := 0;
  LOOP
    FETCH l_cur INTO l_orden, l_ind, l_val;
    EXIT WHEN l_cur%NOTFOUND;
    l_n := l_n + 1;
    IF l_orden = 1 THEN
      l_aprob := l_val;
    END IF;
  END LOOP;
  CLOSE l_cur;
  chequear('reporte con 16 indicadores', l_n = 16);
  chequear('reporte cuenta las 3 operaciones aprobadas', l_aprob >= 3);

  ROLLBACK TO sp_08;
  SELECT COUNT(*) INTO l_n FROM estacion WHERE nombre LIKE 'TST-%';
  chequear('no quedaron datos de prueba', l_n = 0);
  SELECT COUNT(*) INTO l_n FROM regla;
  chequear('la version de prueba de la regla se deshizo', l_n = l_reglas_antes);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/
