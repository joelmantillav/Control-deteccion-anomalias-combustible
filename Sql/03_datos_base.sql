-- ============================================================
-- 03_datos_base.sql
-- Datos base: catalogos, precios, tipos de regla y reglas versionadas
-- Valores de EJEMPLO (no oficiales). Ver plan de implementacion, seccion 3.
-- NO es re-ejecutable (inserta datos). Para repetir: down -v y up -d.
-- Autor: <nombre>   Fecha: 2026-11-18
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ------------------------------------------------------------
-- 3.1 Catalogos
-- (los ids son identity; en otros scripts se buscan por clave natural)
-- ------------------------------------------------------------
INSERT INTO unidad_medida (nombre, simbolo) VALUES ('Litro', 'L');
INSERT INTO unidad_medida (nombre, simbolo) VALUES ('Metro cubico', 'm3');

INSERT INTO combustible (id_unidad, nombre)
  VALUES ((SELECT id_unidad FROM unidad_medida WHERE simbolo = 'L'),  'Gasolina Especial');
INSERT INTO combustible (id_unidad, nombre)
  VALUES ((SELECT id_unidad FROM unidad_medida WHERE simbolo = 'L'),  'Diesel Oil');
INSERT INTO combustible (id_unidad, nombre)
  VALUES ((SELECT id_unidad FROM unidad_medida WHERE simbolo = 'm3'), 'GNV');
INSERT INTO combustible (id_unidad, nombre)
  VALUES ((SELECT id_unidad FROM unidad_medida WHERE simbolo = 'L'),  'Gasolina Premium');

INSERT INTO tipo_vehiculo (nombre, descripcion) VALUES ('MOTO',   'Motocicletas y vehiculos de dos ruedas');
INSERT INTO tipo_vehiculo (nombre, descripcion) VALUES ('AUTO',   'Automoviles, camionetas y vehiculos livianos');
INSERT INTO tipo_vehiculo (nombre, descripcion) VALUES ('PESADO', 'Camiones, buses y vehiculos de carga pesada');

INSERT INTO tipo_periodo (codigo, nombre) VALUES ('DIA',    'Dia');
INSERT INTO tipo_periodo (codigo, nombre) VALUES ('SEMANA', 'Semana');
INSERT INTO tipo_periodo (codigo, nombre) VALUES ('MES',    'Mes');

-- ------------------------------------------------------------
-- 3.2 Precios (Bs, de ejemplo). Intervalo semiabierto [inicio, fin).
-- Gasolina Premium NO tiene precio SUBVENCIONADO a proposito
-- (sirve para probar el motivo SIN_SUBVENCION).
-- ------------------------------------------------------------
DECLARE
  PROCEDURE ins_precio(
    p_combustible IN VARCHAR2,
    p_tipo        IN VARCHAR2,
    p_precio      IN NUMBER,
    p_ini         IN DATE,
    p_fin         IN DATE DEFAULT NULL) IS
    l_id_comb NUMBER;
  BEGIN
    SELECT id_combustible INTO l_id_comb FROM combustible WHERE nombre = p_combustible;
    INSERT INTO precio_combustible (id_combustible, tipo_precio, precio_unitario, fecha_inicio, fecha_fin)
      VALUES (l_id_comb, p_tipo, p_precio, p_ini, p_fin);
  END ins_precio;
BEGIN
  ins_precio('Gasolina Especial', 'SUBVENCIONADO', 3.74, DATE '2026-01-01');
  ins_precio('Gasolina Especial', 'INTERNACIONAL', 7.90, DATE '2025-07-01', DATE '2026-01-01'); -- version cerrada
  ins_precio('Gasolina Especial', 'INTERNACIONAL', 8.20, DATE '2026-01-01');
  ins_precio('Diesel Oil',        'SUBVENCIONADO', 3.72, DATE '2026-01-01');
  ins_precio('Diesel Oil',        'INTERNACIONAL', 8.50, DATE '2026-01-01');
  ins_precio('GNV',               'SUBVENCIONADO', 1.66, DATE '2026-01-01');
  ins_precio('GNV',               'INTERNACIONAL', 3.50, DATE '2026-01-01');
  ins_precio('Gasolina Premium',  'INTERNACIONAL', 9.10, DATE '2026-01-01');
END;
/

-- ------------------------------------------------------------
-- 3.3 Tipos de regla (contrato de parametros: ver plan, seccion 3.3)
-- ------------------------------------------------------------
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'CUOTA_SUBVENCIONADA', 'Cuota subvencionada por vehiculo', 'PRECIO',
  'valor = cantidad maxima subvencionada por vehiculo y periodo, en la unidad del combustible. Lo que excede se cobra a precio internacional.');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'MAX_VEHICULOS_PERSONA', 'Maximo de vehiculos con beneficio por persona', 'REGISTRO',
  'valor = maximo de vehiculos con beneficio vigente que puede tener una persona.');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'MAX_RECIPIENTES_BIDON', 'Maximo de recipientes por compra de bidon', 'OPERATIVA',
  'valor = maximo de recipientes permitidos en una sola compra de bidon.');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'EXCESO_VOLUMEN', 'Exceso de volumen por vehiculo', 'ANOMALIA',
  'valor = cantidad total maxima por vehiculo en el periodo (DIA), sumando cualquier precio. Alerta al cruzar el umbral.');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'MULTIPLES_ESTACIONES', 'Cargas en multiples estaciones', 'ANOMALIA',
  'valor = maximo de estaciones distintas por vehiculo en el dia. Alerta cuando una carga nueva en una estacion nueva supera el valor.');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'FRECUENCIA_CARGAS', 'Frecuencia anormal de cargas', 'ANOMALIA',
  'valor = maximo de cargas por vehiculo en el periodo (DIA o SEMANA). Alerta en la carga numero valor + 1.');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'TANQUE_EXCEDIDO', 'Volumen incompatible con la capacidad del tanque', 'ANOMALIA',
  'valor = factor sobre capacidad_tanque (1.10 = 110 por ciento). valor_secundario = ventana en horas para sumar cargas del mismo vehiculo.');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'UBICACION_IMPOSIBLE', 'Cargas en estaciones distantes en tiempo imposible', 'ANOMALIA',
  'valor = factor sobre los minutos de tiempo_viaje (0.80 = alerta si transcurrio menos del 80 por ciento del tiempo de viaje estimado).');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'BIDON_SIN_PERMISO', 'Compra de bidon sin permiso', 'ANOMALIA',
  'Sin parametros. Alerta cuando una compra de bidon no tiene permiso ANH asociado.');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'BIDON_EXCEDE_PERMISO', 'Compra de bidon que excede el permiso', 'ANOMALIA',
  'Sin parametros. Alerta cuando una compra supera la cantidad autorizada por el permiso en el periodo.');
INSERT INTO tipo_regla (codigo, nombre, familia, descripcion) VALUES (
  'DESBALANCE_YPFB', 'Desbalance entre combustible recibido y vendido', 'ANOMALIA',
  'valor = tolerancia en por ciento. Alerta de estacion si vendido supera recibido * (1 + valor/100) en la semana.');

-- ------------------------------------------------------------
-- 3.4 Reglas versionadas. Intervalo semiabierto [inicio, fin).
-- Un ambito en NULL significa "aplica a todos".
-- La primera cuota de AUTO queda cerrada; la segunda es su version nueva
-- (sirve para demostrar reglas temporales).
-- Un nombre mal escrito falla con NO_DATA_FOUND (no inserta ambito en NULL).
-- ------------------------------------------------------------
DECLARE
  PROCEDURE ins_regla(
    p_codigo   IN VARCHAR2,
    p_tipo_veh IN VARCHAR2,
    p_comb     IN VARCHAR2,
    p_periodo  IN VARCHAR2,
    p_front    IN CHAR,
    p_valor    IN NUMBER,
    p_vsec     IN NUMBER,
    p_grav     IN VARCHAR2,
    p_ini      IN DATE,
    p_fin      IN DATE DEFAULT NULL) IS
    l_tr NUMBER;
    l_tv NUMBER;
    l_co NUMBER;
    l_pe NUMBER;
  BEGIN
    SELECT id_tipo_regla INTO l_tr FROM tipo_regla WHERE codigo = p_codigo;
    IF p_tipo_veh IS NOT NULL THEN
      SELECT id_tipo_vehiculo INTO l_tv FROM tipo_vehiculo WHERE nombre = p_tipo_veh;
    END IF;
    IF p_comb IS NOT NULL THEN
      SELECT id_combustible INTO l_co FROM combustible WHERE nombre = p_comb;
    END IF;
    IF p_periodo IS NOT NULL THEN
      SELECT id_tipo_periodo INTO l_pe FROM tipo_periodo WHERE codigo = p_periodo;
    END IF;
    INSERT INTO regla (id_tipo_regla, id_tipo_vehiculo, id_combustible, id_tipo_periodo,
                       solo_fronteriza, valor, valor_secundario, gravedad,
                       fecha_inicio, fecha_fin)
      VALUES (l_tr, l_tv, l_co, l_pe, p_front, p_valor, p_vsec, p_grav, p_ini, p_fin);
  END ins_regla;
BEGIN
  -- codigo, tipo veh., combustible, periodo, fronteriza, valor, valor_sec, gravedad, inicio [, fin]

  -- PRECIO: cuota subvencionada por dia
  ins_regla('CUOTA_SUBVENCIONADA', 'AUTO',   'Gasolina Especial', 'DIA', NULL, 50,  NULL, NULL, DATE '2026-01-01', DATE '2026-07-01');
  ins_regla('CUOTA_SUBVENCIONADA', 'AUTO',   'Gasolina Especial', 'DIA', NULL, 40,  NULL, NULL, DATE '2026-07-01');
  ins_regla('CUOTA_SUBVENCIONADA', 'MOTO',   'Gasolina Especial', 'DIA', NULL, 15,  NULL, NULL, DATE '2026-01-01');
  ins_regla('CUOTA_SUBVENCIONADA', 'PESADO', 'Diesel Oil',        'DIA', NULL, 200, NULL, NULL, DATE '2026-01-01');
  ins_regla('CUOTA_SUBVENCIONADA', 'AUTO',   'GNV',               'DIA', NULL, 20,  NULL, NULL, DATE '2026-01-01');

  -- REGISTRO y OPERATIVA
  ins_regla('MAX_VEHICULOS_PERSONA', NULL, NULL, NULL, NULL, 2, NULL, NULL, DATE '2026-01-01');
  ins_regla('MAX_RECIPIENTES_BIDON', NULL, NULL, NULL, NULL, 3, NULL, NULL, DATE '2026-01-01');

  -- ANOMALIA: exceso de volumen (la fronteriza es mas estricta y gana en frontera)
  ins_regla('EXCESO_VOLUMEN', 'AUTO',   'Gasolina Especial', 'DIA', NULL, 80,  NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('EXCESO_VOLUMEN', 'AUTO',   'Gasolina Especial', 'DIA', 'S',  60,  NULL, 'ALTA',  DATE '2026-01-01');
  ins_regla('EXCESO_VOLUMEN', 'MOTO',   'Gasolina Especial', 'DIA', NULL, 30,  NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('EXCESO_VOLUMEN', 'PESADO', 'Diesel Oil',        'DIA', NULL, 400, NULL, 'MEDIA', DATE '2026-01-01');

  -- ANOMALIA: estaciones, frecuencia, tanque, ubicacion
  ins_regla('MULTIPLES_ESTACIONES', NULL, NULL, 'DIA',    NULL, 2,    NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('FRECUENCIA_CARGAS',    NULL, NULL, 'DIA',    NULL, 3,    NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('FRECUENCIA_CARGAS',    NULL, NULL, 'SEMANA', NULL, 10,   NULL, 'BAJA',  DATE '2026-01-01');
  ins_regla('TANQUE_EXCEDIDO',      NULL, NULL, NULL,     NULL, 1.10, 3,    'ALTA',  DATE '2026-01-01');
  ins_regla('UBICACION_IMPOSIBLE',  NULL, NULL, NULL,     NULL, 0.80, NULL, 'ALTA',  DATE '2026-01-01');

  -- ANOMALIA: extendido (bidones y conciliacion YPFB)
  ins_regla('BIDON_SIN_PERMISO',    NULL, NULL, NULL,     NULL, NULL, NULL, 'ALTA',  DATE '2026-01-01');
  ins_regla('BIDON_EXCEDE_PERMISO', NULL, NULL, NULL,     NULL, NULL, NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('DESBALANCE_YPFB',      NULL, NULL, 'SEMANA', NULL, 5,    NULL, 'ALTA',  DATE '2026-01-01');
END;
/

COMMIT;

-- ------------------------------------------------------------
-- Verificacion: si algun conteo no coincide, se lanza un error
-- (queda visible en los logs del contenedor).
-- ------------------------------------------------------------
DECLARE
  PROCEDURE verificar(p_tabla IN VARCHAR2, p_esperado IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || p_tabla INTO l_n;
    DBMS_OUTPUT.PUT_LINE(RPAD(p_tabla, 20) || l_n || ' filas (esperado ' || p_esperado || ')');
    IF l_n <> p_esperado THEN
      RAISE_APPLICATION_ERROR(-20999, '03_datos_base: ' || p_tabla || ' tiene ' || l_n ||
                                      ' filas y se esperaban ' || p_esperado);
    END IF;
  END verificar;
BEGIN
  verificar('unidad_medida',      2);
  verificar('combustible',        4);
  verificar('tipo_vehiculo',      3);
  verificar('tipo_periodo',       3);
  verificar('precio_combustible', 8);
  verificar('tipo_regla',         11);
  verificar('regla',              19);
END;
/
