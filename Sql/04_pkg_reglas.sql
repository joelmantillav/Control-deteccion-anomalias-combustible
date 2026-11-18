-- ============================================================
-- 04_pkg_reglas.sql
-- Paquete pkg_reglas: "que regla o precio estaba vigente en esa fecha
-- y para ese ambito?", consumo esperado y versionado de reglas.
-- Va antes de las vistas porque algunas vistas usan sus funciones.
-- Re-ejecutable (CREATE OR REPLACE). El paquete NO hace COMMIT ni
-- ROLLBACK: eso lo decide quien lo llama.
-- Convencion de vigencia: intervalo semiabierto [fecha_inicio, fecha_fin).
-- Errores: -20010 periodo invalido, -20011 tipo de regla inexistente,
--          -20012 gravedad inconsistente con la familia,
--          -20102 version con inicio no posterior a la existente.
-- Autor: <nombre>   Fecha: 2026-11-18
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ------------------------------------------------------------
-- Especificacion (contrato del plan, seccion 5.1)
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE pkg_reglas AS
  -- Inicio (inclusive) y fin (exclusivo) del periodo calendario de p_fecha.
  -- DIA = dia calendario; SEMANA = semana ISO (lunes); MES = mes calendario.
  FUNCTION f_inicio_periodo(p_fecha IN TIMESTAMP, p_codigo_periodo IN VARCHAR2) RETURN TIMESTAMP;
  FUNCTION f_fin_periodo   (p_fecha IN TIMESTAMP, p_codigo_periodo IN VARCHAR2) RETURN TIMESTAMP;

  -- id_tipo_periodo a partir de su codigo (DIA/SEMANA/MES). NULL si p_codigo es NULL.
  FUNCTION f_id_tipo_periodo(p_codigo IN VARCHAR2) RETURN NUMBER;

  -- Categoria de cilindrada que contiene p_cc. NULL si p_cc es NULL o ninguna la contiene.
  FUNCTION f_id_categoria_cilindrada(p_cc IN NUMBER) RETURN NUMBER;

  -- Devuelve el id_regla de la regla ganadora, o NULL si ninguna aplica.
  -- Un campo de ambito NULL en la regla = "aplica a todos". Si el parametro
  -- es NULL, solo pasan reglas con ese campo NULL.
  -- Gana la de mayor prioridad de ambito (suma de pesos):
  --   fronteriza 32, departamento 16, categoria de cilindrada 8,
  --   tipo de vehiculo 4, combustible 2, periodo 1;
  -- empate: fecha_inicio mas reciente, luego mayor id_regla.
  FUNCTION f_id_regla_vigente(
    p_codigo_regla             IN VARCHAR2,
    p_fecha                    IN TIMESTAMP,
    p_id_tipo_vehiculo         IN NUMBER DEFAULT NULL,
    p_id_combustible           IN NUMBER DEFAULT NULL,
    p_id_tipo_periodo          IN NUMBER DEFAULT NULL,
    p_es_fronteriza            IN CHAR   DEFAULT NULL,
    p_id_categoria_cilindrada  IN NUMBER DEFAULT NULL,
    p_id_departamento          IN NUMBER DEFAULT NULL) RETURN NUMBER;

  -- 'S' si la regla es una anomalia de TRANSACCION con gravedad ALTA
  -- (incumplirla bloquea la carga); 'N' en otro caso.
  FUNCTION f_es_bloqueante(p_id_regla IN NUMBER) RETURN CHAR;

  -- Consumo esperado por dia del vehiculo en p_fecha (regla CONSUMO_ESPERADO
  -- segun su tipo y la categoria de su cilindrada). NULL si no hay regla.
  -- Un vehiculo extranjero (sin ficha) usa la regla de su tipo sin categoria.
  FUNCTION f_consumo_esperado_dia(p_id_vehiculo IN NUMBER, p_fecha IN TIMESTAMP) RETURN NUMBER;

  -- Devuelve el id_precio vigente, o NULL si no existe.
  FUNCTION f_id_precio_vigente(
    p_id_combustible IN NUMBER,
    p_tipo_precio    IN VARCHAR2,
    p_fecha          IN TIMESTAMP) RETURN NUMBER;

  -- Cierra la version del mismo tipo y ambito que siga abierta en
  -- p_fecha_inicio (fecha_fin = p_fecha_inicio) y crea la nueva.
  -- Falla con -20102 si ya existe una version del mismo ambito con
  -- fecha_inicio igual o posterior, y con -20012 si la gravedad no
  -- corresponde a la familia (obligatoria solo en ANOMALIA).
  PROCEDURE p_crear_version_regla(
    p_codigo_regla             IN VARCHAR2,
    p_id_tipo_vehiculo         IN NUMBER,
    p_id_combustible           IN NUMBER,
    p_id_tipo_periodo          IN NUMBER,
    p_solo_fronteriza          IN CHAR,
    p_id_categoria_cilindrada  IN NUMBER,
    p_id_departamento          IN NUMBER,
    p_valor                    IN NUMBER,
    p_valor_secundario         IN NUMBER,
    p_gravedad                 IN VARCHAR2,
    p_fecha_inicio             IN DATE);
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

  FUNCTION f_id_categoria_cilindrada(p_cc IN NUMBER) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    IF p_cc IS NULL THEN
      RETURN NULL;
    END IF;
    SELECT id_categoria_cilindrada
      INTO l_id
      FROM (SELECT id_categoria_cilindrada
              FROM categoria_cilindrada
             WHERE p_cc >= cc_min
               AND (cc_max IS NULL OR p_cc <= cc_max)
             ORDER BY cc_min DESC)
     WHERE ROWNUM = 1;
    RETURN l_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END f_id_categoria_cilindrada;

  FUNCTION f_id_regla_vigente(
    p_codigo_regla             IN VARCHAR2,
    p_fecha                    IN TIMESTAMP,
    p_id_tipo_vehiculo         IN NUMBER DEFAULT NULL,
    p_id_combustible           IN NUMBER DEFAULT NULL,
    p_id_tipo_periodo          IN NUMBER DEFAULT NULL,
    p_es_fronteriza            IN CHAR   DEFAULT NULL,
    p_id_categoria_cilindrada  IN NUMBER DEFAULT NULL,
    p_id_departamento          IN NUMBER DEFAULT NULL) RETURN NUMBER IS
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
               AND (r.id_tipo_vehiculo        IS NULL OR r.id_tipo_vehiculo        = p_id_tipo_vehiculo)
               AND (r.id_combustible          IS NULL OR r.id_combustible          = p_id_combustible)
               AND (r.id_tipo_periodo         IS NULL OR r.id_tipo_periodo         = p_id_tipo_periodo)
               AND (r.solo_fronteriza         IS NULL OR r.solo_fronteriza         = p_es_fronteriza)
               AND (r.id_categoria_cilindrada IS NULL OR r.id_categoria_cilindrada = p_id_categoria_cilindrada)
               AND (r.id_departamento         IS NULL OR r.id_departamento         = p_id_departamento)
             ORDER BY (CASE WHEN r.solo_fronteriza         IS NOT NULL THEN 32 ELSE 0 END
                     + CASE WHEN r.id_departamento         IS NOT NULL THEN 16 ELSE 0 END
                     + CASE WHEN r.id_categoria_cilindrada IS NOT NULL THEN 8  ELSE 0 END
                     + CASE WHEN r.id_tipo_vehiculo        IS NOT NULL THEN 4  ELSE 0 END
                     + CASE WHEN r.id_combustible          IS NOT NULL THEN 2  ELSE 0 END
                     + CASE WHEN r.id_tipo_periodo         IS NOT NULL THEN 1  ELSE 0 END) DESC,
                      r.fecha_inicio DESC,
                      r.id_regla DESC)
     WHERE ROWNUM = 1;
    RETURN l_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END f_id_regla_vigente;

  FUNCTION f_es_bloqueante(p_id_regla IN NUMBER) RETURN CHAR IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*)
      INTO l_n
      FROM regla r
      JOIN tipo_regla tr ON tr.id_tipo_regla = r.id_tipo_regla
     WHERE r.id_regla    = p_id_regla
       AND tr.familia    = 'ANOMALIA'
       AND tr.evaluacion = 'TRANSACCION'
       AND r.gravedad    = 'ALTA';
    RETURN CASE WHEN l_n > 0 THEN 'S' ELSE 'N' END;
  END f_es_bloqueante;

  FUNCTION f_consumo_esperado_dia(p_id_vehiculo IN NUMBER, p_fecha IN TIMESTAMP) RETURN NUMBER IS
    l_tipo  NUMBER;
    l_cc    NUMBER;
    l_id    NUMBER;
    l_valor NUMBER;
  BEGIN
    SELECT v.id_tipo_vehiculo, f.cilindrada
      INTO l_tipo, l_cc
      FROM vehiculo v
      LEFT JOIN ficha_aduana f ON f.id_ficha = v.id_ficha
     WHERE v.id_vehiculo = p_id_vehiculo;

    l_id := f_id_regla_vigente('CONSUMO_ESPERADO', p_fecha,
                               p_id_tipo_vehiculo        => l_tipo,
                               p_id_categoria_cilindrada => f_id_categoria_cilindrada(l_cc));
    IF l_id IS NULL THEN
      RETURN NULL;
    END IF;
    SELECT valor INTO l_valor FROM regla WHERE id_regla = l_id;
    RETURN l_valor;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;   -- vehiculo inexistente
  END f_consumo_esperado_dia;

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
    p_codigo_regla             IN VARCHAR2,
    p_id_tipo_vehiculo         IN NUMBER,
    p_id_combustible           IN NUMBER,
    p_id_tipo_periodo          IN NUMBER,
    p_solo_fronteriza          IN CHAR,
    p_id_categoria_cilindrada  IN NUMBER,
    p_id_departamento          IN NUMBER,
    p_valor                    IN NUMBER,
    p_valor_secundario         IN NUMBER,
    p_gravedad                 IN VARCHAR2,
    p_fecha_inicio             IN DATE) IS
    l_tr      NUMBER;
    l_familia tipo_regla.familia%TYPE;
    l_n       NUMBER;
  BEGIN
    BEGIN
      SELECT id_tipo_regla, familia INTO l_tr, l_familia
        FROM tipo_regla WHERE codigo = p_codigo_regla;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20011, 'Tipo de regla inexistente: ' || p_codigo_regla);
    END;

    IF (l_familia = 'ANOMALIA' AND p_gravedad IS NULL)
       OR (l_familia <> 'ANOMALIA' AND p_gravedad IS NOT NULL) THEN
      RAISE_APPLICATION_ERROR(-20012,
        'La gravedad es obligatoria solo en reglas ANOMALIA (' || p_codigo_regla || ' es ' || l_familia || ')');
    END IF;

    -- No debe existir una version del mismo ambito que empiece en esa fecha o despues.
    -- (DECODE compara NULL con NULL como iguales)
    SELECT COUNT(*)
      INTO l_n
      FROM regla r
     WHERE r.id_tipo_regla = l_tr
       AND DECODE(r.id_tipo_vehiculo,        p_id_tipo_vehiculo,        1, 0) = 1
       AND DECODE(r.id_combustible,          p_id_combustible,          1, 0) = 1
       AND DECODE(r.id_tipo_periodo,         p_id_tipo_periodo,         1, 0) = 1
       AND DECODE(r.solo_fronteriza,         p_solo_fronteriza,         1, 0) = 1
       AND DECODE(r.id_categoria_cilindrada, p_id_categoria_cilindrada, 1, 0) = 1
       AND DECODE(r.id_departamento,         p_id_departamento,         1, 0) = 1
       AND r.fecha_inicio >= p_fecha_inicio;
    IF l_n > 0 THEN
      RAISE_APPLICATION_ERROR(-20102,
        'Ya existe una version de ' || p_codigo_regla ||
        ' para ese ambito con inicio igual o posterior a ' || TO_CHAR(p_fecha_inicio, 'YYYY-MM-DD HH24:MI:SS'));
    END IF;

    -- Cierra la version que siga abierta en la fecha de inicio de la nueva
    UPDATE regla r
       SET r.fecha_fin = p_fecha_inicio
     WHERE r.id_tipo_regla = l_tr
       AND DECODE(r.id_tipo_vehiculo,        p_id_tipo_vehiculo,        1, 0) = 1
       AND DECODE(r.id_combustible,          p_id_combustible,          1, 0) = 1
       AND DECODE(r.id_tipo_periodo,         p_id_tipo_periodo,         1, 0) = 1
       AND DECODE(r.solo_fronteriza,         p_solo_fronteriza,         1, 0) = 1
       AND DECODE(r.id_categoria_cilindrada, p_id_categoria_cilindrada, 1, 0) = 1
       AND DECODE(r.id_departamento,         p_id_departamento,         1, 0) = 1
       AND (r.fecha_fin IS NULL OR r.fecha_fin > p_fecha_inicio);

    INSERT INTO regla (id_tipo_regla, id_tipo_vehiculo, id_combustible, id_tipo_periodo,
                       solo_fronteriza, id_categoria_cilindrada, id_departamento,
                       valor, valor_secundario, gravedad, fecha_inicio, fecha_fin)
      VALUES (l_tr, p_id_tipo_vehiculo, p_id_combustible, p_id_tipo_periodo,
              p_solo_fronteriza, p_id_categoria_cilindrada, p_id_departamento,
              p_valor, p_valor_secundario, p_gravedad, p_fecha_inicio, NULL);
  END p_crear_version_regla;

END pkg_reglas;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Verificacion: el paquete compila y responde como dice el plan.
-- Las pruebas que escriben se hacen dentro de un SAVEPOINT y se
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
  l_c1100  NUMBER;
  l_c1600  NUMBER;
  l_c2000  NUMBER;
  l_pando  NUMBER;
  l_cbba   NUMBER;
  l_ficha  NUMBER;
  l_veh    NUMBER;
  l_ts     TIMESTAMP := TIMESTAMP '2026-11-18 15:30:00';

  PROCEDURE chequear(p_nombre IN VARCHAR2, p_ok IN BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      DBMS_OUTPUT.PUT_LINE('OK    ' || p_nombre);
    ELSE
      RAISE_APPLICATION_ERROR(-20999, '04_pkg_reglas: FALLO ' || p_nombre);
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

  FUNCTION regla_de(p_codigo IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN pkg_reglas.f_id_regla_vigente(p_codigo, l_ts);
  END regla_de;
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
  SELECT id_categoria_cilindrada INTO l_c1100 FROM categoria_cilindrada WHERE codigo = 'HASTA_1100';
  SELECT id_categoria_cilindrada INTO l_c1600 FROM categoria_cilindrada WHERE codigo = '1101_1600';
  SELECT id_categoria_cilindrada INTO l_c2000 FROM categoria_cilindrada WHERE codigo = '1601_2000';
  SELECT id_departamento INTO l_pando FROM departamento WHERE nombre = 'Pando';
  SELECT id_departamento INTO l_cbba  FROM departamento WHERE nombre = 'Cochabamba';
  l_dia := pkg_reglas.f_id_tipo_periodo('DIA');

  -- Periodos (2026-11-18 es miercoles; la semana ISO empieza el lunes 16)
  chequear('inicio DIA    = 2026-11-18', pkg_reglas.f_inicio_periodo(l_ts, 'DIA')    = TIMESTAMP '2026-11-18 00:00:00');
  chequear('inicio SEMANA = 2026-11-16', pkg_reglas.f_inicio_periodo(l_ts, 'SEMANA') = TIMESTAMP '2026-11-16 00:00:00');
  chequear('inicio MES    = 2026-11-01', pkg_reglas.f_inicio_periodo(l_ts, 'MES')    = TIMESTAMP '2026-11-01 00:00:00');
  chequear('fin DIA       = 2026-11-19', pkg_reglas.f_fin_periodo(l_ts, 'DIA')       = TIMESTAMP '2026-11-19 00:00:00');
  chequear('fin SEMANA    = 2026-11-23', pkg_reglas.f_fin_periodo(l_ts, 'SEMANA')    = TIMESTAMP '2026-11-23 00:00:00');
  chequear('fin MES       = 2026-12-01', pkg_reglas.f_fin_periodo(l_ts, 'MES')       = TIMESTAMP '2026-12-01 00:00:00');

  -- Categorias de cilindrada (limites inclusivos)
  chequear('1100 cc -> HASTA_1100', pkg_reglas.f_id_categoria_cilindrada(1100) = l_c1100);
  chequear('1101 cc -> 1101_1600',  pkg_reglas.f_id_categoria_cilindrada(1101) = l_c1600);
  chequear('2000 cc -> 1601_2000',  pkg_reglas.f_id_categoria_cilindrada(2000) = l_c2000);
  SELECT id_categoria_cilindrada INTO l_n FROM categoria_cilindrada WHERE codigo = 'MAS_3000';
  chequear('5000 cc -> MAS_3000',   pkg_reglas.f_id_categoria_cilindrada(5000) = l_n);
  chequear('NULL cc -> NULL',       pkg_reglas.f_id_categoria_cilindrada(NULL) IS NULL);

  -- Reglas temporales: cuota AUTO/gasolina/DIA (50 hasta 2026-07-01 exclusive, luego 40)
  chequear('cuota AUTO 2026-06-30 23:59:59 = 50',
    valor_de(pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', TIMESTAMP '2026-06-30 23:59:59', l_auto, l_gas, l_dia)) = 50);
  chequear('cuota AUTO 2026-07-01 00:00:00 = 40 (fin exclusivo)',
    valor_de(pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', TIMESTAMP '2026-07-01 00:00:00', l_auto, l_gas, l_dia)) = 40);

  -- Ambito geografico: departamento
  chequear('cuota AUTO en Pando = 30',
    valor_de(pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', l_ts, l_auto, l_gas, l_dia, 'N', NULL, l_pando)) = 30);
  chequear('cuota AUTO en Cochabamba = 40',
    valor_de(pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', l_ts, l_auto, l_gas, l_dia, 'N', NULL, l_cbba)) = 40);

  -- Prioridad de ambito: fronteriza > cilindrada > generica
  chequear('exceso AUTO 1600cc no fronteriza = 80',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', l_ts, l_auto, l_gas, l_dia, 'N', l_c1600)) = 80);
  chequear('exceso AUTO 1100cc no fronteriza = 50 (cilindrada)',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', l_ts, l_auto, l_gas, l_dia, 'N', l_c1100)) = 50);
  chequear('exceso AUTO 1100cc fronteriza = 60 (frontera gana)',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', l_ts, l_auto, l_gas, l_dia, 'S', l_c1100)) = 60);
  chequear('exceso AUTO sin cilindrada, fronteriza NULL = 80',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', l_ts, l_auto, l_gas, l_dia)) = 80);
  chequear('exceso MOTO fronteriza = 30',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', l_ts, l_moto, l_gas, l_dia, 'S')) = 30);

  -- Consumo esperado por tipo y cilindrada
  chequear('consumo esperado AUTO 1101_1600 = 8',
    valor_de(pkg_reglas.f_id_regla_vigente('CONSUMO_ESPERADO', l_ts, l_auto, NULL, NULL, NULL, l_c1600)) = 8);
  chequear('consumo esperado AUTO sin categoria = 9',
    valor_de(pkg_reglas.f_id_regla_vigente('CONSUMO_ESPERADO', l_ts, l_auto)) = 9);
  chequear('consumo esperado PESADO 1601_2000 cae a PESADO = 50',
    valor_de(pkg_reglas.f_id_regla_vigente('CONSUMO_ESPERADO', l_ts, l_pesado, NULL, NULL, NULL, l_c2000)) = 50);

  -- Sin regla aplicable -> NULL
  chequear('codigo inexistente -> NULL',
    pkg_reglas.f_id_regla_vigente('NO_EXISTE', l_ts, l_auto, l_gas, l_dia) IS NULL);
  chequear('cuota PESADO con gasolina -> NULL',
    pkg_reglas.f_id_regla_vigente('CUOTA_SUBVENCIONADA', l_ts, l_pesado, l_gas, l_dia) IS NULL);
  chequear('MAX_VEHICULOS_PERSONA = 2', valor_de(regla_de('MAX_VEHICULOS_PERSONA')) = 2);

  -- Bloqueantes: anomalia de transaccion con gravedad ALTA
  chequear('TANQUE_EXCEDIDO bloquea',       pkg_reglas.f_es_bloqueante(regla_de('TANQUE_EXCEDIDO')) = 'S');
  chequear('UBICACION_IMPOSIBLE bloquea',   pkg_reglas.f_es_bloqueante(regla_de('UBICACION_IMPOSIBLE')) = 'S');
  chequear('FRECUENCIA_CARGAS no bloquea',
    pkg_reglas.f_es_bloqueante(pkg_reglas.f_id_regla_vigente('FRECUENCIA_CARGAS', l_ts, NULL, NULL, l_dia)) = 'N');
  chequear('DESBALANCE_YPFB (estacion) no bloquea',
    pkg_reglas.f_es_bloqueante(pkg_reglas.f_id_regla_vigente('DESBALANCE_YPFB', l_ts, NULL, NULL,
                               pkg_reglas.f_id_tipo_periodo('SEMANA'))) = 'N');
  chequear('MAX_VEHICULOS_PERSONA no bloquea', pkg_reglas.f_es_bloqueante(regla_de('MAX_VEHICULOS_PERSONA')) = 'N');

  -- Precios
  chequear('precio INTERNACIONAL gasolina 2025-09-01 = 7.9',
    precio_de(pkg_reglas.f_id_precio_vigente(l_gas, 'INTERNACIONAL', TIMESTAMP '2025-09-01 00:00:00')) = 7.9);
  chequear('precio INTERNACIONAL gasolina 2026-01-01 = 8.2 (fin exclusivo)',
    precio_de(pkg_reglas.f_id_precio_vigente(l_gas, 'INTERNACIONAL', TIMESTAMP '2026-01-01 00:00:00')) = 8.2);
  chequear('Gasolina Premium sin SUBVENCIONADO -> NULL',
    pkg_reglas.f_id_precio_vigente(l_prem, 'SUBVENCIONADO', l_ts) IS NULL);

  -- Pruebas que escriben (se deshacen al final)
  SAVEPOINT sp_pkg_reglas;

  -- Consumo esperado de un vehiculo nacional de 1.600 cc y de uno extranjero
  INSERT INTO ficha_aduana (nro_chasis, id_combustible, marca, modelo, anio_fabricacion,
                            cilindrada, capacidad_tanque)
    VALUES ('PRUEBA-04-CHASIS', l_gas, 'Toyota', 'Corolla', 2018, 1600, 50)
    RETURNING id_ficha INTO l_ficha;
  INSERT INTO vehiculo (id_tipo_vehiculo, id_ficha, placa, pais_placa, codigo_rfid, fecha_registro)
    VALUES (l_auto, l_ficha, 'PRB-0401', 'BOL', 'RFID-PRB-0401', DATE '2026-01-01')
    RETURNING id_vehiculo INTO l_veh;
  chequear('consumo esperado vehiculo 1600cc = 8', pkg_reglas.f_consumo_esperado_dia(l_veh, l_ts) = 8);
  INSERT INTO vehiculo (id_tipo_vehiculo, placa, pais_placa, fecha_registro)
    VALUES (l_auto, 'PRB-0402', 'PER', DATE '2026-01-01')
    RETURNING id_vehiculo INTO l_veh;
  chequear('consumo esperado vehiculo extranjero = 9', pkg_reglas.f_consumo_esperado_dia(l_veh, l_ts) = 9);

  -- Versionado
  pkg_reglas.p_crear_version_regla('EXCESO_VOLUMEN', l_moto, l_gas, l_dia, NULL, NULL, NULL,
                                   25, NULL, 'MEDIA', DATE '2026-12-01');
  chequear('version nueva vigente el 2026-12-02 = 25',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', TIMESTAMP '2026-12-02 00:00:00', l_moto, l_gas, l_dia)) = 25);
  chequear('version anterior vigente el 2026-11-30 = 30',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', TIMESTAMP '2026-11-30 00:00:00', l_moto, l_gas, l_dia)) = 30);
  ROLLBACK TO sp_pkg_reglas;
  chequear('tras deshacer, el 2026-12-02 vuelve a 30',
    valor_de(pkg_reglas.f_id_regla_vigente('EXCESO_VOLUMEN', TIMESTAMP '2026-12-02 00:00:00', l_moto, l_gas, l_dia)) = 30);

  -- Una version con inicio igual o anterior a la vigente debe rechazarse (-20102)
  BEGIN
    pkg_reglas.p_crear_version_regla('EXCESO_VOLUMEN', l_moto, l_gas, l_dia, NULL, NULL, NULL,
                                     25, NULL, 'MEDIA', DATE '2026-01-01');
    chequear('rechaza version con inicio no posterior', FALSE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20102 THEN
        DBMS_OUTPUT.PUT_LINE('OK    rechaza version con inicio no posterior (-20102)');
      ELSE
        RAISE;
      END IF;
  END;

  -- Una anomalia sin gravedad debe rechazarse (-20012)
  BEGIN
    pkg_reglas.p_crear_version_regla('EXCESO_VOLUMEN', l_moto, l_gas, l_dia, NULL, NULL, NULL,
                                     25, NULL, NULL, DATE '2027-01-01');
    chequear('rechaza anomalia sin gravedad', FALSE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20012 THEN
        DBMS_OUTPUT.PUT_LINE('OK    rechaza anomalia sin gravedad (-20012)');
      ELSE
        RAISE;
      END IF;
  END;

  SELECT COUNT(*) INTO l_n FROM vehiculo;
  chequear('no quedaron datos de prueba', l_n = 0);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/
