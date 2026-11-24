-- ============================================================
-- 09_pkg_usuarios.sql
-- Paquete pkg_usuarios: usuarios de la aplicacion grafica (tabla
-- usuario_app). Alta, autenticacion con bloqueo por intentos, cambio
-- y restablecimiento de clave, estado y contexto de sesion.
-- La aplicacion se conecta a Oracle con una sola cuenta de servicio
-- (u_app); este paquete autentica a las PERSONAS que la usan.
-- Clave: nunca se guarda. Se guarda SHA-512 (hex) de sal || clave, con
-- una sal aleatoria de 16 bytes (DBMS_CRYPTO) por usuario.
-- Re-ejecutable (CREATE OR REPLACE). No hace COMMIT ni ROLLBACK, salvo
-- f_autenticar: es una transaccion AUTONOMA para que los intentos
-- fallidos, el bloqueo y el registro en bitacora_acceso_app queden
-- guardados aunque quien llama deshaga su transaccion.
-- Errores: -20013 cuenta bloqueada o inactiva,
--          -20014 clave que no cumple la politica o clave actual incorrecta,
--          -20015 datos de usuario invalidos (nombre, rol, duplicado, inexistente).
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ------------------------------------------------------------
-- Especificacion (contrato del plan v2, seccion 5.5)
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE pkg_usuarios AS
  c_max_intentos CONSTANT PLS_INTEGER := 5;

  -- NULL si la clave cumple la politica; si no, el motivo.
  -- Politica: 10 a 64 caracteres, al menos una letra y un numero, sin espacios.
  FUNCTION f_validar_clave(p_clave IN VARCHAR2) RETURN VARCHAR2;

  -- username: minusculas, numeros, punto o guion bajo; 3 a 30; empieza con letra.
  -- rol: ADMIN, OPERADOR (requiere estacion), FISCALIZADOR o ANALISTA.
  PROCEDURE p_crear_usuario(
    p_username    IN  VARCHAR2,
    p_clave       IN  VARCHAR2,
    p_rol         IN  VARCHAR2,
    p_id_persona  IN  NUMBER DEFAULT NULL,
    p_id_estacion IN  NUMBER DEFAULT NULL,
    p_id_usuario  OUT NUMBER);

  -- Devuelve el id del usuario si la clave es correcta, o NULL si el
  -- usuario no existe o la clave es incorrecta (al llegar a c_max_intentos
  -- fallidos la cuenta pasa a BLOQUEADO). Lanza -20013 si la cuenta esta
  -- BLOQUEADO o INACTIVO. Cada intento queda en bitacora_acceso_app.
  FUNCTION f_autenticar(
    p_username IN VARCHAR2,
    p_clave    IN VARCHAR2,
    p_ip       IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;

  -- El propio usuario cambia su clave (verifica la actual).
  PROCEDURE p_cambiar_clave(
    p_id_usuario   IN NUMBER,
    p_clave_actual IN VARCHAR2,
    p_clave_nueva  IN VARCHAR2);

  -- Un administrador fija una clave nueva (y desbloquea si estaba BLOQUEADO).
  PROCEDURE p_restablecer_clave(
    p_id_usuario  IN NUMBER,
    p_clave_nueva IN VARCHAR2);

  PROCEDURE p_desbloquear(p_id_usuario IN NUMBER);

  -- ACTIVO, BLOQUEADO o INACTIVO
  PROCEDURE p_cambiar_estado(p_id_usuario IN NUMBER, p_estado IN VARCHAR2);

  PROCEDURE p_actualizar_usuario(
    p_id_usuario  IN NUMBER,
    p_rol         IN VARCHAR2,
    p_id_persona  IN NUMBER DEFAULT NULL,
    p_id_estacion IN NUMBER DEFAULT NULL);

  -- Marca la sesion de base de datos con el usuario de la aplicacion:
  -- CLIENT_IDENTIFIER = username (aparece en auditoria y bitacora).
  PROCEDURE p_fijar_contexto(p_id_usuario IN NUMBER);
  PROCEDURE p_limpiar_contexto;
END pkg_usuarios;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Cuerpo
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE BODY pkg_usuarios AS

  FUNCTION hash_clave(p_sal IN VARCHAR2, p_clave IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN RAWTOHEX(DBMS_CRYPTO.HASH(UTL_RAW.CAST_TO_RAW(p_sal || p_clave), DBMS_CRYPTO.HASH_SH512));
  END hash_clave;

  FUNCTION nueva_sal RETURN VARCHAR2 IS
  BEGIN
    RETURN RAWTOHEX(DBMS_CRYPTO.RANDOMBYTES(16));   -- 32 caracteres hex
  END nueva_sal;

  FUNCTION normalizar(p_username IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN LOWER(TRIM(p_username));
  END normalizar;

  PROCEDURE exigir_politica(p_clave IN VARCHAR2) IS
    l_motivo VARCHAR2(200) := f_validar_clave(p_clave);
  BEGIN
    IF l_motivo IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(-20014, 'Clave invalida: ' || l_motivo);
    END IF;
  END exigir_politica;

  PROCEDURE validar_rol(p_rol IN VARCHAR2, p_id_persona IN NUMBER, p_id_estacion IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    IF p_rol IS NULL OR p_rol NOT IN ('ADMIN', 'OPERADOR', 'FISCALIZADOR', 'ANALISTA') THEN
      RAISE_APPLICATION_ERROR(-20015, 'Rol invalido: ' || NVL(p_rol, 'NULL'));
    END IF;
    IF p_rol = 'OPERADOR' AND p_id_estacion IS NULL THEN
      RAISE_APPLICATION_ERROR(-20015, 'Un OPERADOR debe tener una estacion asignada');
    END IF;
    IF p_id_persona IS NOT NULL THEN
      SELECT COUNT(*) INTO l_n FROM persona WHERE id_persona = p_id_persona;
      IF l_n = 0 THEN
        RAISE_APPLICATION_ERROR(-20015, 'Persona inexistente: ' || p_id_persona);
      END IF;
    END IF;
    IF p_id_estacion IS NOT NULL THEN
      SELECT COUNT(*) INTO l_n FROM estacion WHERE id_estacion = p_id_estacion;
      IF l_n = 0 THEN
        RAISE_APPLICATION_ERROR(-20015, 'Estacion inexistente: ' || p_id_estacion);
      END IF;
    END IF;
  END validar_rol;

  PROCEDURE exigir_usuario(p_id_usuario IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM usuario_app WHERE id_usuario = p_id_usuario;
    IF l_n = 0 THEN
      RAISE_APPLICATION_ERROR(-20015, 'Usuario inexistente: ' || p_id_usuario);
    END IF;
  END exigir_usuario;

  -- ----------------------------------------------------------
  -- Publicos
  -- ----------------------------------------------------------
  FUNCTION f_validar_clave(p_clave IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_clave IS NULL OR LENGTH(p_clave) < 10 THEN
      RETURN 'debe tener al menos 10 caracteres';
    ELSIF LENGTH(p_clave) > 64 THEN
      RETURN 'debe tener como maximo 64 caracteres';
    ELSIF NOT REGEXP_LIKE(p_clave, '[A-Za-z]') THEN
      RETURN 'debe tener al menos una letra';
    ELSIF NOT REGEXP_LIKE(p_clave, '[0-9]') THEN
      RETURN 'debe tener al menos un numero';
    ELSIF REGEXP_LIKE(p_clave, '\s') THEN
      RETURN 'no debe tener espacios';
    END IF;
    RETURN NULL;
  END f_validar_clave;

  PROCEDURE p_crear_usuario(
    p_username    IN  VARCHAR2,
    p_clave       IN  VARCHAR2,
    p_rol         IN  VARCHAR2,
    p_id_persona  IN  NUMBER DEFAULT NULL,
    p_id_estacion IN  NUMBER DEFAULT NULL,
    p_id_usuario  OUT NUMBER) IS
    l_username usuario_app.username%TYPE;
    l_sal      usuario_app.sal%TYPE := nueva_sal;
    l_hash     usuario_app.password_hash%TYPE;
  BEGIN
    IF p_username IS NULL OR NOT REGEXP_LIKE(normalizar(p_username), '^[a-z][a-z0-9._]{2,29}$') THEN
      RAISE_APPLICATION_ERROR(-20015, 'Nombre de usuario invalido: ' || NVL(p_username, 'NULL')
                                      || ' (minusculas, numeros, punto o guion bajo; 3 a 30; empieza con letra)');
    END IF;
    l_username := normalizar(p_username);
    validar_rol(p_rol, p_id_persona, p_id_estacion);
    exigir_politica(p_clave);
    l_hash := hash_clave(l_sal, p_clave);   -- funcion privada: se calcula fuera del SQL

    BEGIN
      INSERT INTO usuario_app (username, password_hash, sal, rol, id_persona, id_estacion)
        VALUES (l_username, l_hash, l_sal, p_rol, p_id_persona, p_id_estacion)
        RETURNING id_usuario INTO p_id_usuario;
    EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN
        RAISE_APPLICATION_ERROR(-20015, 'Ya existe el usuario ' || l_username);
    END;
  END p_crear_usuario;

  FUNCTION f_autenticar(
    p_username IN VARCHAR2,
    p_clave    IN VARCHAR2,
    p_ip       IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_username usuario_app.username%TYPE := SUBSTR(normalizar(p_username), 1, 30);
    l_id       usuario_app.id_usuario%TYPE;
    l_hash     usuario_app.password_hash%TYPE;
    l_sal      usuario_app.sal%TYPE;
    l_estado   usuario_app.estado%TYPE;
    l_intentos usuario_app.intentos_fallidos%TYPE;
    l_ip       VARCHAR2(45) := SUBSTR(NVL(p_ip, SYS_CONTEXT('USERENV', 'IP_ADDRESS')), 1, 45);

    PROCEDURE registrar(p_exito IN CHAR, p_motivo IN VARCHAR2) IS
    BEGIN
      INSERT INTO bitacora_acceso_app (username, exito, motivo, ip)
        VALUES (NVL(l_username, '(vacio)'), p_exito, p_motivo, l_ip);
    END registrar;
  BEGIN
    BEGIN
      SELECT id_usuario, password_hash, sal, estado, intentos_fallidos
        INTO l_id, l_hash, l_sal, l_estado, l_intentos
        FROM usuario_app
       WHERE username = l_username
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        l_hash := hash_clave('0', NVL(p_clave, 'x'));   -- mismo costo que un usuario real
        registrar('N', 'USUARIO_INEXISTENTE');
        COMMIT;
        RETURN NULL;
    END;

    IF l_estado <> 'ACTIVO' THEN
      registrar('N', 'CUENTA_' || l_estado);
      COMMIT;
      RAISE_APPLICATION_ERROR(-20013, 'La cuenta ' || l_username || ' esta ' || l_estado);
    END IF;

    IF p_clave IS NULL OR hash_clave(l_sal, p_clave) <> l_hash THEN
      l_intentos := l_intentos + 1;
      UPDATE usuario_app
         SET intentos_fallidos = l_intentos,
             estado = CASE WHEN l_intentos >= c_max_intentos THEN 'BLOQUEADO' ELSE estado END
       WHERE id_usuario = l_id;
      registrar('N', CASE WHEN l_intentos >= c_max_intentos
                          THEN 'CLAVE_INCORRECTA_CUENTA_BLOQUEADA'
                          ELSE 'CLAVE_INCORRECTA_' || l_intentos END);
      COMMIT;
      RETURN NULL;
    END IF;

    UPDATE usuario_app
       SET intentos_fallidos = 0,
           ultimo_acceso     = SYSTIMESTAMP
     WHERE id_usuario = l_id;
    registrar('S', 'OK');
    COMMIT;
    RETURN l_id;
  EXCEPTION
    WHEN OTHERS THEN
      -- -20013 ya confirmo su registro; cualquier otro error deshace lo autonomo
      IF SQLCODE <> -20013 THEN
        ROLLBACK;
      END IF;
      RAISE;
  END f_autenticar;

  PROCEDURE p_cambiar_clave(
    p_id_usuario   IN NUMBER,
    p_clave_actual IN VARCHAR2,
    p_clave_nueva  IN VARCHAR2) IS
    l_hash   usuario_app.password_hash%TYPE;
    l_sal    usuario_app.sal%TYPE;
    l_estado usuario_app.estado%TYPE;
    l_nueva  usuario_app.sal%TYPE := nueva_sal;
    l_hash_n usuario_app.password_hash%TYPE;
  BEGIN
    BEGIN
      SELECT password_hash, sal, estado INTO l_hash, l_sal, l_estado
        FROM usuario_app WHERE id_usuario = p_id_usuario
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20015, 'Usuario inexistente: ' || p_id_usuario);
    END;
    IF l_estado <> 'ACTIVO' THEN
      RAISE_APPLICATION_ERROR(-20013, 'La cuenta esta ' || l_estado);
    END IF;
    IF p_clave_actual IS NULL OR hash_clave(l_sal, p_clave_actual) <> l_hash THEN
      RAISE_APPLICATION_ERROR(-20014, 'La clave actual no es correcta');
    END IF;
    exigir_politica(p_clave_nueva);
    IF p_clave_nueva = p_clave_actual THEN
      RAISE_APPLICATION_ERROR(-20014, 'La clave nueva debe ser distinta de la actual');
    END IF;
    l_hash_n := hash_clave(l_nueva, p_clave_nueva);
    UPDATE usuario_app
       SET sal = l_nueva, password_hash = l_hash_n
     WHERE id_usuario = p_id_usuario;
  END p_cambiar_clave;

  PROCEDURE p_restablecer_clave(
    p_id_usuario  IN NUMBER,
    p_clave_nueva IN VARCHAR2) IS
    l_nueva usuario_app.sal%TYPE := nueva_sal;
    l_hash  usuario_app.password_hash%TYPE;
  BEGIN
    exigir_usuario(p_id_usuario);
    exigir_politica(p_clave_nueva);
    l_hash := hash_clave(l_nueva, p_clave_nueva);
    UPDATE usuario_app
       SET sal               = l_nueva,
           password_hash     = l_hash,
           intentos_fallidos = 0,
           estado            = CASE WHEN estado = 'BLOQUEADO' THEN 'ACTIVO' ELSE estado END
     WHERE id_usuario = p_id_usuario;
  END p_restablecer_clave;

  PROCEDURE p_desbloquear(p_id_usuario IN NUMBER) IS
  BEGIN
    exigir_usuario(p_id_usuario);
    UPDATE usuario_app
       SET estado = 'ACTIVO', intentos_fallidos = 0
     WHERE id_usuario = p_id_usuario
       AND estado = 'BLOQUEADO';
  END p_desbloquear;

  PROCEDURE p_cambiar_estado(p_id_usuario IN NUMBER, p_estado IN VARCHAR2) IS
  BEGIN
    IF p_estado IS NULL OR p_estado NOT IN ('ACTIVO', 'BLOQUEADO', 'INACTIVO') THEN
      RAISE_APPLICATION_ERROR(-20015, 'Estado invalido: ' || NVL(p_estado, 'NULL'));
    END IF;
    exigir_usuario(p_id_usuario);
    UPDATE usuario_app
       SET estado            = p_estado,
           intentos_fallidos = CASE WHEN p_estado = 'ACTIVO' THEN 0 ELSE intentos_fallidos END
     WHERE id_usuario = p_id_usuario;
  END p_cambiar_estado;

  PROCEDURE p_actualizar_usuario(
    p_id_usuario  IN NUMBER,
    p_rol         IN VARCHAR2,
    p_id_persona  IN NUMBER DEFAULT NULL,
    p_id_estacion IN NUMBER DEFAULT NULL) IS
  BEGIN
    exigir_usuario(p_id_usuario);
    validar_rol(p_rol, p_id_persona, p_id_estacion);
    UPDATE usuario_app
       SET rol = p_rol, id_persona = p_id_persona, id_estacion = p_id_estacion
     WHERE id_usuario = p_id_usuario;
  END p_actualizar_usuario;

  PROCEDURE p_fijar_contexto(p_id_usuario IN NUMBER) IS
    l_username usuario_app.username%TYPE;
  BEGIN
    SELECT username INTO l_username FROM usuario_app WHERE id_usuario = p_id_usuario;
    DBMS_SESSION.SET_IDENTIFIER(l_username);
    DBMS_APPLICATION_INFO.SET_MODULE('APP_COMBUSTIBLE', NULL);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20015, 'Usuario inexistente: ' || p_id_usuario);
  END p_fijar_contexto;

  PROCEDURE p_limpiar_contexto IS
  BEGIN
    DBMS_SESSION.CLEAR_IDENTIFIER;
    DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);
  END p_limpiar_contexto;

END pkg_usuarios;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Verificacion (SAVEPOINT, se deshace).
-- f_autenticar es autonoma: no ve los usuarios creados en esta prueba
-- sin confirmar, y lo que registra queda guardado. Por eso aqui solo se
-- prueba que compila; el inicio de sesion se prueba en
-- Scripts/pruebas (T39) con un usuario real.
-- ------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  l_n      NUMBER;
  l_id     NUMBER;
  l_id2    NUMBER;
  l_est    NUMBER;
  l_hash1  usuario_app.password_hash%TYPE;
  l_hash2  usuario_app.password_hash%TYPE;
  l_sal1   usuario_app.sal%TYPE;

  PROCEDURE chequear(p_nombre IN VARCHAR2, p_ok IN BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      DBMS_OUTPUT.PUT_LINE('OK    ' || p_nombre);
    ELSE
      RAISE_APPLICATION_ERROR(-20999, '09_pkg_usuarios: FALLO ' || p_nombre);
    END IF;
  END chequear;

  PROCEDURE espera(p_nombre IN VARCHAR2, p_codigo IN NUMBER, p_sqlcode IN NUMBER) IS
  BEGIN
    chequear(p_nombre || ' (' || p_codigo || ')', p_sqlcode = p_codigo);
  END espera;
BEGIN
  SELECT COUNT(*) INTO l_n FROM all_objects
   WHERE owner = l_schema AND object_name = 'PKG_USUARIOS' AND status = 'VALID';
  chequear('pkg_usuarios (especificacion y cuerpo) VALID', l_n = 2);

  -- Politica de clave
  chequear('clave corta rechazada',        pkg_usuarios.f_validar_clave('abc123') IS NOT NULL);
  chequear('clave sin numero rechazada',   pkg_usuarios.f_validar_clave('abcdefghijk') IS NOT NULL);
  chequear('clave sin letra rechazada',    pkg_usuarios.f_validar_clave('12345678901') IS NOT NULL);
  chequear('clave con espacio rechazada',  pkg_usuarios.f_validar_clave('abcde 12345') IS NOT NULL);
  chequear('clave valida aceptada',        pkg_usuarios.f_validar_clave('Prueba_2026x') IS NULL);

  SAVEPOINT sp_09;

  -- Alta: la clave no se guarda; se guarda el hash con sal propia
  pkg_usuarios.p_crear_usuario('TST_Fiscal', 'Prueba_2026x', 'FISCALIZADOR', p_id_usuario => l_id);
  SELECT password_hash, sal INTO l_hash1, l_sal1 FROM usuario_app WHERE id_usuario = l_id;
  SELECT COUNT(*) INTO l_n FROM usuario_app WHERE id_usuario = l_id AND username = 'tst_fiscal';
  chequear('username normalizado a minusculas', l_n = 1);
  chequear('hash SHA-512 de 128 caracteres', LENGTH(l_hash1) = 128 AND LENGTH(l_sal1) = 32);
  chequear('la clave no aparece en la tabla', INSTR(l_hash1, 'Prueba_2026x') = 0);

  pkg_usuarios.p_crear_usuario('tst_otro', 'Prueba_2026x', 'ANALISTA', p_id_usuario => l_id2);
  SELECT password_hash INTO l_hash2 FROM usuario_app WHERE id_usuario = l_id2;
  chequear('misma clave, distinto hash (sal distinta)', l_hash1 <> l_hash2);

  -- Validaciones de alta
  BEGIN pkg_usuarios.p_crear_usuario('tst_fiscal', 'Prueba_2026x', 'ANALISTA', p_id_usuario => l_n);
        chequear('rechaza usuario duplicado', FALSE);
  EXCEPTION WHEN OTHERS THEN espera('rechaza usuario duplicado', -20015, SQLCODE); END;
  BEGIN pkg_usuarios.p_crear_usuario('1malo', 'Prueba_2026x', 'ANALISTA', p_id_usuario => l_n);
        chequear('rechaza nombre invalido', FALSE);
  EXCEPTION WHEN OTHERS THEN espera('rechaza nombre invalido', -20015, SQLCODE); END;
  BEGIN pkg_usuarios.p_crear_usuario('tst_jefe', 'Prueba_2026x', 'JEFE', p_id_usuario => l_n);
        chequear('rechaza rol invalido', FALSE);
  EXCEPTION WHEN OTHERS THEN espera('rechaza rol invalido', -20015, SQLCODE); END;
  BEGIN pkg_usuarios.p_crear_usuario('tst_oper', 'Prueba_2026x', 'OPERADOR', p_id_usuario => l_n);
        chequear('rechaza operador sin estacion', FALSE);
  EXCEPTION WHEN OTHERS THEN espera('rechaza operador sin estacion', -20015, SQLCODE); END;
  BEGIN pkg_usuarios.p_crear_usuario('tst_debil', 'corta1', 'ANALISTA', p_id_usuario => l_n);
        chequear('rechaza clave debil', FALSE);
  EXCEPTION WHEN OTHERS THEN espera('rechaza clave debil', -20014, SQLCODE); END;

  -- Operador con estacion
  SELECT MIN(id_estacion) INTO l_est FROM estacion;
  IF l_est IS NULL THEN
    INSERT INTO estacion (id_municipio, nombre, nit, latitud, longitud)
      VALUES ((SELECT MIN(id_municipio) FROM municipio), 'TST-A', 'NIT-TST-A', -17, -66)
      RETURNING id_estacion INTO l_est;
  END IF;
  pkg_usuarios.p_crear_usuario('tst_oper', 'Prueba_2026x', 'OPERADOR', p_id_estacion => l_est, p_id_usuario => l_n);
  chequear('operador con estacion creado', l_n IS NOT NULL);

  -- Cambio de clave
  BEGIN pkg_usuarios.p_cambiar_clave(l_id, 'Equivocada_1', 'Nueva_Clave_2027');
        chequear('rechaza clave actual incorrecta', FALSE);
  EXCEPTION WHEN OTHERS THEN espera('rechaza clave actual incorrecta', -20014, SQLCODE); END;
  pkg_usuarios.p_cambiar_clave(l_id, 'Prueba_2026x', 'Nueva_Clave_2027');
  SELECT password_hash INTO l_hash2 FROM usuario_app WHERE id_usuario = l_id;
  chequear('cambio de clave cambia el hash', l_hash2 <> l_hash1);

  -- Estado, bloqueo y restablecimiento
  pkg_usuarios.p_cambiar_estado(l_id, 'BLOQUEADO');
  BEGIN pkg_usuarios.p_cambiar_clave(l_id, 'Nueva_Clave_2027', 'Otra_Clave_2028');
        chequear('cuenta bloqueada no cambia clave', FALSE);
  EXCEPTION WHEN OTHERS THEN espera('cuenta bloqueada no cambia clave', -20013, SQLCODE); END;
  pkg_usuarios.p_restablecer_clave(l_id, 'Restablecida_2027');
  SELECT COUNT(*) INTO l_n FROM usuario_app WHERE id_usuario = l_id AND estado = 'ACTIVO' AND intentos_fallidos = 0;
  chequear('restablecer clave desbloquea', l_n = 1);
  pkg_usuarios.p_actualizar_usuario(l_id, 'ADMIN');
  SELECT COUNT(*) INTO l_n FROM usuario_app WHERE id_usuario = l_id AND rol = 'ADMIN';
  chequear('rol actualizado', l_n = 1);

  -- Contexto de sesion
  pkg_usuarios.p_fijar_contexto(l_id);
  chequear('CLIENT_IDENTIFIER = tst_fiscal', SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER') = 'tst_fiscal');
  pkg_usuarios.p_limpiar_contexto;
  chequear('contexto limpio', SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER') IS NULL);

  ROLLBACK TO sp_09;
  SELECT COUNT(*) INTO l_n FROM usuario_app WHERE username LIKE 'tst\_%' ESCAPE '\';
  chequear('no quedaron datos de prueba', l_n = 0);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/
