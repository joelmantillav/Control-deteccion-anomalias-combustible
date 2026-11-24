-- ============================================================
-- 10_triggers.sql
-- Triggers de integridad, inmutabilidad y bitacora.
-- La deteccion de anomalias NO vive en triggers (tabla mutante y
-- visibilidad de las especializaciones): vive en pkg_deteccion, llamada
-- por pkg_transacciones. Aqui solo se protegen reglas que ninguna
-- restriccion CHECK/FK puede expresar.
-- Re-ejecutable (CREATE OR REPLACE TRIGGER).
-- Errores:
--   -20101 gravedad inconsistente con la familia de la regla
--   -20102 vigencias de regla solapadas
--   -20103 especializacion que no corresponde al tipo de transaccion
--   -20104 beneficio que supera MAX_VEHICULOS_PERSONA o con regla equivocada
--   -20105 beneficio a quien no es propietario RUAT vigente o sin huella ACTIVA
--   -20106 modificar o borrar historial de operaciones
--   -20107 modificar una alerta fuera de su revision, o borrarla
--   -20108 modificar o borrar una version de regla ya aplicada
--   -20109 rangos de cilindrada solapados
--   -20110 detalle en una transaccion BLOQUEADA
--   -20111 reclamo con recepcion de otra estacion o combustible
--   -20112 modificar o borrar bitacoras
--   -20113 precios solapados
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ============================================================
-- A. REGLAS, PRECIOS Y CATEGORIAS
-- ============================================================

-- A1. Gravedad obligatoria solo en reglas de familia ANOMALIA
CREATE OR REPLACE TRIGGER trg_regla_gravedad
  BEFORE INSERT OR UPDATE OF id_tipo_regla, gravedad ON regla
  FOR EACH ROW
DECLARE
  l_familia tipo_regla.familia%TYPE;
BEGIN
  SELECT familia INTO l_familia FROM tipo_regla WHERE id_tipo_regla = :NEW.id_tipo_regla;
  IF (l_familia = 'ANOMALIA' AND :NEW.gravedad IS NULL)
     OR (l_familia <> 'ANOMALIA' AND :NEW.gravedad IS NOT NULL) THEN
    RAISE_APPLICATION_ERROR(-20101, 'La gravedad es obligatoria solo en reglas ANOMALIA (familia '
                                    || l_familia || ', gravedad ' || NVL(:NEW.gravedad, 'NULL') || ')');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;  -- tipo de regla inexistente: lo rechaza la clave foranea
END;
/
SHOW ERRORS

-- A2. Dos versiones del mismo tipo y ambito (6 campos, NULL = NULL) no
--     pueden tener vigencias solapadas. Nivel de sentencia: puede leer
--     la tabla completa sin error de tabla mutante.
CREATE OR REPLACE TRIGGER trg_regla_solapamiento
  AFTER INSERT OR UPDATE ON regla
DECLARE
  l_codigo tipo_regla.codigo%TYPE;
  l_a      NUMBER;
  l_b      NUMBER;
BEGIN
  SELECT tr.codigo, a.id_regla, b.id_regla
    INTO l_codigo, l_a, l_b
    FROM regla a
    JOIN regla b       ON b.id_tipo_regla = a.id_tipo_regla AND b.id_regla > a.id_regla
    JOIN tipo_regla tr ON tr.id_tipo_regla = a.id_tipo_regla
   WHERE DECODE(a.id_tipo_vehiculo,        b.id_tipo_vehiculo,        1, 0) = 1
     AND DECODE(a.id_combustible,          b.id_combustible,          1, 0) = 1
     AND DECODE(a.id_tipo_periodo,         b.id_tipo_periodo,         1, 0) = 1
     AND DECODE(a.solo_fronteriza,         b.solo_fronteriza,         1, 0) = 1
     AND DECODE(a.id_categoria_cilindrada, b.id_categoria_cilindrada, 1, 0) = 1
     AND DECODE(a.id_departamento,         b.id_departamento,         1, 0) = 1
     AND a.fecha_inicio < NVL(b.fecha_fin, DATE '9999-12-31')
     AND b.fecha_inicio < NVL(a.fecha_fin, DATE '9999-12-31')
     AND ROWNUM = 1;
  RAISE_APPLICATION_ERROR(-20102, 'Vigencias solapadas en ' || l_codigo || ': reglas '
                                  || l_a || ' y ' || l_b || ' (usar pkg_reglas.p_crear_version_regla)');
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;  -- sin solapes
END;
/
SHOW ERRORS

-- A3. Una version de regla no se edita: solo se puede cerrar (fijar o
--     adelantar fecha_fin, sin reabrirla). Solo se borra si todavia no
--     empezo a regir. Cambiar una regla = crear una version nueva.
CREATE OR REPLACE TRIGGER trg_regla_inmutable
  BEFORE UPDATE OR DELETE ON regla
  FOR EACH ROW
DECLARE
  FUNCTION cambio(p_a IN NUMBER, p_b IN NUMBER) RETURN BOOLEAN IS
  BEGIN
    RETURN (p_a <> p_b) OR (p_a IS NULL AND p_b IS NOT NULL) OR (p_a IS NOT NULL AND p_b IS NULL);
  END cambio;
  FUNCTION cambio(p_a IN VARCHAR2, p_b IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN (p_a <> p_b) OR (p_a IS NULL AND p_b IS NOT NULL) OR (p_a IS NOT NULL AND p_b IS NULL);
  END cambio;
  FUNCTION cambio(p_a IN DATE, p_b IN DATE) RETURN BOOLEAN IS
  BEGIN
    RETURN (p_a <> p_b) OR (p_a IS NULL AND p_b IS NOT NULL) OR (p_a IS NOT NULL AND p_b IS NULL);
  END cambio;
BEGIN
  IF DELETING THEN
    IF :OLD.fecha_inicio <= SYSDATE THEN
      RAISE_APPLICATION_ERROR(-20108, 'La regla ' || :OLD.id_regla
                                      || ' ya empezo a regir: no se borra, se cierra con fecha_fin');
    END IF;
    RETURN;
  END IF;

  IF cambio(:OLD.id_tipo_regla, :NEW.id_tipo_regla)
     OR cambio(:OLD.id_tipo_vehiculo, :NEW.id_tipo_vehiculo)
     OR cambio(:OLD.id_combustible, :NEW.id_combustible)
     OR cambio(:OLD.id_tipo_periodo, :NEW.id_tipo_periodo)
     OR cambio(:OLD.solo_fronteriza, :NEW.solo_fronteriza)
     OR cambio(:OLD.id_categoria_cilindrada, :NEW.id_categoria_cilindrada)
     OR cambio(:OLD.id_departamento, :NEW.id_departamento)
     OR cambio(:OLD.valor, :NEW.valor)
     OR cambio(:OLD.valor_secundario, :NEW.valor_secundario)
     OR cambio(:OLD.gravedad, :NEW.gravedad)
     OR cambio(:OLD.fecha_inicio, :NEW.fecha_inicio) THEN
    RAISE_APPLICATION_ERROR(-20108, 'La regla ' || :OLD.id_regla || ' no se modifica: '
                                    || 'cree una version nueva con pkg_reglas.p_crear_version_regla');
  END IF;
  IF :OLD.fecha_fin IS NOT NULL AND :NEW.fecha_fin IS NULL THEN
    RAISE_APPLICATION_ERROR(-20108, 'La regla ' || :OLD.id_regla || ' ya estaba cerrada: no se reabre');
  END IF;
END;
/
SHOW ERRORS

-- A4. Precios del mismo combustible y tipo sin vigencias solapadas
CREATE OR REPLACE TRIGGER trg_precio_solapamiento
  AFTER INSERT OR UPDATE ON precio_combustible
DECLARE
  l_a NUMBER;
  l_b NUMBER;
BEGIN
  SELECT a.id_precio, b.id_precio
    INTO l_a, l_b
    FROM precio_combustible a
    JOIN precio_combustible b
      ON b.id_combustible = a.id_combustible
     AND b.tipo_precio    = a.tipo_precio
     AND b.id_precio      > a.id_precio
   WHERE a.fecha_inicio < NVL(b.fecha_fin, DATE '9999-12-31')
     AND b.fecha_inicio < NVL(a.fecha_fin, DATE '9999-12-31')
     AND ROWNUM = 1;
  RAISE_APPLICATION_ERROR(-20113, 'Precios con vigencias solapadas: ' || l_a || ' y ' || l_b);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;
END;
/
SHOW ERRORS

-- A5. Rangos de cilindrada [cc_min, cc_max] sin solaparse
CREATE OR REPLACE TRIGGER trg_categoria_cil_solape
  AFTER INSERT OR UPDATE ON categoria_cilindrada
DECLARE
  l_a categoria_cilindrada.codigo%TYPE;
  l_b categoria_cilindrada.codigo%TYPE;
BEGIN
  SELECT a.codigo, b.codigo
    INTO l_a, l_b
    FROM categoria_cilindrada a
    JOIN categoria_cilindrada b ON b.id_categoria_cilindrada > a.id_categoria_cilindrada
   WHERE a.cc_min <= NVL(b.cc_max, 999999)
     AND b.cc_min <= NVL(a.cc_max, 999999)
     AND ROWNUM = 1;
  RAISE_APPLICATION_ERROR(-20109, 'Rangos de cilindrada solapados: ' || l_a || ' y ' || l_b);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;
END;
/
SHOW ERRORS

-- ============================================================
-- B. OPERACIONES
-- ============================================================

-- B1. carga_vehicular solo para transacciones VEHICULAR
CREATE OR REPLACE TRIGGER trg_carga_vehicular_tipo
  BEFORE INSERT ON carga_vehicular
  FOR EACH ROW
DECLARE
  l_tipo transaccion.tipo_transaccion%TYPE;
BEGIN
  SELECT tipo_transaccion INTO l_tipo FROM transaccion WHERE id_transaccion = :NEW.id_transaccion;
  IF l_tipo <> 'VEHICULAR' THEN
    RAISE_APPLICATION_ERROR(-20103, 'La transaccion ' || :NEW.id_transaccion || ' es ' || l_tipo
                                    || ': no puede tener carga vehicular');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;  -- lo rechaza la clave foranea
END;
/
SHOW ERRORS

-- B2. compra_bidon solo para transacciones BIDON
CREATE OR REPLACE TRIGGER trg_compra_bidon_tipo
  BEFORE INSERT ON compra_bidon
  FOR EACH ROW
DECLARE
  l_tipo transaccion.tipo_transaccion%TYPE;
BEGIN
  SELECT tipo_transaccion INTO l_tipo FROM transaccion WHERE id_transaccion = :NEW.id_transaccion;
  IF l_tipo <> 'BIDON' THEN
    RAISE_APPLICATION_ERROR(-20103, 'La transaccion ' || :NEW.id_transaccion || ' es ' || l_tipo
                                    || ': no puede tener compra de bidon');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;
END;
/
SHOW ERRORS

-- B3. Una transaccion BLOQUEADA no despacha: no tiene lineas de precio
CREATE OR REPLACE TRIGGER trg_detalle_aprobada
  BEFORE INSERT ON detalle_transaccion
  FOR EACH ROW
DECLARE
  l_estado transaccion.estado%TYPE;
BEGIN
  SELECT estado INTO l_estado FROM transaccion WHERE id_transaccion = :NEW.id_transaccion;
  IF l_estado <> 'APROBADA' THEN
    RAISE_APPLICATION_ERROR(-20110, 'La transaccion ' || :NEW.id_transaccion
                                    || ' esta ' || l_estado || ': no puede tener detalle');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;
END;
/
SHOW ERRORS

-- B4. El historial de operaciones es inmutable (nivel de sentencia: se
--     rechaza cualquier intento, aunque no afecte filas)
CREATE OR REPLACE TRIGGER trg_transaccion_inmutable
  BEFORE UPDATE OR DELETE ON transaccion
BEGIN
  RAISE_APPLICATION_ERROR(-20106, 'Las transacciones no se modifican ni se borran');
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_carga_vehicular_inmutable
  BEFORE UPDATE OR DELETE ON carga_vehicular
BEGIN
  RAISE_APPLICATION_ERROR(-20106, 'Las cargas vehiculares no se modifican ni se borran');
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_compra_bidon_inmutable
  BEFORE UPDATE OR DELETE ON compra_bidon
BEGIN
  RAISE_APPLICATION_ERROR(-20106, 'Las compras de bidon no se modifican ni se borran');
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_detalle_inmutable
  BEFORE UPDATE OR DELETE ON detalle_transaccion
BEGIN
  RAISE_APPLICATION_ERROR(-20106, 'El detalle de las transacciones no se modifica ni se borra');
END;
/
SHOW ERRORS

-- ============================================================
-- C. BENEFICIOS
-- ============================================================

-- C1. El titular del beneficio es el propietario RUAT vigente del vehiculo
--     en la fecha de inicio y tiene huella ACTIVA; la regla referida es
--     una version de MAX_VEHICULOS_PERSONA.
CREATE OR REPLACE TRIGGER trg_beneficio_propietario
  BEFORE INSERT OR UPDATE OF id_vehiculo, id_persona, id_regla, fecha_inicio ON registro_beneficio
  FOR EACH ROW
DECLARE
  l_n      NUMBER;
  l_codigo tipo_regla.codigo%TYPE;
BEGIN
  SELECT tr.codigo INTO l_codigo
    FROM regla r JOIN tipo_regla tr ON tr.id_tipo_regla = r.id_tipo_regla
   WHERE r.id_regla = :NEW.id_regla;
  IF l_codigo <> 'MAX_VEHICULOS_PERSONA' THEN
    RAISE_APPLICATION_ERROR(-20104, 'El beneficio debe referir una version de MAX_VEHICULOS_PERSONA, no '
                                    || l_codigo);
  END IF;

  SELECT COUNT(*) INTO l_n
    FROM registro_ruat
   WHERE id_vehiculo  = :NEW.id_vehiculo
     AND id_persona   = :NEW.id_persona
     AND fecha_alta  <= :NEW.fecha_inicio
     AND (fecha_baja IS NULL OR :NEW.fecha_inicio < fecha_baja);
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20105, 'La persona ' || :NEW.id_persona || ' no es propietaria RUAT del vehiculo '
                                    || :NEW.id_vehiculo || ' en ' || TO_CHAR(:NEW.fecha_inicio, 'YYYY-MM-DD'));
  END IF;

  SELECT COUNT(*) INTO l_n
    FROM huella_digital
   WHERE id_persona = :NEW.id_persona AND estado = 'ACTIVA';
  IF l_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20105, 'La persona ' || :NEW.id_persona || ' no tiene huella ACTIVA');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;  -- regla inexistente: lo rechaza la clave foranea
END;
/
SHOW ERRORS

-- C2. Una persona no puede tener mas beneficios abiertos que el valor de
--     MAX_VEHICULOS_PERSONA (nivel de sentencia: cuenta toda la tabla)
CREATE OR REPLACE TRIGGER trg_beneficio_max_vehiculos
  AFTER INSERT OR UPDATE ON registro_beneficio
DECLARE
  l_persona NUMBER;
  l_n       NUMBER;
  l_max     NUMBER;
BEGIN
  SELECT id_persona, n, maximo
    INTO l_persona, l_n, l_max
    FROM (SELECT b.id_persona, COUNT(*) AS n, MIN(r.valor) AS maximo
            FROM registro_beneficio b
            JOIN regla r ON r.id_regla = b.id_regla
           WHERE b.fecha_fin IS NULL
           GROUP BY b.id_persona
          HAVING COUNT(*) > MIN(r.valor))
   WHERE ROWNUM = 1;
  RAISE_APPLICATION_ERROR(-20104, 'La persona ' || l_persona || ' tendria ' || l_n
                                  || ' beneficios abiertos (maximo ' || l_max || ')');
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;
END;
/
SHOW ERRORS

-- ============================================================
-- D. ALERTAS Y CALIDAD
-- ============================================================

-- D1. Una alerta es evidencia: no se borra; solo cambian los campos de
--     revision, y una vez REVISADA ya no cambia.
CREATE OR REPLACE TRIGGER trg_alerta_revision
  BEFORE UPDATE OR DELETE ON alerta
  FOR EACH ROW
BEGIN
  IF DELETING THEN
    RAISE_APPLICATION_ERROR(-20107, 'Las alertas no se borran (alerta ' || :OLD.id_alerta || ')');
  END IF;
  IF :OLD.estado_revision = 'REVISADA' THEN
    RAISE_APPLICATION_ERROR(-20107, 'La alerta ' || :OLD.id_alerta || ' ya fue revisada: no se modifica');
  END IF;
  IF :NEW.id_regla <> :OLD.id_regla
     OR NVL(:NEW.id_transaccion, -1) <> NVL(:OLD.id_transaccion, -1)
     OR NVL(:NEW.id_estacion, -1)    <> NVL(:OLD.id_estacion, -1)
     OR NVL(:NEW.periodo_inicio, DATE '1900-01-01') <> NVL(:OLD.periodo_inicio, DATE '1900-01-01')
     OR :NEW.fecha_deteccion <> :OLD.fecha_deteccion
     OR NVL(:NEW.valor_observado, -1) <> NVL(:OLD.valor_observado, -1)
     OR NVL(:NEW.valor_umbral, -1)    <> NVL(:OLD.valor_umbral, -1)
     OR :NEW.descripcion <> :OLD.descripcion THEN
    RAISE_APPLICATION_ERROR(-20107, 'En la alerta ' || :OLD.id_alerta
                                    || ' solo se pueden registrar los datos de revision');
  END IF;
END;
/
SHOW ERRORS

-- D2. El lote (recepcion) de un reclamo es de la misma estacion y combustible
CREATE OR REPLACE TRIGGER trg_reclamo_lote
  BEFORE INSERT OR UPDATE OF id_recepcion, id_estacion, id_combustible ON reclamo_calidad
  FOR EACH ROW
  WHEN (NEW.id_recepcion IS NOT NULL)
DECLARE
  l_est  NUMBER;
  l_comb NUMBER;
BEGIN
  SELECT id_estacion, id_combustible INTO l_est, l_comb
    FROM recepcion_combustible WHERE id_recepcion = :NEW.id_recepcion;
  IF l_est <> :NEW.id_estacion OR l_comb <> :NEW.id_combustible THEN
    RAISE_APPLICATION_ERROR(-20111, 'La recepcion ' || :NEW.id_recepcion
                                    || ' es de otra estacion o de otro combustible');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    NULL;
END;
/
SHOW ERRORS

-- ============================================================
-- E. BITACORAS
-- ============================================================

-- E1. Las bitacoras no se modifican ni se borran
CREATE OR REPLACE TRIGGER trg_bitacora_op_inmutable
  BEFORE UPDATE OR DELETE ON bitacora_operacion
BEGIN
  RAISE_APPLICATION_ERROR(-20112, 'La bitacora de operaciones no se modifica ni se borra');
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_bitacora_acceso_inmutable
  BEFORE UPDATE OR DELETE ON bitacora_acceso_app
BEGIN
  RAISE_APPLICATION_ERROR(-20112, 'La bitacora de accesos no se modifica ni se borra');
END;
/
SHOW ERRORS

-- E2. Registro de cambios en tablas criticas (valores anterior y nuevo en
--     JSON, usuario de base de datos, usuario de la aplicacion, equipo, IP
--     y modulo). Complementa a Unified Auditing (13_auditoria.sql).
CREATE OR REPLACE TRIGGER trg_aud_regla
  AFTER INSERT OR UPDATE OR DELETE ON regla
  FOR EACH ROW
DECLARE
  l_op VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('REGLA', l_op, TO_CHAR(NVL(:NEW.id_regla, :OLD.id_regla)),
    CASE WHEN l_op <> 'INSERT' THEN JSON_OBJECT(
      'id_tipo_regla' VALUE :OLD.id_tipo_regla, 'id_tipo_vehiculo' VALUE :OLD.id_tipo_vehiculo,
      'id_combustible' VALUE :OLD.id_combustible, 'id_tipo_periodo' VALUE :OLD.id_tipo_periodo,
      'solo_fronteriza' VALUE :OLD.solo_fronteriza, 'id_categoria_cilindrada' VALUE :OLD.id_categoria_cilindrada,
      'id_departamento' VALUE :OLD.id_departamento, 'valor' VALUE :OLD.valor,
      'valor_secundario' VALUE :OLD.valor_secundario, 'gravedad' VALUE :OLD.gravedad,
      'fecha_inicio' VALUE :OLD.fecha_inicio, 'fecha_fin' VALUE :OLD.fecha_fin) END,
    CASE WHEN l_op <> 'DELETE' THEN JSON_OBJECT(
      'id_tipo_regla' VALUE :NEW.id_tipo_regla, 'id_tipo_vehiculo' VALUE :NEW.id_tipo_vehiculo,
      'id_combustible' VALUE :NEW.id_combustible, 'id_tipo_periodo' VALUE :NEW.id_tipo_periodo,
      'solo_fronteriza' VALUE :NEW.solo_fronteriza, 'id_categoria_cilindrada' VALUE :NEW.id_categoria_cilindrada,
      'id_departamento' VALUE :NEW.id_departamento, 'valor' VALUE :NEW.valor,
      'valor_secundario' VALUE :NEW.valor_secundario, 'gravedad' VALUE :NEW.gravedad,
      'fecha_inicio' VALUE :NEW.fecha_inicio, 'fecha_fin' VALUE :NEW.fecha_fin) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_aud_tipo_regla
  AFTER INSERT OR UPDATE OR DELETE ON tipo_regla
  FOR EACH ROW
DECLARE
  l_op VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('TIPO_REGLA', l_op, TO_CHAR(NVL(:NEW.id_tipo_regla, :OLD.id_tipo_regla)),
    CASE WHEN l_op <> 'INSERT' THEN JSON_OBJECT(
      'codigo' VALUE :OLD.codigo, 'nombre' VALUE :OLD.nombre, 'familia' VALUE :OLD.familia,
      'evaluacion' VALUE :OLD.evaluacion, 'descripcion' VALUE :OLD.descripcion) END,
    CASE WHEN l_op <> 'DELETE' THEN JSON_OBJECT(
      'codigo' VALUE :NEW.codigo, 'nombre' VALUE :NEW.nombre, 'familia' VALUE :NEW.familia,
      'evaluacion' VALUE :NEW.evaluacion, 'descripcion' VALUE :NEW.descripcion) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_aud_precio
  AFTER INSERT OR UPDATE OR DELETE ON precio_combustible
  FOR EACH ROW
DECLARE
  l_op VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('PRECIO_COMBUSTIBLE', l_op, TO_CHAR(NVL(:NEW.id_precio, :OLD.id_precio)),
    CASE WHEN l_op <> 'INSERT' THEN JSON_OBJECT(
      'id_combustible' VALUE :OLD.id_combustible, 'tipo_precio' VALUE :OLD.tipo_precio,
      'precio_unitario' VALUE :OLD.precio_unitario, 'fecha_inicio' VALUE :OLD.fecha_inicio,
      'fecha_fin' VALUE :OLD.fecha_fin) END,
    CASE WHEN l_op <> 'DELETE' THEN JSON_OBJECT(
      'id_combustible' VALUE :NEW.id_combustible, 'tipo_precio' VALUE :NEW.tipo_precio,
      'precio_unitario' VALUE :NEW.precio_unitario, 'fecha_inicio' VALUE :NEW.fecha_inicio,
      'fecha_fin' VALUE :NEW.fecha_fin) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_aud_categoria_cil
  AFTER INSERT OR UPDATE OR DELETE ON categoria_cilindrada
  FOR EACH ROW
DECLARE
  l_op VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('CATEGORIA_CILINDRADA', l_op,
    TO_CHAR(NVL(:NEW.id_categoria_cilindrada, :OLD.id_categoria_cilindrada)),
    CASE WHEN l_op <> 'INSERT' THEN JSON_OBJECT(
      'codigo' VALUE :OLD.codigo, 'nombre' VALUE :OLD.nombre,
      'cc_min' VALUE :OLD.cc_min, 'cc_max' VALUE :OLD.cc_max) END,
    CASE WHEN l_op <> 'DELETE' THEN JSON_OBJECT(
      'codigo' VALUE :NEW.codigo, 'nombre' VALUE :NEW.nombre,
      'cc_min' VALUE :NEW.cc_min, 'cc_max' VALUE :NEW.cc_max) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_aud_tanque
  AFTER INSERT OR UPDATE OR DELETE ON tanque_estacion
  FOR EACH ROW
DECLARE
  l_op VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('TANQUE_ESTACION', l_op,
    NVL(:NEW.id_estacion, :OLD.id_estacion) || '/' || NVL(:NEW.id_combustible, :OLD.id_combustible),
    CASE WHEN l_op <> 'INSERT' THEN JSON_OBJECT(
      'capacidad' VALUE :OLD.capacidad, 'saldo_inicial' VALUE :OLD.saldo_inicial,
      'fecha_saldo_inicial' VALUE :OLD.fecha_saldo_inicial) END,
    CASE WHEN l_op <> 'DELETE' THEN JSON_OBJECT(
      'capacidad' VALUE :NEW.capacidad, 'saldo_inicial' VALUE :NEW.saldo_inicial,
      'fecha_saldo_inicial' VALUE :NEW.fecha_saldo_inicial) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_aud_beneficio
  AFTER INSERT OR UPDATE OR DELETE ON registro_beneficio
  FOR EACH ROW
DECLARE
  l_op VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('REGISTRO_BENEFICIO', l_op, TO_CHAR(NVL(:NEW.id_beneficio, :OLD.id_beneficio)),
    CASE WHEN l_op <> 'INSERT' THEN JSON_OBJECT(
      'id_vehiculo' VALUE :OLD.id_vehiculo, 'id_persona' VALUE :OLD.id_persona,
      'id_regla' VALUE :OLD.id_regla, 'fecha_inicio' VALUE :OLD.fecha_inicio,
      'fecha_fin' VALUE :OLD.fecha_fin) END,
    CASE WHEN l_op <> 'DELETE' THEN JSON_OBJECT(
      'id_vehiculo' VALUE :NEW.id_vehiculo, 'id_persona' VALUE :NEW.id_persona,
      'id_regla' VALUE :NEW.id_regla, 'fecha_inicio' VALUE :NEW.fecha_inicio,
      'fecha_fin' VALUE :NEW.fecha_fin) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_aud_permiso
  AFTER INSERT OR UPDATE OR DELETE ON permiso_bidon
  FOR EACH ROW
DECLARE
  l_op VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('PERMISO_BIDON', l_op, TO_CHAR(NVL(:NEW.id_permiso, :OLD.id_permiso)),
    CASE WHEN l_op <> 'INSERT' THEN JSON_OBJECT(
      'id_persona' VALUE :OLD.id_persona, 'id_combustible' VALUE :OLD.id_combustible,
      'id_tipo_periodo' VALUE :OLD.id_tipo_periodo, 'nro_resolucion_anh' VALUE :OLD.nro_resolucion_anh,
      'cantidad_autorizada' VALUE :OLD.cantidad_autorizada, 'fecha_inicio' VALUE :OLD.fecha_inicio,
      'fecha_fin' VALUE :OLD.fecha_fin) END,
    CASE WHEN l_op <> 'DELETE' THEN JSON_OBJECT(
      'id_persona' VALUE :NEW.id_persona, 'id_combustible' VALUE :NEW.id_combustible,
      'id_tipo_periodo' VALUE :NEW.id_tipo_periodo, 'nro_resolucion_anh' VALUE :NEW.nro_resolucion_anh,
      'cantidad_autorizada' VALUE :NEW.cantidad_autorizada, 'fecha_inicio' VALUE :NEW.fecha_inicio,
      'fecha_fin' VALUE :NEW.fecha_fin) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

-- usuario_app: nunca se copian el hash ni la sal; solo si la clave cambio.
-- No se registran las actualizaciones de ultimo_acceso ni de intentos (los
-- accesos estan en bitacora_acceso_app); si se registra el cambio de estado.
CREATE OR REPLACE TRIGGER trg_aud_usuario_app
  AFTER INSERT OR DELETE OR UPDATE OF username, rol, id_persona, id_estacion, estado, password_hash
  ON usuario_app
  FOR EACH ROW
DECLARE
  l_op    VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
  l_clave CHAR(1) := 'N';
BEGIN
  IF UPDATING AND :NEW.password_hash <> :OLD.password_hash THEN
    l_clave := 'S';
  END IF;
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('USUARIO_APP', l_op, TO_CHAR(NVL(:NEW.id_usuario, :OLD.id_usuario)),
    CASE WHEN l_op <> 'INSERT' THEN JSON_OBJECT(
      'username' VALUE :OLD.username, 'rol' VALUE :OLD.rol, 'id_persona' VALUE :OLD.id_persona,
      'id_estacion' VALUE :OLD.id_estacion, 'estado' VALUE :OLD.estado) END,
    CASE WHEN l_op <> 'DELETE' THEN JSON_OBJECT(
      'username' VALUE :NEW.username, 'rol' VALUE :NEW.rol, 'id_persona' VALUE :NEW.id_persona,
      'id_estacion' VALUE :NEW.id_estacion, 'estado' VALUE :NEW.estado,
      'clave_cambiada' VALUE l_clave) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

-- alerta: solo la revision (la creacion ya queda en la propia alerta)
CREATE OR REPLACE TRIGGER trg_aud_alerta
  AFTER UPDATE ON alerta
  FOR EACH ROW
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('ALERTA', 'UPDATE', TO_CHAR(:NEW.id_alerta),
    JSON_OBJECT('estado_revision' VALUE :OLD.estado_revision, 'resultado_revision' VALUE :OLD.resultado_revision,
                'id_usuario_revision' VALUE :OLD.id_usuario_revision, 'fecha_revision' VALUE :OLD.fecha_revision,
                'observacion_revision' VALUE :OLD.observacion_revision),
    JSON_OBJECT('estado_revision' VALUE :NEW.estado_revision, 'resultado_revision' VALUE :NEW.resultado_revision,
                'id_usuario_revision' VALUE :NEW.id_usuario_revision, 'fecha_revision' VALUE :NEW.fecha_revision,
                'observacion_revision' VALUE :NEW.observacion_revision),
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

-- persona y vehiculo: cambios y bajas (las altas masivas no se copian)
CREATE OR REPLACE TRIGGER trg_aud_persona
  AFTER UPDATE OR DELETE ON persona
  FOR EACH ROW
DECLARE
  l_op VARCHAR2(6) := CASE WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('PERSONA', l_op, TO_CHAR(:OLD.id_persona),
    JSON_OBJECT('tipo_documento' VALUE :OLD.tipo_documento, 'nro_documento' VALUE :OLD.nro_documento,
                'complemento' VALUE :OLD.complemento, 'nombres' VALUE :OLD.nombres,
                'apellido_paterno' VALUE :OLD.apellido_paterno, 'apellido_materno' VALUE :OLD.apellido_materno,
                'nacionalidad' VALUE :OLD.nacionalidad),
    CASE WHEN l_op = 'UPDATE' THEN JSON_OBJECT(
                'tipo_documento' VALUE :NEW.tipo_documento, 'nro_documento' VALUE :NEW.nro_documento,
                'complemento' VALUE :NEW.complemento, 'nombres' VALUE :NEW.nombres,
                'apellido_paterno' VALUE :NEW.apellido_paterno, 'apellido_materno' VALUE :NEW.apellido_materno,
                'nacionalidad' VALUE :NEW.nacionalidad) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER trg_aud_vehiculo
  AFTER UPDATE OR DELETE ON vehiculo
  FOR EACH ROW
DECLARE
  l_op VARCHAR2(6) := CASE WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  INSERT INTO bitacora_operacion (tabla, operacion, id_registro, datos_anteriores, datos_nuevos,
                                  usuario_bd, usuario_app, equipo, ip, modulo)
  VALUES ('VEHICULO', l_op, TO_CHAR(:OLD.id_vehiculo),
    JSON_OBJECT('id_tipo_vehiculo' VALUE :OLD.id_tipo_vehiculo, 'id_ficha' VALUE :OLD.id_ficha,
                'placa' VALUE :OLD.placa, 'pais_placa' VALUE :OLD.pais_placa,
                'codigo_rfid' VALUE :OLD.codigo_rfid),
    CASE WHEN l_op = 'UPDATE' THEN JSON_OBJECT(
                'id_tipo_vehiculo' VALUE :NEW.id_tipo_vehiculo, 'id_ficha' VALUE :NEW.id_ficha,
                'placa' VALUE :NEW.placa, 'pais_placa' VALUE :NEW.pais_placa,
                'codigo_rfid' VALUE :NEW.codigo_rfid) END,
    SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
    SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'IP_ADDRESS'), SYS_CONTEXT('USERENV', 'MODULE'));
END;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Verificacion: los 29 triggers existen, estan habilitados y validos, y
-- cada uno rechaza lo que debe (pruebas T20 a T27 y T36 a T40 del plan,
-- en un SAVEPOINT que se deshace).
-- ------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  l_n      NUMBER;
  l_gas    NUMBER; l_auto NUMBER; l_dia NUMBER;
  l_mu     NUMBER; l_est NUMBER; l_est2 NUMBER; l_sur NUMBER;
  l_p      NUMBER; l_p_sin NUMBER;
  l_v      NUMBER; l_v2 NUMBER; l_v3 NUMBER; l_v_ext NUMBER;
  l_ficha  NUMBER;
  l_max    NUMBER;
  l_frec   NUMBER;
  l_tx     NUMBER; l_tk NUMBER; l_estado VARCHAR2(10);
  l_alerta NUMBER;
  l_rec    NUMBER;
  l_fiscal NUMBER;
  l_bit    NUMBER;

  PROCEDURE chequear(p_nombre IN VARCHAR2, p_ok IN BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      DBMS_OUTPUT.PUT_LINE('OK    ' || p_nombre);
    ELSE
      RAISE_APPLICATION_ERROR(-20999, '10_triggers: FALLO ' || p_nombre);
    END IF;
  END chequear;

  -- Ejecuta p_sql y exige que falle con p_codigo
  PROCEDURE espera_error(p_nombre IN VARCHAR2, p_codigo IN NUMBER, p_sql IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    chequear(p_nombre || ' (no lanzo error)', FALSE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = p_codigo THEN
        DBMS_OUTPUT.PUT_LINE('OK    ' || p_nombre || ' (' || p_codigo || ')');
      ELSIF SQLCODE = -20999 THEN
        RAISE;
      ELSE
        chequear(p_nombre || ': se esperaba ' || p_codigo || ' y salio ' || SQLCODE || ' ' || SQLERRM, FALSE);
      END IF;
  END espera_error;

  FUNCTION nuevo_vehiculo(p_placa IN VARCHAR2) RETURN NUMBER IS
    l_f  NUMBER;
    l_id NUMBER;
  BEGIN
    INSERT INTO ficha_aduana (nro_chasis, id_combustible, marca, modelo, anio_fabricacion, cilindrada, capacidad_tanque)
      VALUES ('CH-' || p_placa, l_gas, 'Marca', 'Modelo', 2018, 1600, 50) RETURNING id_ficha INTO l_f;
    INSERT INTO vehiculo (id_tipo_vehiculo, id_ficha, placa, codigo_rfid, fecha_registro)
      VALUES (l_auto, l_f, p_placa, 'RFID-' || p_placa, DATE '2026-01-01') RETURNING id_vehiculo INTO l_id;
    INSERT INTO registro_ruat (id_vehiculo, id_persona, clase, servicio, fecha_alta)
      VALUES (l_id, l_p, 'AUTOMOVIL', 'PARTICULAR', DATE '2026-01-01');
    RETURN l_id;
  END nuevo_vehiculo;
BEGIN
  SELECT COUNT(*) INTO l_n FROM all_triggers
   WHERE owner = l_schema AND trigger_name LIKE 'TRG\_%' ESCAPE '\' AND status = 'ENABLED';
  chequear('29 triggers habilitados (hay ' || l_n || ')', l_n = 29);
  SELECT COUNT(*) INTO l_n FROM all_objects
   WHERE owner = l_schema AND object_type = 'TRIGGER' AND status <> 'VALID';
  chequear('ningun trigger invalido', l_n = 0);

  SAVEPOINT sp_10;
  SELECT id_combustible   INTO l_gas  FROM combustible   WHERE nombre = 'Gasolina Especial';
  SELECT id_tipo_vehiculo INTO l_auto FROM tipo_vehiculo WHERE nombre = 'AUTO';
  SELECT id_municipio     INTO l_mu   FROM municipio     WHERE nombre = 'Cochabamba';
  l_dia  := pkg_reglas.f_id_tipo_periodo('DIA');
  l_max  := pkg_reglas.f_id_regla_vigente('MAX_VEHICULOS_PERSONA', SYSTIMESTAMP);
  l_frec := pkg_reglas.f_id_regla_vigente('FRECUENCIA_CARGAS', SYSTIMESTAMP, p_id_tipo_periodo => l_dia);

  -- ---------- Reglas ----------
  espera_error('T20 regla ANOMALIA sin gravedad', -20101,
    'INSERT INTO regla (id_tipo_regla, valor, fecha_inicio) VALUES ((SELECT id_tipo_regla FROM tipo_regla WHERE codigo = ''TANQUE_EXCEDIDO''), 2, DATE ''2030-01-01'')');
  espera_error('T21 regla con vigencia solapada', -20102,
    'INSERT INTO regla (id_tipo_regla, id_tipo_periodo, valor, gravedad, fecha_inicio) VALUES ((SELECT id_tipo_regla FROM tipo_regla WHERE codigo = ''FRECUENCIA_CARGAS''), '
    || l_dia || ', 5, ''MEDIA'', DATE ''2026-03-01'')');
  espera_error('T38 modificar el valor de una regla vigente', -20108,
    'UPDATE regla SET valor = valor + 1 WHERE id_regla = ' || l_frec);
  espera_error('T38 borrar una regla vigente', -20108,
    'DELETE FROM regla WHERE id_regla = ' || l_frec);
  -- Cerrar una version si se permite (y queda en la bitacora con valor anterior y nuevo)
  SELECT COUNT(*) INTO l_bit FROM bitacora_operacion WHERE tabla = 'REGLA' AND id_registro = TO_CHAR(l_frec);
  UPDATE regla SET fecha_fin = DATE '2030-01-01' WHERE id_regla = l_frec;
  SELECT COUNT(*) INTO l_n FROM bitacora_operacion
   WHERE tabla = 'REGLA' AND id_registro = TO_CHAR(l_frec) AND operacion = 'UPDATE'
     AND datos_nuevos LIKE '%2030-01-01%';
  chequear('cerrar una version se permite y queda en la bitacora', l_n >= 1);
  espera_error('T38 reabrir una version cerrada', -20108,
    'UPDATE regla SET fecha_fin = NULL WHERE id_regla = ' || l_frec);
  -- La forma correcta: version nueva
  pkg_reglas.p_crear_version_regla('FRECUENCIA_CARGAS', NULL, NULL, l_dia, NULL, NULL, NULL,
                                   4, NULL, 'MEDIA', DATE '2030-01-01');
  chequear('T38 version nueva con pkg_reglas',
           pkg_reglas.f_id_regla_vigente('FRECUENCIA_CARGAS', TIMESTAMP '2030-01-02 00:00:00',
                                         p_id_tipo_periodo => l_dia) <> l_frec);

  -- ---------- Precios y categorias ----------
  espera_error('precio solapado', -20113,
    'INSERT INTO precio_combustible (id_combustible, tipo_precio, precio_unitario, fecha_inicio) VALUES ('
    || l_gas || ', ''SUBVENCIONADO'', 4, DATE ''2026-06-01'')');
  espera_error('T37 categoria de cilindrada solapada', -20109,
    'INSERT INTO categoria_cilindrada (codigo, nombre, cc_min, cc_max) VALUES (''TST'', ''Prueba'', 1500, 1700)');

  -- ---------- Escenario para operaciones ----------
  INSERT INTO estacion (id_municipio, nombre, nit, latitud, longitud)
    VALUES (l_mu, 'TST-A', 'NIT-TST-A', -17, -66) RETURNING id_estacion INTO l_est;
  INSERT INTO estacion (id_municipio, nombre, nit, latitud, longitud)
    VALUES (l_mu, 'TST-B', 'NIT-TST-B', -17, -66) RETURNING id_estacion INTO l_est2;
  INSERT INTO surtidor (id_estacion, codigo) VALUES (l_est, 'S1') RETURNING id_surtidor INTO l_sur;
  INSERT INTO persona (tipo_documento, nro_documento, nombres, nacionalidad, fecha_registro)
    VALUES ('CI', 'TST-P1', 'Prueba', 'BOLIVIANA', DATE '2026-01-01') RETURNING id_persona INTO l_p;
  INSERT INTO huella_digital (id_persona, plantilla, fecha_enrolamiento)
    VALUES (l_p, TO_BLOB(HEXTORAW('00')), DATE '2026-01-01');
  INSERT INTO persona (tipo_documento, nro_documento, nombres, nacionalidad, fecha_registro)
    VALUES ('CI', 'TST-P2', 'Sin huella', 'BOLIVIANA', DATE '2026-01-01') RETURNING id_persona INTO l_p_sin;
  INSERT INTO vehiculo (id_tipo_vehiculo, placa, pais_placa, fecha_registro)
    VALUES (l_auto, 'TST-EXT', 'PER', DATE '2026-01-01') RETURNING id_vehiculo INTO l_v_ext;

  -- Operacion real por el paquete (extranjero: APROBADA a precio internacional)
  pkg_transacciones.p_registrar_carga_vehicular(
    p_id_surtidor => l_sur, p_id_vehiculo => l_v_ext, p_id_persona => l_p, p_id_combustible => l_gas,
    p_cantidad => 20, p_fecha_hora => TIMESTAMP '2026-11-16 08:00:00',
    p_id_transaccion => l_tx, p_nro_ticket => l_tk, p_estado => l_estado);
  chequear('operacion de prueba APROBADA', l_estado = 'APROBADA');

  -- ---------- Historial inmutable ----------
  espera_error('T23 modificar una transaccion', -20106,
    'UPDATE transaccion SET cantidad_total = 1 WHERE id_transaccion = ' || l_tx);
  espera_error('T23 borrar una transaccion', -20106,
    'DELETE FROM transaccion WHERE id_transaccion = ' || l_tx);
  espera_error('T23 modificar el detalle', -20106,
    'UPDATE detalle_transaccion SET cantidad = 1 WHERE id_transaccion = ' || l_tx);
  espera_error('T23 borrar la carga vehicular', -20106,
    'DELETE FROM carga_vehicular WHERE id_transaccion = ' || l_tx);
  espera_error('T23 modificar una compra de bidon', -20106,
    'UPDATE compra_bidon SET nro_recipientes = 1 WHERE 1 = 0');

  -- ---------- Especializacion y detalle ----------
  espera_error('T22 compra de bidon sobre transaccion VEHICULAR', -20103,
    'INSERT INTO compra_bidon (id_transaccion, nro_recipientes) VALUES (' || l_tx || ', 1)');
  INSERT INTO transaccion (id_surtidor, id_combustible, id_persona, fecha_hora, cantidad_total,
                           tipo_transaccion, huella_verificada, estado)
    VALUES (l_sur, l_gas, l_p, TIMESTAMP '2026-11-16 09:00:00', 10, 'VEHICULAR', 'S', 'BLOQUEADA')
    RETURNING id_transaccion INTO l_n;
  espera_error('detalle en transaccion BLOQUEADA', -20110,
    'INSERT INTO detalle_transaccion (id_transaccion, nro_linea, id_precio, cantidad, motivo_precio) VALUES ('
    || l_n || ', 1, ' || pkg_reglas.f_id_precio_vigente(l_gas, 'INTERNACIONAL', SYSTIMESTAMP) || ', 10, ''EXTRANJERO'')');

  -- ---------- Beneficios ----------
  l_v  := nuevo_vehiculo('TST-001');
  l_v2 := nuevo_vehiculo('TST-002');
  l_v3 := nuevo_vehiculo('TST-003');
  espera_error('T25 beneficio con regla que no es MAX_VEHICULOS_PERSONA', -20104,
    'INSERT INTO registro_beneficio (id_vehiculo, id_persona, id_regla, fecha_inicio) VALUES ('
    || l_v || ', ' || l_p || ', ' || l_frec || ', DATE ''2026-01-01'')');
  espera_error('T24 beneficio a quien no es propietario', -20105,
    'INSERT INTO registro_beneficio (id_vehiculo, id_persona, id_regla, fecha_inicio) VALUES ('
    || l_v || ', ' || l_p_sin || ', ' || l_max || ', DATE ''2026-01-01'')');
  INSERT INTO registro_beneficio (id_vehiculo, id_persona, id_regla, fecha_inicio)
    VALUES (l_v,  l_p, l_max, DATE '2026-01-01');
  INSERT INTO registro_beneficio (id_vehiculo, id_persona, id_regla, fecha_inicio)
    VALUES (l_v2, l_p, l_max, DATE '2026-01-01');
  chequear('dos beneficios para la misma persona (maximo 2)', TRUE);
  espera_error('T25 tercer beneficio supera MAX_VEHICULOS_PERSONA', -20104,
    'INSERT INTO registro_beneficio (id_vehiculo, id_persona, id_regla, fecha_inicio) VALUES ('
    || l_v3 || ', ' || l_p || ', ' || l_max || ', DATE ''2026-01-01'')');

  -- ---------- Alertas ----------
  INSERT INTO alerta (id_regla, id_transaccion, fecha_deteccion, descripcion)
    VALUES (l_frec, l_tx, SYSTIMESTAMP, 'Alerta de prueba') RETURNING id_alerta INTO l_alerta;
  espera_error('T26 cambiar la descripcion de una alerta', -20107,
    'UPDATE alerta SET descripcion = ''otra'' WHERE id_alerta = ' || l_alerta);
  espera_error('T26 borrar una alerta', -20107,
    'DELETE FROM alerta WHERE id_alerta = ' || l_alerta);
  INSERT INTO usuario_app (username, password_hash, sal, rol)
    VALUES ('tst_fiscal', 'x', 'x', 'FISCALIZADOR') RETURNING id_usuario INTO l_fiscal;
  pkg_deteccion.p_revisar_alerta(l_alerta, 'CONFIRMADA', l_fiscal, 'Prueba');
  SELECT COUNT(*) INTO l_n FROM bitacora_operacion
   WHERE tabla = 'ALERTA' AND id_registro = TO_CHAR(l_alerta) AND datos_nuevos LIKE '%CONFIRMADA%';
  chequear('la revision queda en la bitacora', l_n = 1);
  espera_error('T40 modificar una alerta revisada', -20107,
    'UPDATE alerta SET observacion_revision = ''cambio'' WHERE id_alerta = ' || l_alerta);

  -- ---------- Usuario de la aplicacion en la bitacora, sin hash ----------
  SELECT COUNT(*) INTO l_n FROM bitacora_operacion
   WHERE tabla = 'USUARIO_APP' AND id_registro = TO_CHAR(l_fiscal) AND operacion = 'INSERT'
     AND datos_nuevos LIKE '%tst_fiscal%' AND datos_nuevos NOT LIKE '%password%';
  chequear('alta de usuario en la bitacora sin hash', l_n = 1);

  -- ---------- Reclamos ----------
  INSERT INTO tanque_estacion VALUES (l_est, l_gas, 20000, 1000, DATE '2026-11-01');
  INSERT INTO recepcion_combustible (id_estacion, id_combustible, nro_guia_ypfb, nro_lote, cantidad, fecha_hora)
    VALUES (l_est, l_gas, 'GUIA-TST-1', 'LOTE-TST-1', 500, TIMESTAMP '2026-11-03 09:00:00')
    RETURNING id_recepcion INTO l_rec;
  espera_error('T36 reclamo con lote de otra estacion', -20111,
    'INSERT INTO reclamo_calidad (id_estacion, id_combustible, id_recepcion, fecha_hora, tipo_reclamo, descripcion) VALUES ('
    || l_est2 || ', ' || l_gas || ', ' || l_rec || ', SYSTIMESTAMP, ''ADULTERACION'', ''Prueba'')');
  INSERT INTO reclamo_calidad (id_estacion, id_combustible, id_recepcion, fecha_hora, tipo_reclamo, descripcion)
    VALUES (l_est, l_gas, l_rec, SYSTIMESTAMP, 'ADULTERACION', 'Prueba');
  chequear('reclamo con lote de la misma estacion aceptado', TRUE);

  -- ---------- Bitacoras inmutables ----------
  espera_error('modificar la bitacora de operaciones', -20112,
    'UPDATE bitacora_operacion SET tabla = ''X'' WHERE 1 = 0');
  espera_error('borrar la bitacora de accesos', -20112,
    'DELETE FROM bitacora_acceso_app WHERE 1 = 0');

  ROLLBACK TO sp_10;
  SELECT COUNT(*) INTO l_n FROM estacion WHERE nombre LIKE 'TST-%';
  chequear('no quedaron datos de prueba', l_n = 0);
  SELECT COUNT(*) INTO l_n FROM bitacora_operacion WHERE id_registro = TO_CHAR(l_frec) AND tabla = 'REGLA';
  chequear('la bitacora de prueba tambien se deshizo', l_n = l_bit);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/
