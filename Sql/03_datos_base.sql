-- ============================================================
-- 03_datos_base.sql
-- Datos base: catalogos, ubicacion, precios, tipos de regla y reglas
-- versionadas. Valores de EJEMPLO (no oficiales).
-- Lo que es dato de operacion (estaciones, vehiculos, personas,
-- transacciones) va en el script de datos simulados.
-- NO es re-ejecutable (inserta datos). Para repetir: down -v y up -d.
-- Autor: <nombre>   Fecha: 2026-11-18
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ------------------------------------------------------------
-- 1. Catalogos
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

-- Rangos de cilindrada [cc_min, cc_max] sin solaparse (enunciado 3.8:
-- comparar 1.100 cc, 1.600 cc, 2.000 cc y otras categorias)
INSERT INTO categoria_cilindrada (codigo, nombre, cc_min, cc_max) VALUES ('HASTA_1100', 'Hasta 1.100 cc',        0, 1100);
INSERT INTO categoria_cilindrada (codigo, nombre, cc_min, cc_max) VALUES ('1101_1600',  'De 1.101 a 1.600 cc', 1101, 1600);
INSERT INTO categoria_cilindrada (codigo, nombre, cc_min, cc_max) VALUES ('1601_2000',  'De 1.601 a 2.000 cc', 1601, 2000);
INSERT INTO categoria_cilindrada (codigo, nombre, cc_min, cc_max) VALUES ('2001_3000',  'De 2.001 a 3.000 cc', 2001, 3000);
INSERT INTO categoria_cilindrada (codigo, nombre, cc_min, cc_max) VALUES ('MAS_3000',   'Mas de 3.000 cc',     3001, NULL);

-- ------------------------------------------------------------
-- 2. Ubicacion: 9 departamentos y municipios donde habra estaciones
-- (Cochabamba con mas detalle; incluye municipios fronterizos)
-- ------------------------------------------------------------
DECLARE
  PROCEDURE ins_depto(p_nombre IN VARCHAR2) IS
  BEGIN
    INSERT INTO departamento (nombre) VALUES (p_nombre);
  END ins_depto;

  PROCEDURE ins_muni(p_depto IN VARCHAR2, p_nombre IN VARCHAR2) IS
    l_id NUMBER;
  BEGIN
    SELECT id_departamento INTO l_id FROM departamento WHERE nombre = p_depto;
    INSERT INTO municipio (id_departamento, nombre) VALUES (l_id, p_nombre);
  END ins_muni;
BEGIN
  ins_depto('Chuquisaca'); ins_depto('La Paz');  ins_depto('Cochabamba');
  ins_depto('Oruro');      ins_depto('Potosi');  ins_depto('Tarija');
  ins_depto('Santa Cruz'); ins_depto('Beni');    ins_depto('Pando');

  ins_muni('Cochabamba', 'Cochabamba');
  ins_muni('Cochabamba', 'Quillacollo');
  ins_muni('Cochabamba', 'Sacaba');
  ins_muni('Cochabamba', 'Colcapirhua');
  ins_muni('Cochabamba', 'Tiquipaya');
  ins_muni('Cochabamba', 'Vinto');
  ins_muni('Cochabamba', 'Sipe Sipe');
  ins_muni('Cochabamba', 'Punata');
  ins_muni('Cochabamba', 'Villa Tunari');
  ins_muni('Cochabamba', 'Chimore');
  ins_muni('Cochabamba', 'Puerto Villarroel');
  ins_muni('La Paz',     'La Paz');
  ins_muni('La Paz',     'El Alto');
  ins_muni('La Paz',     'Desaguadero');
  ins_muni('La Paz',     'Copacabana');
  ins_muni('Santa Cruz', 'Santa Cruz de la Sierra');
  ins_muni('Santa Cruz', 'Montero');
  ins_muni('Santa Cruz', 'Puerto Suarez');
  ins_muni('Santa Cruz', 'San Matias');
  ins_muni('Oruro',      'Oruro');
  ins_muni('Oruro',      'Sabaya');
  ins_muni('Potosi',     'Potosi');
  ins_muni('Potosi',     'Villazon');
  ins_muni('Potosi',     'Uyuni');
  ins_muni('Tarija',     'Tarija');
  ins_muni('Tarija',     'Yacuiba');
  ins_muni('Tarija',     'Bermejo');
  ins_muni('Chuquisaca', 'Sucre');
  ins_muni('Chuquisaca', 'Monteagudo');
  ins_muni('Beni',       'Trinidad');
  ins_muni('Beni',       'Guayaramerin');
  ins_muni('Beni',       'Riberalta');
  ins_muni('Pando',      'Cobija');
END;
/

-- ------------------------------------------------------------
-- 3. Precios (Bs, de ejemplo). Intervalo semiabierto [inicio, fin).
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
-- 4. Tipos de regla (contrato de parametros: ver plan, seccion 3)
-- Todas las anomalias de TRANSACCION generan una alerta en CADA carga
-- que las incumple (D-5). Si la version tiene gravedad ALTA, la carga
-- se BLOQUEA (D-2). Las de ESTACION solo alertan.
-- ------------------------------------------------------------
DECLARE
  PROCEDURE ins_tipo(p_codigo IN VARCHAR2, p_nombre IN VARCHAR2, p_familia IN VARCHAR2,
                     p_evaluacion IN VARCHAR2, p_desc IN VARCHAR2) IS
  BEGIN
    INSERT INTO tipo_regla (codigo, nombre, familia, evaluacion, descripcion)
      VALUES (p_codigo, p_nombre, p_familia, p_evaluacion, p_desc);
  END ins_tipo;
BEGIN
  -- PRECIO / REGISTRO / OPERATIVA
  ins_tipo('CUOTA_SUBVENCIONADA', 'Cuota subvencionada por vehiculo', 'PRECIO', NULL,
    'valor = cantidad maxima subvencionada por vehiculo y periodo, en la unidad del combustible. Lo que excede se cobra a precio internacional.');
  ins_tipo('MAX_VEHICULOS_PERSONA', 'Maximo de vehiculos con beneficio por persona', 'REGISTRO', NULL,
    'valor = maximo de vehiculos con beneficio vigente que puede tener una persona.');
  ins_tipo('MAX_RECIPIENTES_BIDON', 'Maximo de recipientes por compra de bidon', 'OPERATIVA', NULL,
    'valor = maximo de recipientes permitidos en una sola compra de bidon.');

  -- REFERENCIA
  ins_tipo('CONSUMO_ESPERADO', 'Consumo diario esperado', 'REFERENCIA', NULL,
    'valor = consumo esperado por dia de un vehiculo, en la unidad de su combustible, segun tipo de vehiculo y categoria de cilindrada.');

  -- ANOMALIA de transaccion
  ins_tipo('EXCESO_VOLUMEN', 'Exceso de volumen por vehiculo', 'ANOMALIA', 'TRANSACCION',
    'valor = cantidad total maxima por vehiculo en el periodo, sumando cualquier precio e incluyendo la carga actual.');
  ins_tipo('MULTIPLES_ESTACIONES', 'Cargas en multiples estaciones', 'ANOMALIA', 'TRANSACCION',
    'valor = maximo de estaciones distintas por vehiculo en el periodo, incluyendo la de la carga actual.');
  ins_tipo('FRECUENCIA_CARGAS', 'Frecuencia anormal de cargas', 'ANOMALIA', 'TRANSACCION',
    'valor = maximo de cargas por vehiculo en el periodo (DIA o SEMANA), incluyendo la actual.');
  ins_tipo('TANQUE_EXCEDIDO', 'Volumen incompatible con el tanque en ventana corta', 'ANOMALIA', 'TRANSACCION',
    'valor = factor sobre capacidad_tanque (1.10 = 110 por ciento). valor_secundario = ventana movil en horas hacia atras.');
  ins_tipo('TANQUE_ACUMULADO', 'Acumulado de varias veces el tanque en 24 horas', 'ANOMALIA', 'TRANSACCION',
    'valor = factor sobre capacidad_tanque (2 = dos tanques). valor_secundario = ventana movil en horas hacia atras.');
  ins_tipo('UBICACION_IMPOSIBLE', 'Cargas en estaciones distantes en tiempo imposible', 'ANOMALIA', 'TRANSACCION',
    'valor = factor sobre los minutos de tiempo_viaje (0.80 = incumple si transcurrio menos del 80 por ciento del tiempo estimado).');
  ins_tipo('CONSUMO_VS_ESPERADO', 'Consumo real superior al esperado', 'ANOMALIA', 'TRANSACCION',
    'valor = factor (1.5 = 50 por ciento mas). Incumple si el consumo del vehiculo en el periodo supera CONSUMO_ESPERADO * dias del periodo * valor.');
  ins_tipo('CONCENTRACION_PROPIETARIO', 'Persona que usa varios vehiculos', 'ANOMALIA', 'TRANSACCION',
    'valor = maximo de vehiculos distintos con los que una misma persona carga en el periodo, incluyendo la carga actual.');
  ins_tipo('BIDON_SIN_PERMISO', 'Compra de bidon sin permiso', 'ANOMALIA', 'TRANSACCION',
    'Sin parametros. Incumple cuando una compra de bidon no tiene permiso ANH vigente.');
  ins_tipo('BIDON_EXCEDE_PERMISO', 'Compra de bidon que excede el permiso', 'ANOMALIA', 'TRANSACCION',
    'Sin parametros. Incumple cuando lo comprado en el periodo del permiso supera la cantidad autorizada.');

  -- ANOMALIA de estacion
  ins_tipo('DESBALANCE_YPFB', 'Desbalance entre combustible recibido y vendido', 'ANOMALIA', 'ESTACION',
    'valor = tolerancia en por ciento. Incumple si en el periodo lo vendido supera lo recibido mas el saldo al inicio, en mas de valor por ciento.');
END;
/

-- ------------------------------------------------------------
-- 5. Reglas versionadas. Intervalo semiabierto [inicio, fin).
-- Un ambito en NULL significa "aplica a todos". Si varias aplican, gana
-- la de mayor prioridad de ambito: fronteriza (32) > departamento (16) >
-- categoria de cilindrada (8) > tipo de vehiculo (4) > combustible (2) >
-- periodo (1); empate: inicio mas reciente, luego id mayor.
-- La primera cuota de AUTO queda cerrada; la segunda es su version nueva
-- (sirve para demostrar reglas temporales).
-- Un nombre mal escrito falla con NO_DATA_FOUND (no inserta ambito en NULL).
-- ------------------------------------------------------------
DECLARE
  PROCEDURE ins_regla(
    p_codigo    IN VARCHAR2,
    p_tipo_veh  IN VARCHAR2,
    p_comb      IN VARCHAR2,
    p_periodo   IN VARCHAR2,
    p_front     IN CHAR,
    p_categoria IN VARCHAR2,
    p_depto     IN VARCHAR2,
    p_valor     IN NUMBER,
    p_vsec      IN NUMBER,
    p_grav      IN VARCHAR2,
    p_ini       IN DATE,
    p_fin       IN DATE DEFAULT NULL) IS
    l_tr NUMBER;
    l_tv NUMBER;
    l_co NUMBER;
    l_pe NUMBER;
    l_ca NUMBER;
    l_de NUMBER;
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
    IF p_categoria IS NOT NULL THEN
      SELECT id_categoria_cilindrada INTO l_ca FROM categoria_cilindrada WHERE codigo = p_categoria;
    END IF;
    IF p_depto IS NOT NULL THEN
      SELECT id_departamento INTO l_de FROM departamento WHERE nombre = p_depto;
    END IF;
    INSERT INTO regla (id_tipo_regla, id_tipo_vehiculo, id_combustible, id_tipo_periodo,
                       solo_fronteriza, id_categoria_cilindrada, id_departamento,
                       valor, valor_secundario, gravedad, fecha_inicio, fecha_fin)
      VALUES (l_tr, l_tv, l_co, l_pe, p_front, l_ca, l_de,
              p_valor, p_vsec, p_grav, p_ini, p_fin);
  END ins_regla;
BEGIN
  -- codigo, tipo veh., combustible, periodo, fronteriza, categoria cc, departamento,
  -- valor, valor_sec, gravedad, inicio [, fin]

  -- PRECIO: cuota subvencionada por dia
  ins_regla('CUOTA_SUBVENCIONADA', 'AUTO',   'Gasolina Especial', 'DIA', NULL, NULL, NULL,    50,  NULL, NULL, DATE '2026-01-01', DATE '2026-07-01');
  ins_regla('CUOTA_SUBVENCIONADA', 'AUTO',   'Gasolina Especial', 'DIA', NULL, NULL, NULL,    40,  NULL, NULL, DATE '2026-07-01');
  ins_regla('CUOTA_SUBVENCIONADA', 'MOTO',   'Gasolina Especial', 'DIA', NULL, NULL, NULL,    15,  NULL, NULL, DATE '2026-01-01');
  ins_regla('CUOTA_SUBVENCIONADA', 'PESADO', 'Diesel Oil',        'DIA', NULL, NULL, NULL,    200, NULL, NULL, DATE '2026-01-01');
  ins_regla('CUOTA_SUBVENCIONADA', 'AUTO',   'GNV',               'DIA', NULL, NULL, NULL,    20,  NULL, NULL, DATE '2026-01-01');
  -- Ambito geografico: departamento de alto riesgo de contrabando, cuota menor
  ins_regla('CUOTA_SUBVENCIONADA', 'AUTO',   'Gasolina Especial', 'DIA', NULL, NULL, 'Pando', 30,  NULL, NULL, DATE '2026-01-01');

  -- REGISTRO y OPERATIVA
  ins_regla('MAX_VEHICULOS_PERSONA', NULL, NULL, NULL, NULL, NULL, NULL, 2, NULL, NULL, DATE '2026-01-01');
  ins_regla('MAX_RECIPIENTES_BIDON', NULL, NULL, NULL, NULL, NULL, NULL, 3, NULL, NULL, DATE '2026-01-01');

  -- REFERENCIA: consumo esperado por dia (por tipo; por tipo y cilindrada)
  ins_regla('CONSUMO_ESPERADO', 'MOTO',   NULL, NULL, NULL, NULL,        NULL, 3,  NULL, NULL, DATE '2026-01-01');
  ins_regla('CONSUMO_ESPERADO', 'AUTO',   NULL, NULL, NULL, NULL,        NULL, 9,  NULL, NULL, DATE '2026-01-01');
  ins_regla('CONSUMO_ESPERADO', 'PESADO', NULL, NULL, NULL, NULL,        NULL, 50, NULL, NULL, DATE '2026-01-01');
  ins_regla('CONSUMO_ESPERADO', 'AUTO',   NULL, NULL, NULL, 'HASTA_1100', NULL, 6,  NULL, NULL, DATE '2026-01-01');
  ins_regla('CONSUMO_ESPERADO', 'AUTO',   NULL, NULL, NULL, '1101_1600',  NULL, 8,  NULL, NULL, DATE '2026-01-01');
  ins_regla('CONSUMO_ESPERADO', 'AUTO',   NULL, NULL, NULL, '1601_2000',  NULL, 10, NULL, NULL, DATE '2026-01-01');
  ins_regla('CONSUMO_ESPERADO', 'AUTO',   NULL, NULL, NULL, '2001_3000',  NULL, 13, NULL, NULL, DATE '2026-01-01');
  ins_regla('CONSUMO_ESPERADO', 'AUTO',   NULL, NULL, NULL, 'MAS_3000',   NULL, 16, NULL, NULL, DATE '2026-01-01');
  ins_regla('CONSUMO_ESPERADO', 'PESADO', NULL, NULL, NULL, 'MAS_3000',   NULL, 60, NULL, NULL, DATE '2026-01-01');

  -- ANOMALIA (transaccion): exceso de volumen
  -- la fronteriza es mas estricta y ALTA (bloquea); la de cilindrada baja es mas estricta pero MEDIA
  ins_regla('EXCESO_VOLUMEN', 'AUTO',   'Gasolina Especial', 'DIA', NULL, NULL,         NULL, 80,  NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('EXCESO_VOLUMEN', 'AUTO',   'Gasolina Especial', 'DIA', 'S',  NULL,         NULL, 60,  NULL, 'ALTA',  DATE '2026-01-01');
  ins_regla('EXCESO_VOLUMEN', 'AUTO',   'Gasolina Especial', 'DIA', NULL, 'HASTA_1100', NULL, 50,  NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('EXCESO_VOLUMEN', 'MOTO',   'Gasolina Especial', 'DIA', NULL, NULL,         NULL, 30,  NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('EXCESO_VOLUMEN', 'PESADO', 'Diesel Oil',        'DIA', NULL, NULL,         NULL, 400, NULL, 'MEDIA', DATE '2026-01-01');

  -- ANOMALIA (transaccion): estaciones, frecuencia, tanque, ubicacion
  ins_regla('MULTIPLES_ESTACIONES', NULL, NULL, 'DIA',    NULL, NULL, NULL, 2,    NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('FRECUENCIA_CARGAS',    NULL, NULL, 'DIA',    NULL, NULL, NULL, 3,    NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('FRECUENCIA_CARGAS',    NULL, NULL, 'SEMANA', NULL, NULL, NULL, 10,   NULL, 'BAJA',  DATE '2026-01-01');
  ins_regla('TANQUE_EXCEDIDO',      NULL, NULL, NULL,     NULL, NULL, NULL, 1.10, 3,    'ALTA',  DATE '2026-01-01');
  ins_regla('TANQUE_ACUMULADO',     NULL, NULL, NULL,     NULL, NULL, NULL, 2,    24,   'ALTA',  DATE '2026-01-01');
  ins_regla('UBICACION_IMPOSIBLE',  NULL, NULL, NULL,     NULL, NULL, NULL, 0.80, NULL, 'ALTA',  DATE '2026-01-01');

  -- ANOMALIA (transaccion): consumo y concentracion
  ins_regla('CONSUMO_VS_ESPERADO',       NULL, NULL, 'SEMANA', NULL, NULL, NULL, 1.5, NULL, 'MEDIA', DATE '2026-01-01');
  ins_regla('CONCENTRACION_PROPIETARIO', NULL, NULL, 'SEMANA', NULL, NULL, NULL, 3,   NULL, 'MEDIA', DATE '2026-01-01');

  -- ANOMALIA (transaccion): bidones
  ins_regla('BIDON_SIN_PERMISO',    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'ALTA',  DATE '2026-01-01');
  ins_regla('BIDON_EXCEDE_PERMISO', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'MEDIA', DATE '2026-01-01');

  -- ANOMALIA (estacion): conciliacion YPFB
  ins_regla('DESBALANCE_YPFB', NULL, NULL, 'SEMANA', NULL, NULL, NULL, 5, NULL, 'ALTA', DATE '2026-01-01');
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
    DBMS_OUTPUT.PUT_LINE(RPAD(p_tabla, 22) || l_n || ' filas (esperado ' || p_esperado || ')');
    IF l_n <> p_esperado THEN
      RAISE_APPLICATION_ERROR(-20999, '03_datos_base: ' || p_tabla || ' tiene ' || l_n ||
                                      ' filas y se esperaban ' || p_esperado);
    END IF;
  END verificar;
BEGIN
  verificar('unidad_medida',         2);
  verificar('combustible',           4);
  verificar('tipo_vehiculo',         3);
  verificar('tipo_periodo',          3);
  verificar('categoria_cilindrada',  5);
  verificar('departamento',          9);
  verificar('municipio',             33);
  verificar('precio_combustible',    8);
  verificar('tipo_regla',            15);
  verificar('regla',                 33);
END;
/
