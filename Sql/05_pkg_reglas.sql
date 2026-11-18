-- ============================================================
-- 05_pkg_reglas.sql
-- Paquete pkg_reglas: "que regla o precio estaba vigente en esa
-- fecha y hora?" + versionado de reglas (plan, seccion 5.1).
-- Re-ejecutable (CREATE OR REPLACE). El paquete NO hace COMMIT ni
-- ROLLBACK: eso lo decide quien lo llama.
-- Convencion de vigencia: intervalo semiabierto [fecha_inicio, fecha_fin).
-- Errores: -20010 periodo invalido, -20011 tipo de regla inexistente,
--          -20102 vigencia solapada / version con inicio no posterior.
-- Autor: <nombre>   Fecha: 2026-11-18
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ------------------------------------------------------------
-- Especificacion (firmas fijas: contrato del plan, seccion 5.1)
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE pkg_reglas AS
  -- Inicio (inclusive) y fin (exclusivo) del periodo calendario de p_fecha.
  -- DIA = dia calendario; SEMANA = semana ISO (lunes); MES = mes calendario.
  FUNCTION f_inicio_periodo(p_fecha IN TIMESTAMP, p_codigo_periodo IN VARCHAR2) RETURN TIMESTAMP;
  FUNCTION f_fin_periodo   (p_fecha IN TIMESTAMP, p_codigo_periodo IN VARCHAR2) RETURN TIMESTAMP;

  -- id_tipo_periodo a partir de su codigo (DIA/SEMANA/MES). NULL si p_codigo es NULL.
  FUNCTION f_id_tipo_periodo(p_codigo IN VARCHAR2) RETURN NUMBER;

  -- Devuelve el id_regla de la regla ganadora, o NULL si ninguna aplica.
  -- Un campo de ambito NULL en la regla = "aplica a todos". Si el parametro
  -- es NULL, solo pasan reglas con ese campo NULL.
  -- Gana la de mayor especificidad (mas campos de ambito no nulos), luego la
  -- de fecha_inicio mas reciente, luego la de mayor id_regla.
  FUNCTION f_id_regla_vigente(
    p_codigo_regla      IN VARCHAR2,
    p_fecha             IN TIMESTAMP,
    p_id_tipo_vehiculo  IN NUMBER DEFAULT NULL,
    p_id_combustible    IN NUMBER DEFAULT NULL,
    p_id_tipo_periodo   IN NUMBER DEFAULT NULL,
    p_es_fronteriza     IN CHAR   DEFAULT NULL) RETURN NUMBER;

  -- Devuelve el id_precio vigente, o NULL si no existe.
  FUNCTION f_id_precio_vigente(
    p_id_combustible IN NUMBER,
    p_tipo_precio    IN VARCHAR2,
    p_fecha          IN TIMESTAMP) RETURN NUMBER;

  -- Cierra la version vigente del mismo tipo y ambito (fecha_fin = p_fecha_inicio)
  -- y crea la nueva. Falla (-20102) si ya existe una version del mismo ambito
  -- con fecha_inicio igual o posterior a p_fecha_inicio.
  PROCEDURE p_crear_version_regla(
    p_codigo_regla      IN VARCHAR2,
    p_id_tipo_vehiculo  IN NUMBER,
    p_id_combustible    IN NUMBER,
    p_id_tipo_periodo   IN NUMBER,
    p_solo_fronteriza   IN CHAR,
    p_valor             IN NUMBER,
    p_valor_secundario  IN NUMBER,
    p_gravedad          IN VARCHAR2,
    p_fecha_inicio      IN DATE);
END pkg_reglas;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Cuerpo
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE BODY pkg_reglas AS

  FUNCTION f_inicio_periodo(p_fecha IN TIMESTAMP, p_codigo_periodo IN VARCHAR2) RETURN TIMESTAMP IS
    l_d   DATE := CAST(p_fecha AS DATE);
    l_ini DATE;
  BEGIN
    IF p_fecha IS NULL THEN
      RETURN NULL;
    END IF;
    IF p_codigo_periodo = 'DIA' THEN
      l_ini := TRUNC(l_d);
    ELSIF p_codigo_periodo = 'SEMANA' THEN
      l_ini := TRUNC(l_d, 'IW');
    ELSIF p_codigo_periodo = 'MES' THEN
      l_ini := TRUNC(l_d, 'MM');
    ELSE
      RAISE_APPLICATION_ERROR(-20010, 'Codigo de periodo invalido: ' || NVL(p_codigo_periodo, 'NULL'));
    END IF;
    RETURN CAST(l_ini AS TIMESTAMP);
  END f_inicio_periodo;

  FUNCTION f_fin_periodo(p_fecha IN TIMESTAMP, p_codigo_periodo IN VARCHAR2) RETURN TIMESTAMP IS
    l_ini DATE := CAST(f_inicio_periodo(p_fecha, p_codigo_periodo) AS DATE);
    l_fin DATE;
  BEGIN
    IF p_fecha IS NULL THEN
      RETURN NULL;
    END IF;
    IF p_codigo_periodo = 'DIA' THEN
      l_fin := l_ini + 1;
    ELSIF p_codigo_periodo = 'SEMANA' THEN
      l_fin := l_ini + 7;
    ELSE  -- 'MES' (cualquier otro valor ya fallo en f_inicio_periodo)
      l_fin := ADD_MONTHS(l_ini, 1);
    END IF;
    RETURN CAST(l_fin AS TIMESTAMP);
  END f_fin_periodo;

  FUNCTION f_id_tipo_periodo(p_codigo IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    IF p_codigo IS NULL THEN
      RETURN NULL;
    END IF;
    SELECT id_tipo_periodo INTO l_id FROM tipo_periodo WHERE codigo = p_codigo;
    RETURN l_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20010, 'Codigo de periodo invalido: ' || p_codigo);
  END f_id_tipo_periodo;

  FUNCTION f_id_regla_vigente(
    p_codigo_regla      IN VARCHAR2,
    p_fecha             IN TIMESTAMP,
    p_id_tipo_vehiculo  IN NUMBER DEFAULT NULL,
    p_id_combustible    IN NUMBER DEFAULT NULL,
    p_id_tipo_periodo   IN NUMBER DEFAULT NULL,
    p_es_fronteriza     IN CHAR   DEFAULT NULL) RETURN NUMBER IS
    l_fecha DATE := CAST(p_fecha AS DATE);
    l_id    NUMBER;
  BEGIN
    SELECT id_regla
      INTO l_id
      FROM (SELECT r.id_regla
              FROM regla r
              JOIN tipo_regla tr ON tr.id_tipo_regla = r.id_tipo_regla
             WHERE tr.codigo = p_codigo_regla
               AND r.fecha_inicio <= l_fecha
               AND (r.fecha_fin IS NULL OR l_fecha < r.fecha_fin)
               AND (r.id_tipo_vehiculo IS NULL OR r.id_tipo_vehiculo = p_id_tipo_vehiculo)
               AND (r.id_combustible   IS NULL OR r.id_combustible   = p_id_combustible)
               AND (r.id_tipo_periodo  IS NULL OR r.id_tipo_periodo  = p_id_tipo_periodo)
               AND (r.solo_fronteriza  IS NULL OR r.solo_fronteriza  = p_es_fronteriza)
             ORDER BY (CASE WHEN r.id_tipo_vehiculo IS NOT NULL THEN 1 ELSE 0 END
                     + CASE WHEN r.id_combustible   IS NOT NULL THEN 1 ELSE 0 END
                     + CASE WHEN r.id_tipo_periodo  IS NOT NULL THEN 1 ELSE 0 END
                     + CASE WHEN r.solo_fronteriza  IS NOT NULL THEN 1 ELSE 0 END) DESC,
                      r.fecha_inicio DESC,
                      r.id_regla DESC)
     WHERE ROWNUM = 1;
    RETURN l_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END f_id_regla_vigente;

  FUNCTION f_id_precio_vigente(
    p_id_combustible IN NUMBER,
    p_tipo_precio    IN VARCHAR2,
    p_fecha          IN TIMESTAMP) RETURN NUMBER IS
    l_fecha DATE := CAST(p_fecha AS DATE);
    l_id    NUMBER;
  BEGIN
    SELECT id_precio
      INTO l_id
      FROM (SELECT pc.id_precio
              FROM precio_combustible pc
             WHERE pc.id_combustible = p_id_combustible
               AND pc.tipo_precio    = p_tipo_precio
               AND pc.fecha_inicio  <= l_fecha
               AND (pc.fecha_fin IS NULL OR l_fecha < pc.fecha_fin)
             ORDER BY pc.fecha_inicio DESC, pc.id_precio DESC)
     WHERE ROWNUM = 1;
    RETURN l_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END f_id_precio_vigente;

  PROCEDURE p_crear_version_regla(
    p_codigo_regla      IN VARCHAR2,
    p_id_tipo_vehiculo  IN NUMBER,
    p_id_combustible    IN NUMBER,
    p_id_tipo_periodo   IN NUMBER,
    p_solo_fronteriza   IN CHAR,
    p_valor             IN NUMBER,
    p_valor_secundario  IN NUMBER,
    p_gravedad          IN VARCHAR2,
    p_fecha_inicio      IN DATE) IS
    l_tr NUMBER;
    l_n  NUMBER;
  BEGIN
    BEGIN
      SELECT id_tipo_regla INTO l_tr FROM tipo_regla WHERE codigo = p_codigo_regla;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20011, 'Tipo de regla inexistente: ' || p_codigo_regla);
    END;

    -- No debe existir una version del mismo ambito que empiece en esa fecha o despues.
    -- (DECODE compara NULL con NULL como iguales)
    SELECT COUNT(*)
      INTO l_n
      FROM regla r
     WHERE r.id_tipo_regla = l_tr
       AND DECODE(r.id_tipo_vehiculo, p_id_tipo_vehiculo, 1, 0) = 1
       AND DECODE(r.id_combustible,   p_id_combustible,   1, 0) = 1
       AND DECODE(r.id_tipo_periodo,  p_id_tipo_periodo,  1, 0) = 1
       AND DECODE(r.solo_fronteriza,  p_solo_fronteriza,  1, 0) = 1
       AND r.fecha_inicio >= p_fecha_inicio;
    IF l_n > 0 THEN
      RAISE_APPLICATION_ERROR(-20102,
        'Ya existe una version de ' || p_codigo_regla ||
        ' para ese ambito con inicio igual o posterior a ' || TO_CHAR(p_fecha_inicio, 'YYYY-MM-DD HH24:MI:SS'));
    END IF;

    -- Cierra la version vigente (o la que siga abierta hacia el futuro)
    UPDATE regla r
       SET r.fecha_fin = p_fecha_inicio
     WHERE r.id_tipo_regla = l_tr
       AND DECODE(r.id_tipo_vehiculo, p_id_tipo_vehiculo, 1, 0) = 1
       AND DECODE(r.id_combustible,   p_id_combustible,   1, 0) = 1
       AND DECODE(r.id_tipo_periodo,  p_id_tipo_periodo,  1, 0) = 1
       AND DECODE(r.solo_fronteriza,  p_solo_fronteriza,  1, 0) = 1
       AND (r.fecha_fin IS NULL OR r.fecha_fin > p_fecha_inicio);

    INSERT INTO regla (id_tipo_regla, id_tipo_vehiculo, id_combustible, id_tipo_periodo,
                       solo_fronteriza, valor, valor_secundario, gravedad,
                       fecha_inicio, fecha_fin)
      VALUES (l_tr, p_id_tipo_vehiculo, p_id_combustible, p_id_tipo_periodo,
              p_solo_fronteriza, p_valor, p_valor_secundario, p_gravedad,
              p_fecha_inicio, NULL);
  END p_crear_version_regla;

END pkg_reglas;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Verificacion: el paquete compila y responde como dice el plan.
-- Las pruebas de versionado se hacen dentro de un SAVEPOINT y se
-- deshacen: no dejan datos. Si algo falla, se lanza un error.
-- ------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  l_n      NUMBER;
  l_auto   NUMBER;
  l_moto   NUMBER;
  l_pesado NUMBER;
  l_gas    NUMBER;
  l_prem   NUMBER;
  l_dia    NUMBER;
  l_ts     TIMESTAMP := TIMESTAMP '2026-11-18 15:30:00';

  PROCEDURE chequear(p_nombre IN VARCHAR2, p_ok IN BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      DBMS_OUTPUT.PUT_LINE('OK    ' || p_nombre);
    ELSE
      RAISE_APPLICATION_ERROR(-20999, '05_pkg_reglas: FALLO ' || p_nombre);
    END IF;
  END chequear;

  FUNCTION valor_de(p_id IN NUMBER) RETURN NUMBER IS
    l_v NUMBER;
  BEGIN
    SELECT valor INTO l_v FROM regla WHERE id_regla = p_id;
    RETURN l_v;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END valor_de;

  FUNCTION precio_de(p_id IN NUMBER) RETURN NUMBER IS
    l_v NUMBER;
  BEGIN
    SELECT precio_unitario INTO l_v FROM precio_combustible WHERE id_precio = p_id;
    RETURN l_v;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END precio_de;
BEGIN
  -- Estado del paquete
  SELECT COUNT(*) INTO l_n FROM all_objects
   WHERE owner = l_schema AND object_name = 'PKG_REGLAS' AND status = 'VALID';
  chequear('pkg_reglas (especificacion y cuerpo) VALID', l_n = 2);

  SELECT id_tipo_vehiculo INTO l_auto   FROM tipo_vehiculo WHERE nombre = 'AUTO';
  SELECT id_tipo_vehiculo INTO l_moto   FROM tipo_vehiculo WHERE nombre = 'MOTO';
  SELECT id_tipo_vehiculo INTO l_pesado FROM tipo_vehiculo WHERE nombre = 'PESADO';
  SELECT id_combustible   INTO l_gas    FROM combustible   WHERE nombre = 'Gasolina Especial';
  SELECT id_combustible   INTO l_prem   FROM combustible   WHERE nombre = 'Gasolina Premium';
  l_dia := pkg_reglas.f_id_tipo_periodo('DIA');

  -- Periodos (2026-11-18 es miercoles; la semana ISO empieza el lunes 16)
  chequear('inicio DIA    = 2026-11-18', pkg_reglas.f_inicio_periodo(l_ts, 'DIA')    = TIMESTAMP '2026-11-18 00:00:00');
  chequear('inicio SEMANA = 2026-11-16', pkg_reglas.f_inicio_periodo(l_ts, 'SEMANA') = TIMESTAMP '2026-11-16 00:00:00');
  chequear('inicio MES    = 2026-11-01', pkg_reglas.f_inicio_periodo(l_ts, 'MES')    = TIMESTAMP '2026-11-01 00:00:00');
  chequear('fin DIA       = 2026-11-19', pkg_reglas.f_fin_periodo(l_ts, 'DIA')       = TIMESTAMP '2026-11-19 00:00:00');
  chequear('fin SEMANA    = 2026-11-23', pkg_reglas.f_fin_periodo(l_ts, 'SEMANA')    = TIMESTAMP '2026-11-23 00:00:00');
  chequear('fin MES       = 2026-12-01', pkg_reglas.f_fin_periodo(l_ts, 'MES')       = TIMESTAMP '2026-12-01 00:00:00');

  -- Reglas temporales: cuota AUTO/gasolina/DIA (50 hasta 2026-07-01 exclusive, luego 40)
  chequear('cuota AUTO 2026-06-15 = 50',
    valor_de(pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', TIMESTAMP '2026-06-15 10:00:00', l_auto, l_gas, l_dia)) = 50);
  chequear('cuota AUTO 2026-06-30 23:59:59 = 50',
    valor_de(pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', TIMESTAMP '2026-06-30 23:59:59', l_auto, l_gas, l_dia)) = 50);
  chequear('cuota AUTO 2026-07-01 00:00:00 = 40 (fin exclusivo)',
    valor_de(pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', TIMESTAMP '2026-07-01 00:00:00', l_auto, l_gas, l_dia)) = 40);
  chequear('cuota AUTO 2026-11-18 = 40',
    valor_de(pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', l_ts, l_auto, l_gas, l_dia)) = 40);

  -- Especificidad: la regla fronteriza gana solo en estaciones fronterizas
  chequear('exceso AUTO fronteriza S = 60',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', l_ts, l_auto, l_gas, l_dia, 'S')) = 60);
  chequear('exceso AUTO fronteriza N = 80',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', l_ts, l_auto, l_gas, l_dia, 'N')) = 80);
  chequear('exceso AUTO fronteriza NULL = 80',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', l_ts, l_auto, l_gas, l_dia, NULL)) = 80);
  chequear('exceso MOTO (fronteriza S) = 30',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', l_ts, l_moto, l_gas, l_dia, 'S')) = 30);

  -- Sin regla aplicable -> NULL
  chequear('codigo inexistente -> NULL',
    pkg_reglas.f_id_regla_vigente('NO_EXISTE', l_ts, l_auto, l_gas, l_dia) IS NULL);
  chequear('cuota PESADO con gasolina -> NULL',
    pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', l_ts, l_pesado, l_gas, l_dia) IS NULL);

  -- Reglas sin ambito (aplican a todos)
  chequear('MAX_VEHICULOS_PERSONA = 2',
    valor_de(pkg_reglas.f_id_regla_vigente('MAX_VEHICULOS_PERSONA', l_ts)) = 2);

  -- Precios
  chequear('precio INTERNACIONAL gasolina 2025-09-01 = 7.9',
    precio_de(pkg_reglas.f_id_precio_vigente(l_gas, 'INTERNACIONAL', TIMESTAMP '2025-09-01 00:00:00')) = 7.9);
  chequear('precio INTERNACIONAL gasolina 2026-01-01 = 8.2 (fin exclusivo)',
    precio_de(pkg_reglas.f_id_precio_vigente(l_gas, 'INTERNACIONAL', TIMESTAMP '2026-01-01 00:00:00')) = 8.2);
  chequear('precio SUBVENCIONADO gasolina 2026-11-18 = 3.74',
    precio_de(pkg_reglas.f_id_precio_vigente(l_gas, 'SUBVENCIONADO', l_ts)) = 3.74);
  chequear('Gasolina Premium sin SUBVENCIONADO -> NULL',
    pkg_reglas.f_id_precio_vigente(l_prem, 'SUBVENCIONADO', l_ts) IS NULL);

  -- Versionado (dentro de un SAVEPOINT; se deshace al final)
  SAVEPOINT sp_pkg_reglas;
  pkg_reglas.p_crear_version_regla('EXCESO_VOLUMEN', l_moto, l_gas, l_dia, NULL, 25, NULL, 'MEDIA', DATE '2026-12-01');
  chequear('version nueva vigente el 2026-12-02 = 25',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', TIMESTAMP '2026-12-02 00:00:00', l_moto, l_gas, l_dia)) = 25);
  chequear('version anterior vigente el 2026-11-30 = 30',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', TIMESTAMP '2026-11-30 00:00:00', l_moto, l_gas, l_dia)) = 30);
  ROLLBACK TO sp_pkg_reglas;
  chequear('tras deshacer, el 2026-12-02 vuelve a 30',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', TIMESTAMP '2026-12-02 00:00:00', l_moto, l_gas, l_dia)) = 30);

  -- Una version con inicio igual o anterior a la vigente debe rechazarse (-20102)
  BEGIN
    pkg_reglas.p_crear_version_regla('EXCESO_VOLUMEN', l_moto, l_gas, l_dia, NULL, 25, NULL, 'MEDIA', DATE '2026-01-01');
    chequear('rechaza version con inicio no posterior', FALSE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20102 THEN
        DBMS_OUTPUT.PUT_LINE('OK    rechaza version con inicio no posterior (-20102)');
      ELSE
        RAISE;
      END IF;
  END;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/
