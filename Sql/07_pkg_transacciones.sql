-- ============================================================
-- 07_pkg_transacciones.sql
-- Paquete pkg_transacciones: UNICA puerta de entrada de operaciones
-- (cargas vehiculares y compras en bidon). Valida, evalua las reglas
-- con pkg_deteccion, decide APROBADA o BLOQUEADA, asigna precios por
-- motivo y registra las alertas.
-- Re-ejecutable (CREATE OR REPLACE). El paquete NO hace COMMIT ni
-- ROLLBACK. Una operacion BLOQUEADA no lanza error: se guarda como
-- evidencia y se informa en p_estado (si lanzara, quien llama haria
-- rollback y se perderia la evidencia).
-- Errores: -20001 cantidad o indicador invalido, -20002 surtidor,
--          -20003 vehiculo, -20004 combustible, -20005 sin precio
--          internacional, -20006 persona, -20007 recipientes.
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ------------------------------------------------------------
-- Especificacion (contrato del plan v2, seccion 5.3)
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE pkg_transacciones AS
  -- Prioridad del motivo de precio (carga vehicular):
  --   FALLA_IDENTIFICACION > EXTRANJERO > SIN_SUBVENCION > SIN_BENEFICIO
  --   > NO_TITULAR > CUOTA / EXCEDE_CUOTA
  -- Sin regla CUOTA_SUBVENCIONADA para el vehiculo y combustible = SIN_SUBVENCION.
  PROCEDURE p_registrar_carga_vehicular(
    p_id_surtidor       IN  NUMBER,
    p_id_vehiculo       IN  NUMBER,
    p_id_persona        IN  NUMBER,
    p_id_combustible    IN  NUMBER,
    p_cantidad          IN  NUMBER,
    p_fecha_hora        IN  TIMESTAMP DEFAULT SYSTIMESTAMP,
    p_huella_verificada IN  CHAR      DEFAULT 'S',
    p_rfid_leido        IN  CHAR      DEFAULT 'S',
    p_id_transaccion    OUT NUMBER,
    p_nro_ticket        OUT NUMBER,
    p_estado            OUT VARCHAR2);

  -- Bidon: FALLA_IDENTIFICACION > SIN_PERMISO > SIN_SUBVENCION
  --        > CUOTA (dentro del permiso) / EXCEDE_PERMISO
  PROCEDURE p_registrar_compra_bidon(
    p_id_surtidor       IN  NUMBER,
    p_id_persona        IN  NUMBER,
    p_id_combustible    IN  NUMBER,
    p_cantidad          IN  NUMBER,
    p_nro_recipientes   IN  NUMBER,
    p_motivo_declarado  IN  VARCHAR2  DEFAULT NULL,
    p_fecha_hora        IN  TIMESTAMP DEFAULT SYSTIMESTAMP,
    p_huella_verificada IN  CHAR      DEFAULT 'S',
    p_id_transaccion    OUT NUMBER,
    p_nro_ticket        OUT NUMBER,
    p_estado            OUT VARCHAR2);

  -- Cuota subvencionada que le queda al vehiculo en esa fecha y surtidor
  -- (la menor entre sus periodos). NULL si no tiene regla de cuota.
  FUNCTION f_cuota_disponible(
    p_id_vehiculo    IN NUMBER,
    p_id_surtidor    IN NUMBER,
    p_id_combustible IN NUMBER,
    p_fecha          IN TIMESTAMP DEFAULT SYSTIMESTAMP) RETURN NUMBER;

  -- Codigos de reglas incumplidas en la ultima operacion registrada en
  -- esta sesion (separados por coma; NULL si ninguna). Para la interfaz.
  FUNCTION f_ultimas_alertas RETURN VARCHAR2;
END pkg_transacciones;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Cuerpo
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE BODY pkg_transacciones AS

  g_ultimas VARCHAR2(4000);

  -- ----------------------------------------------------------
  -- Utilitarios
  -- ----------------------------------------------------------
  -- Validaciones comunes; devuelve el precio INTERNACIONAL vigente
  FUNCTION validar_comun(
    p_id_surtidor    IN NUMBER,
    p_id_combustible IN NUMBER,
    p_cantidad       IN NUMBER,
    p_id_persona     IN NUMBER,
    p_huella         IN CHAR,
    p_fecha          IN TIMESTAMP) RETURN NUMBER IS
    l_estado surtidor.estado%TYPE;
    l_n      NUMBER;
    l_intl   NUMBER;
  BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
      RAISE_APPLICATION_ERROR(-20001, 'La cantidad debe ser mayor a cero');
    END IF;
    IF p_huella IS NULL OR p_huella NOT IN ('S', 'N') THEN
      RAISE_APPLICATION_ERROR(-20001, 'Indicador de huella invalido (S/N)');
    END IF;

    BEGIN
      SELECT estado INTO l_estado FROM surtidor WHERE id_surtidor = p_id_surtidor;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20002, 'Surtidor inexistente: ' || p_id_surtidor);
    END;
    IF l_estado <> 'ACTIVO' THEN
      RAISE_APPLICATION_ERROR(-20002, 'Surtidor ' || p_id_surtidor || ' en estado ' || l_estado);
    END IF;

    SELECT COUNT(*) INTO l_n FROM combustible WHERE id_combustible = p_id_combustible;
    IF l_n = 0 THEN
      RAISE_APPLICATION_ERROR(-20004, 'Combustible inexistente: ' || p_id_combustible);
    END IF;

    IF p_id_persona IS NOT NULL THEN
      SELECT COUNT(*) INTO l_n FROM persona WHERE id_persona = p_id_persona;
      IF l_n = 0 THEN
        RAISE_APPLICATION_ERROR(-20006, 'Persona inexistente: ' || p_id_persona);
      END IF;
    END IF;

    l_intl := pkg_reglas.f_id_precio_vigente(p_id_combustible, 'INTERNACIONAL', p_fecha);
    IF l_intl IS NULL THEN
      RAISE_APPLICATION_ERROR(-20005, 'No hay precio INTERNACIONAL vigente para el combustible '
                                      || p_id_combustible || ' en ' || TO_CHAR(p_fecha, 'YYYY-MM-DD HH24:MI'));
    END IF;
    RETURN l_intl;
  END validar_comun;

  PROCEDURE insertar_transaccion(
    p_id_surtidor    IN  NUMBER,
    p_id_combustible IN  NUMBER,
    p_id_persona     IN  NUMBER,
    p_fecha          IN  TIMESTAMP,
    p_cantidad       IN  NUMBER,
    p_tipo           IN  VARCHAR2,
    p_huella         IN  CHAR,
    p_estado         IN  VARCHAR2,
    p_id             OUT NUMBER,
    p_ticket         OUT NUMBER) IS
  BEGIN
    INSERT INTO transaccion (id_surtidor, id_combustible, id_persona, fecha_hora, cantidad_total,
                             tipo_transaccion, huella_verificada, estado)
      VALUES (p_id_surtidor, p_id_combustible, p_id_persona, p_fecha, p_cantidad,
              p_tipo, p_huella, p_estado)
      RETURNING id_transaccion, nro_ticket INTO p_id, p_ticket;
  END insertar_transaccion;

  PROCEDURE insertar_linea(
    p_id_transaccion IN NUMBER,
    p_nro_linea      IN OUT NUMBER,
    p_id_precio      IN NUMBER,
    p_cantidad       IN NUMBER,
    p_motivo         IN VARCHAR2) IS
  BEGIN
    IF p_cantidad > 0 THEN
      p_nro_linea := p_nro_linea + 1;
      INSERT INTO detalle_transaccion (id_transaccion, nro_linea, id_precio, cantidad, motivo_precio)
        VALUES (p_id_transaccion, p_nro_linea, p_id_precio, p_cantidad, p_motivo);
    END IF;
  END insertar_linea;

  -- Cuota restante (la menor entre los periodos con regla) y la regla que
  -- la determina. Cuenta solo lineas CUOTA de transacciones APROBADA.
  PROCEDURE calcular_cuota(
    p_id_vehiculo    IN  NUMBER,
    p_id_surtidor    IN  NUMBER,
    p_id_combustible IN  NUMBER,
    p_fecha          IN  TIMESTAMP,
    p_restante       OUT NUMBER,
    p_id_regla       OUT NUMBER) IS
    l_id     NUMBER;
    l_valor  NUMBER;
    l_per    VARCHAR2(10);
    l_usado  NUMBER;
  BEGIN
    p_restante := NULL;
    p_id_regla := NULL;
    FOR per IN (SELECT codigo FROM tipo_periodo ORDER BY id_tipo_periodo) LOOP
      l_id := pkg_deteccion.f_id_regla_operacion('CUOTA_SUBVENCIONADA', p_fecha, p_id_surtidor,
                                                 p_id_combustible, p_id_vehiculo, per.codigo);
      IF l_id IS NOT NULL THEN
        SELECT r.valor, NVL(tp.codigo, 'DIA')
          INTO l_valor, l_per
          FROM regla r
          LEFT JOIN tipo_periodo tp ON tp.id_tipo_periodo = r.id_tipo_periodo
         WHERE r.id_regla = l_id;
        IF l_per = per.codigo THEN
          SELECT NVL(SUM(dt.cantidad), 0)
            INTO l_usado
            FROM carga_vehicular cv
            JOIN transaccion t          ON t.id_transaccion  = cv.id_transaccion
            JOIN detalle_transaccion dt ON dt.id_transaccion = t.id_transaccion
           WHERE cv.id_vehiculo   = p_id_vehiculo
             AND t.estado         = 'APROBADA'
             AND t.id_combustible = p_id_combustible
             AND dt.motivo_precio = 'CUOTA'
             AND t.fecha_hora    >= pkg_reglas.f_inicio_periodo(p_fecha, per.codigo)
             AND t.fecha_hora    <= p_fecha;
          IF p_restante IS NULL OR l_valor - l_usado < p_restante THEN
            p_restante := l_valor - l_usado;
            p_id_regla := l_id;
          END IF;
        END IF;
      END IF;
    END LOOP;
  END calcular_cuota;

  -- ----------------------------------------------------------
  -- Publicos
  -- ----------------------------------------------------------
  PROCEDURE p_registrar_carga_vehicular(
    p_id_surtidor       IN  NUMBER,
    p_id_vehiculo       IN  NUMBER,
    p_id_persona        IN  NUMBER,
    p_id_combustible    IN  NUMBER,
    p_cantidad          IN  NUMBER,
    p_fecha_hora        IN  TIMESTAMP DEFAULT SYSTIMESTAMP,
    p_huella_verificada IN  CHAR      DEFAULT 'S',
    p_rfid_leido        IN  CHAR      DEFAULT 'S',
    p_id_transaccion    OUT NUMBER,
    p_nro_ticket        OUT NUMBER,
    p_estado            OUT VARCHAR2) IS
    l_fecha      TIMESTAMP := NVL(p_fecha_hora, SYSTIMESTAMP);
    l_id_intl    NUMBER;
    l_id_sub     NUMBER;
    l_ficha      NUMBER;
    l_comb_ficha NUMBER;
    l_res        pkg_deteccion.t_incumplimientos;
    l_motivo     VARCHAR2(25);   -- motivo de la parte a precio internacional
    l_cant_sub   NUMBER := 0;
    l_id_benef   NUMBER;
    l_titular    NUMBER;
    l_restante   NUMBER;
    l_id_cuota   NUMBER;
    l_linea      NUMBER := 0;
  BEGIN
    g_ultimas := NULL;
    IF p_rfid_leido IS NULL OR p_rfid_leido NOT IN ('S', 'N') THEN
      RAISE_APPLICATION_ERROR(-20001, 'Indicador de RFID invalido (S/N)');
    END IF;
    l_id_intl := validar_comun(p_id_surtidor, p_id_combustible, p_cantidad, p_id_persona,
                               p_huella_verificada, l_fecha);

    BEGIN
      SELECT v.id_ficha, f.id_combustible
        INTO l_ficha, l_comb_ficha
        FROM vehiculo v
        LEFT JOIN ficha_aduana f ON f.id_ficha = v.id_ficha
       WHERE v.id_vehiculo = p_id_vehiculo;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20003, 'Vehiculo inexistente: ' || p_id_vehiculo);
    END;
    IF l_ficha IS NOT NULL AND l_comb_ficha <> p_id_combustible THEN
      RAISE_APPLICATION_ERROR(-20004, 'El combustible ' || p_id_combustible
                                      || ' no corresponde al de la ficha del vehiculo ' || p_id_vehiculo);
    END IF;

    -- 1. Reglas de anomalia (antes de registrar)
    pkg_deteccion.p_evaluar_carga(p_id_vehiculo, p_id_persona, p_id_surtidor, p_id_combustible,
                                  p_cantidad, l_fecha, l_res);
    g_ultimas := pkg_deteccion.f_codigos(l_res);

    -- 2. Bloqueo (D-2): se guarda el intento, sin detalle ni beneficio
    IF pkg_deteccion.f_hay_bloqueante(l_res) THEN
      insertar_transaccion(p_id_surtidor, p_id_combustible, p_id_persona, l_fecha, p_cantidad,
                           'VEHICULAR', p_huella_verificada, 'BLOQUEADA', p_id_transaccion, p_nro_ticket);
      INSERT INTO carga_vehicular (id_transaccion, id_vehiculo, id_beneficio, id_regla_cuota, rfid_leido)
        VALUES (p_id_transaccion, p_id_vehiculo, NULL, NULL, p_rfid_leido);
      pkg_deteccion.p_registrar_alertas(p_id_transaccion, l_res);
      p_estado := 'BLOQUEADA';
      RETURN;
    END IF;

    -- 3. Motivo de precio
    IF p_huella_verificada = 'N' OR p_id_persona IS NULL
       OR (l_ficha IS NOT NULL AND p_rfid_leido = 'N') THEN
      l_motivo := 'FALLA_IDENTIFICACION';
    ELSIF l_ficha IS NULL THEN
      l_motivo := 'EXTRANJERO';
    ELSE
      l_id_sub := pkg_reglas.f_id_precio_vigente(p_id_combustible, 'SUBVENCIONADO', l_fecha);
      IF l_id_sub IS NULL THEN
        l_motivo := 'SIN_SUBVENCION';
      ELSE
        BEGIN
          SELECT id_beneficio, id_persona
            INTO l_id_benef, l_titular
            FROM (SELECT id_beneficio, id_persona
                    FROM registro_beneficio
                   WHERE id_vehiculo   = p_id_vehiculo
                     AND fecha_inicio <= CAST(l_fecha AS DATE)
                     AND (fecha_fin IS NULL OR CAST(l_fecha AS DATE) < fecha_fin)
                   ORDER BY fecha_inicio DESC, id_beneficio DESC)
           WHERE ROWNUM = 1;
        EXCEPTION
          WHEN NO_DATA_FOUND THEN
            l_id_benef := NULL;
        END;

        IF l_id_benef IS NULL THEN
          l_motivo := 'SIN_BENEFICIO';
        ELSIF l_titular <> p_id_persona THEN
          l_motivo   := 'NO_TITULAR';
          l_id_benef := NULL;
        ELSE
          calcular_cuota(p_id_vehiculo, p_id_surtidor, p_id_combustible, l_fecha, l_restante, l_id_cuota);
          IF l_id_cuota IS NULL THEN
            l_motivo   := 'SIN_SUBVENCION';   -- no hay cuota definida para ese vehiculo y combustible
            l_id_benef := NULL;
          ELSE
            l_cant_sub := LEAST(p_cantidad, GREATEST(l_restante, 0));
            l_motivo   := 'EXCEDE_CUOTA';
          END IF;
        END IF;
      END IF;
    END IF;

    -- 4. Registro APROBADA
    insertar_transaccion(p_id_surtidor, p_id_combustible, p_id_persona, l_fecha, p_cantidad,
                         'VEHICULAR', p_huella_verificada, 'APROBADA', p_id_transaccion, p_nro_ticket);
    INSERT INTO carga_vehicular (id_transaccion, id_vehiculo, id_beneficio, id_regla_cuota, rfid_leido)
      VALUES (p_id_transaccion, p_id_vehiculo, l_id_benef, l_id_cuota, p_rfid_leido);
    insertar_linea(p_id_transaccion, l_linea, l_id_sub,  l_cant_sub,              'CUOTA');
    insertar_linea(p_id_transaccion, l_linea, l_id_intl, p_cantidad - l_cant_sub, l_motivo);

    -- 5. Alertas no bloqueantes (D-5: en cada carga que incumple)
    pkg_deteccion.p_registrar_alertas(p_id_transaccion, l_res);
    p_estado := 'APROBADA';
  END p_registrar_carga_vehicular;

  PROCEDURE p_registrar_compra_bidon(
    p_id_surtidor       IN  NUMBER,
    p_id_persona        IN  NUMBER,
    p_id_combustible    IN  NUMBER,
    p_cantidad          IN  NUMBER,
    p_nro_recipientes   IN  NUMBER,
    p_motivo_declarado  IN  VARCHAR2  DEFAULT NULL,
    p_fecha_hora        IN  TIMESTAMP DEFAULT SYSTIMESTAMP,
    p_huella_verificada IN  CHAR      DEFAULT 'S',
    p_id_transaccion    OUT NUMBER,
    p_nro_ticket        OUT NUMBER,
    p_estado            OUT VARCHAR2) IS
    l_fecha      TIMESTAMP := NVL(p_fecha_hora, SYSTIMESTAMP);
    l_id_intl    NUMBER;
    l_id_sub     NUMBER;
    l_id_regla   NUMBER;
    l_max        NUMBER;
    l_permiso    NUMBER;
    l_autorizado NUMBER;
    l_res        pkg_deteccion.t_incumplimientos;
    l_motivo     VARCHAR2(25);
    l_cant_sub   NUMBER := 0;
    l_linea      NUMBER := 0;
  BEGIN
    g_ultimas := NULL;
    IF p_id_persona IS NULL THEN
      RAISE_APPLICATION_ERROR(-20006, 'La compra en bidon requiere una persona identificada');
    END IF;
    l_id_intl := validar_comun(p_id_surtidor, p_id_combustible, p_cantidad, p_id_persona,
                               p_huella_verificada, l_fecha);

    -- Maximo de recipientes (regla OPERATIVA)
    IF p_nro_recipientes IS NULL OR p_nro_recipientes <= 0 THEN
      RAISE_APPLICATION_ERROR(-20007, 'Numero de recipientes invalido');
    END IF;
    l_id_regla := pkg_deteccion.f_id_regla_operacion('MAX_RECIPIENTES_BIDON', l_fecha,
                                                     p_id_surtidor, p_id_combustible);
    IF l_id_regla IS NOT NULL THEN
      SELECT valor INTO l_max FROM regla WHERE id_regla = l_id_regla;
      IF p_nro_recipientes > l_max THEN
        RAISE_APPLICATION_ERROR(-20007, 'Supera el maximo de ' || l_max || ' recipientes por compra');
      END IF;
    END IF;

    -- Permiso ANH vigente de la persona para ese combustible
    BEGIN
      SELECT id_permiso, cantidad_autorizada
        INTO l_permiso, l_autorizado
        FROM (SELECT id_permiso, cantidad_autorizada
                FROM permiso_bidon
               WHERE id_persona     = p_id_persona
                 AND id_combustible = p_id_combustible
                 AND fecha_inicio  <= CAST(l_fecha AS DATE)
                 AND CAST(l_fecha AS DATE) < fecha_fin
               ORDER BY fecha_inicio DESC, id_permiso DESC)
       WHERE ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        l_permiso := NULL;
    END;

    -- 1. Reglas de anomalia
    pkg_deteccion.p_evaluar_bidon(p_id_persona, p_id_surtidor, p_id_combustible, p_cantidad,
                                  l_fecha, l_permiso, l_res);
    g_ultimas := pkg_deteccion.f_codigos(l_res);

    -- 2. Bloqueo
    IF pkg_deteccion.f_hay_bloqueante(l_res) THEN
      insertar_transaccion(p_id_surtidor, p_id_combustible, p_id_persona, l_fecha, p_cantidad,
                           'BIDON', p_huella_verificada, 'BLOQUEADA', p_id_transaccion, p_nro_ticket);
      INSERT INTO compra_bidon (id_transaccion, id_permiso, nro_recipientes, motivo_declarado)
        VALUES (p_id_transaccion, l_permiso, p_nro_recipientes, p_motivo_declarado);
      pkg_deteccion.p_registrar_alertas(p_id_transaccion, l_res);
      p_estado := 'BLOQUEADA';
      RETURN;
    END IF;

    -- 3. Motivo de precio
    IF p_huella_verificada = 'N' THEN
      l_motivo := 'FALLA_IDENTIFICACION';
    ELSIF l_permiso IS NULL THEN
      l_motivo := 'SIN_PERMISO';
    ELSE
      l_id_sub := pkg_reglas.f_id_precio_vigente(p_id_combustible, 'SUBVENCIONADO', l_fecha);
      IF l_id_sub IS NULL THEN
        l_motivo := 'SIN_SUBVENCION';
      ELSE
        l_cant_sub := LEAST(p_cantidad,
                            GREATEST(l_autorizado - pkg_deteccion.f_consumo_permiso(l_permiso, l_fecha), 0));
        l_motivo   := 'EXCEDE_PERMISO';
      END IF;
    END IF;

    -- 4. Registro APROBADA
    insertar_transaccion(p_id_surtidor, p_id_combustible, p_id_persona, l_fecha, p_cantidad,
                         'BIDON', p_huella_verificada, 'APROBADA', p_id_transaccion, p_nro_ticket);
    INSERT INTO compra_bidon (id_transaccion, id_permiso, nro_recipientes, motivo_declarado)
      VALUES (p_id_transaccion, l_permiso, p_nro_recipientes, p_motivo_declarado);
    insertar_linea(p_id_transaccion, l_linea, l_id_sub,  l_cant_sub,              'CUOTA');
    insertar_linea(p_id_transaccion, l_linea, l_id_intl, p_cantidad - l_cant_sub, l_motivo);

    -- 5. Alertas no bloqueantes
    pkg_deteccion.p_registrar_alertas(p_id_transaccion, l_res);
    p_estado := 'APROBADA';
  END p_registrar_compra_bidon;

  FUNCTION f_cuota_disponible(
    p_id_vehiculo    IN NUMBER,
    p_id_surtidor    IN NUMBER,
    p_id_combustible IN NUMBER,
    p_fecha          IN TIMESTAMP DEFAULT SYSTIMESTAMP) RETURN NUMBER IS
    l_restante NUMBER;
    l_id       NUMBER;
  BEGIN
    calcular_cuota(p_id_vehiculo, p_id_surtidor, p_id_combustible, NVL(p_fecha, SYSTIMESTAMP),
                   l_restante, l_id);
    IF l_id IS NULL THEN
      RETURN NULL;
    END IF;
    RETURN GREATEST(l_restante, 0);
  END f_cuota_disponible;

  FUNCTION f_ultimas_alertas RETURN VARCHAR2 IS
  BEGIN
    RETURN g_ultimas;
  END f_ultimas_alertas;

END pkg_transacciones;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Verificacion: pruebas T01 a T18 del plan sobre un escenario de prueba
-- creado dentro de un SAVEPOINT y deshecho al final.
-- Semana del lunes 2026-11-16 (cuota AUTO = 40 L/dia).
-- ------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  l_n      NUMBER;
  l_gas    NUMBER; l_diesel NUMBER; l_prem NUMBER; l_kero NUMBER;
  l_auto   NUMBER; l_moto NUMBER;
  l_est_a  NUMBER; l_est_c NUMBER; l_est_p NUMBER;
  l_sur_a  NUMBER; l_sur_c NUMBER; l_sur_p NUMBER; l_sur_x NUMBER;
  l_p1     NUMBER; l_p2 NUMBER; l_p3 NUMBER;
  l_v1     NUMBER; l_v3 NUMBER; l_v4 NUMBER; l_v5 NUMBER;
  l_regla_max NUMBER;
  l_tx     NUMBER;
  l_tk     NUMBER;
  l_tk_ant NUMBER;
  l_est    VARCHAR2(10);
  c_lunes  CONSTANT TIMESTAMP := TIMESTAMP '2026-11-16 00:00:00';

  PROCEDURE chequear(p_nombre IN VARCHAR2, p_ok IN BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      DBMS_OUTPUT.PUT_LINE('OK    ' || p_nombre);
    ELSE
      RAISE_APPLICATION_ERROR(-20999, '07_pkg_transacciones: FALLO ' || p_nombre);
    END IF;
  END chequear;

  FUNCTION h(p_horas IN NUMBER) RETURN TIMESTAMP IS
  BEGIN
    RETURN c_lunes + NUMTODSINTERVAL(p_horas, 'HOUR');
  END h;

  -- 'MOTIVO:cantidad|MOTIVO:cantidad' en orden de linea
  FUNCTION lineas(p_id IN NUMBER) RETURN VARCHAR2 IS
    l_txt VARCHAR2(4000);
  BEGIN
    SELECT LISTAGG(motivo_precio || ':' || RTRIM(RTRIM(TO_CHAR(cantidad, 'FM9999999990.000'), '0'), '.'), '|')
             WITHIN GROUP (ORDER BY nro_linea)
      INTO l_txt
      FROM detalle_transaccion WHERE id_transaccion = p_id;
    RETURN l_txt;
  END lineas;

  FUNCTION valor_cuota(p_id IN NUMBER) RETURN NUMBER IS
    l_v NUMBER;
  BEGIN
    SELECT r.valor INTO l_v
      FROM carga_vehicular cv JOIN regla r ON r.id_regla = cv.id_regla_cuota
     WHERE cv.id_transaccion = p_id;
    RETURN l_v;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END valor_cuota;

  FUNCTION alertas_de(p_id IN NUMBER, p_codigo IN VARCHAR2) RETURN NUMBER IS
    l_c NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_c
      FROM alerta a JOIN regla r ON r.id_regla = a.id_regla
      JOIN tipo_regla tr ON tr.id_tipo_regla = r.id_tipo_regla
     WHERE a.id_transaccion = p_id AND tr.codigo = p_codigo;
    RETURN l_c;
  END alertas_de;

  FUNCTION nueva_estacion(p_muni IN VARCHAR2, p_nombre IN VARCHAR2, p_front IN CHAR,
                          p_surtidor OUT NUMBER) RETURN NUMBER IS
    l_id NUMBER;
    l_mu NUMBER;
  BEGIN
    SELECT id_municipio INTO l_mu FROM municipio WHERE nombre = p_muni;
    INSERT INTO estacion (id_municipio, nombre, nit, zona, latitud, longitud, es_fronteriza)
      VALUES (l_mu, p_nombre, 'NIT-' || p_nombre, 'Prueba', -17, -66, p_front)
      RETURNING id_estacion INTO l_id;
    INSERT INTO surtidor (id_estacion, codigo) VALUES (l_id, 'S1') RETURNING id_surtidor INTO p_surtidor;
    RETURN l_id;
  END nueva_estacion;

  FUNCTION nueva_persona(p_tipo IN VARCHAR2, p_doc IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    INSERT INTO persona (tipo_documento, nro_documento, nombres, apellido_paterno, nacionalidad, fecha_registro)
      VALUES (p_tipo, p_doc, 'Prueba', p_doc, 'BOLIVIANA', DATE '2026-01-01')
      RETURNING id_persona INTO l_id;
    INSERT INTO huella_digital (id_persona, plantilla, fecha_enrolamiento)
      VALUES (l_id, TO_BLOB(HEXTORAW('00')), DATE '2026-01-01');
    RETURN l_id;
  END nueva_persona;

  -- Vehiculo nacional con propietario RUAT y, si p_benef = 'S', beneficio
  FUNCTION nuevo_vehiculo(p_placa IN VARCHAR2, p_tipo IN NUMBER, p_comb IN NUMBER, p_cc IN NUMBER,
                          p_tanque IN NUMBER, p_duenio IN NUMBER, p_benef IN CHAR) RETURN NUMBER IS
    l_ficha NUMBER;
    l_id    NUMBER;
  BEGIN
    INSERT INTO ficha_aduana (nro_chasis, id_combustible, marca, modelo, anio_fabricacion, cilindrada, capacidad_tanque)
      VALUES ('CH-' || p_placa, p_comb, 'Marca', 'Modelo', 2018, p_cc, p_tanque) RETURNING id_ficha INTO l_ficha;
    INSERT INTO vehiculo (id_tipo_vehiculo, id_ficha, placa, codigo_rfid, fecha_registro)
      VALUES (p_tipo, l_ficha, p_placa, 'RFID-' || p_placa, DATE '2026-01-01') RETURNING id_vehiculo INTO l_id;
    INSERT INTO registro_ruat (id_vehiculo, id_persona, clase, servicio, fecha_alta)
      VALUES (l_id, p_duenio, 'AUTOMOVIL', 'PARTICULAR', DATE '2026-01-01');
    IF p_benef = 'S' THEN
      INSERT INTO registro_beneficio (id_vehiculo, id_persona, id_regla, fecha_inicio)
        VALUES (l_id, p_duenio, l_regla_max, DATE '2026-01-01');
    END IF;
    RETURN l_id;
  END nuevo_vehiculo;

  PROCEDURE carga(p_sur IN NUMBER, p_veh IN NUMBER, p_per IN NUMBER, p_comb IN NUMBER,
                  p_cant IN NUMBER, p_ts IN TIMESTAMP, p_huella IN CHAR DEFAULT 'S') IS
  BEGIN
    l_tk_ant := l_tk;
    pkg_transacciones.p_registrar_carga_vehicular(
      p_id_surtidor => p_sur, p_id_vehiculo => p_veh, p_id_persona => p_per,
      p_id_combustible => p_comb, p_cantidad => p_cant, p_fecha_hora => p_ts,
      p_huella_verificada => p_huella, p_rfid_leido => 'S',
      p_id_transaccion => l_tx, p_nro_ticket => l_tk, p_estado => l_est);
  END carga;

  PROCEDURE bidon(p_sur IN NUMBER, p_per IN NUMBER, p_cant IN NUMBER, p_recip IN NUMBER, p_ts IN TIMESTAMP) IS
  BEGIN
    pkg_transacciones.p_registrar_compra_bidon(
      p_id_surtidor => p_sur, p_id_persona => p_per, p_id_combustible => l_gas,
      p_cantidad => p_cant, p_nro_recipientes => p_recip, p_motivo_declarado => 'Generador',
      p_fecha_hora => p_ts, p_id_transaccion => l_tx, p_nro_ticket => l_tk, p_estado => l_est);
  END bidon;

  PROCEDURE espera_error(p_nombre IN VARCHAR2, p_codigo IN NUMBER, p_sur IN NUMBER, p_veh IN NUMBER,
                         p_per IN NUMBER, p_comb IN NUMBER, p_cant IN NUMBER) IS
  BEGIN
    carga(p_sur, p_veh, p_per, p_comb, p_cant, h(150));
    chequear(p_nombre || ' (no lanzo error)', FALSE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = p_codigo THEN
        DBMS_OUTPUT.PUT_LINE('OK    ' || p_nombre || ' (' || p_codigo || ')');
      ELSE
        RAISE;
      END IF;
  END espera_error;
BEGIN
  SELECT COUNT(*) INTO l_n FROM all_objects
   WHERE owner = l_schema AND object_name = 'PKG_TRANSACCIONES' AND status = 'VALID';
  chequear('pkg_transacciones (especificacion y cuerpo) VALID', l_n = 2);

  SAVEPOINT sp_07;
  SELECT id_combustible   INTO l_gas    FROM combustible   WHERE nombre = 'Gasolina Especial';
  SELECT id_combustible   INTO l_diesel FROM combustible   WHERE nombre = 'Diesel Oil';
  SELECT id_combustible   INTO l_prem   FROM combustible   WHERE nombre = 'Gasolina Premium';
  SELECT id_tipo_vehiculo INTO l_auto   FROM tipo_vehiculo WHERE nombre = 'AUTO';
  SELECT id_tipo_vehiculo INTO l_moto   FROM tipo_vehiculo WHERE nombre = 'MOTO';
  l_regla_max := pkg_reglas.f_id_regla_vigente('MAX_VEHICULOS_PERSONA', c_lunes);

  -- Escenario
  l_est_a := nueva_estacion('Cochabamba',  'TST-A', 'N', l_sur_a);
  l_est_c := nueva_estacion('Desaguadero', 'TST-C', 'S', l_sur_c);
  l_est_p := nueva_estacion('Cobija',      'TST-P', 'N', l_sur_p);
  INSERT INTO surtidor (id_estacion, codigo, estado) VALUES (l_est_a, 'S9', 'INACTIVO')
    RETURNING id_surtidor INTO l_sur_x;
  INSERT INTO tiempo_viaje VALUES (l_est_a, l_est_c, 420,  DATE '2026-01-01');
  INSERT INTO tiempo_viaje VALUES (l_est_a, l_est_p, 1500, DATE '2026-01-01');
  l_p1 := nueva_persona('CI', 'TST-P1');
  l_p2 := nueva_persona('CI', 'TST-P2');
  l_p3 := nueva_persona('PASAPORTE', 'TST-P3');
  l_v1 := nuevo_vehiculo('TST-001', l_auto, l_gas,  1600, 50, l_p1, 'S');
  l_v4 := nuevo_vehiculo('TST-004', l_moto, l_gas,  150,  12, l_p2, 'N');
  l_v5 := nuevo_vehiculo('TST-005', l_auto, l_prem, 2000, 60, l_p2, 'S');
  INSERT INTO vehiculo (id_tipo_vehiculo, placa, pais_placa, fecha_registro)
    VALUES (l_auto, 'TST-003', 'PER', DATE '2026-01-01') RETURNING id_vehiculo INTO l_v3;
  INSERT INTO permiso_bidon (id_persona, id_combustible, id_tipo_periodo, nro_resolucion_anh, motivo,
                             cantidad_autorizada, fecha_emision, fecha_inicio, fecha_fin)
    VALUES (l_p2, l_gas, pkg_reglas.f_id_tipo_periodo('DIA'), 'ANH-TST-1', 'Generador agricola',
            100, DATE '2026-10-25', DATE '2026-11-01', DATE '2026-12-01');

  -- T01 cuota completa
  carga(l_sur_a, l_v1, l_p1, l_gas, 30, h(8));
  chequear('T01 APROBADA con ticket',       l_est = 'APROBADA' AND l_tk IS NOT NULL);
  chequear('T01 lineas CUOTA:30',           lineas(l_tx) = 'CUOTA:30');
  chequear('T01 cuota aplicada = 40',       valor_cuota(l_tx) = 40);
  -- T02 resto de la cuota + exceso
  carga(l_sur_a, l_v1, l_p1, l_gas, 20, h(10));
  chequear('T02 CUOTA:10|EXCEDE_CUOTA:10',  lineas(l_tx) = 'CUOTA:10|EXCEDE_CUOTA:10');
  -- T03 extranjero
  carga(l_sur_a, l_v3, l_p3, l_gas, 30, h(11));
  chequear('T03 EXTRANJERO:30',             lineas(l_tx) = 'EXTRANJERO:30');
  -- T04 sin beneficio
  carga(l_sur_a, l_v4, l_p2, l_gas, 5, h(12));
  chequear('T04 SIN_BENEFICIO:5',           lineas(l_tx) = 'SIN_BENEFICIO:5');
  -- T05 no titular (martes)
  carga(l_sur_a, l_v1, l_p2, l_gas, 10, h(32));
  chequear('T05 NO_TITULAR:10',             lineas(l_tx) = 'NO_TITULAR:10');
  -- T06 falla de identificacion (miercoles)
  carga(l_sur_a, l_v1, l_p1, l_gas, 10, h(56), 'N');
  chequear('T06 FALLA_IDENTIFICACION:10',   lineas(l_tx) = 'FALLA_IDENTIFICACION:10');
  -- T07 combustible sin precio subvencionado
  carga(l_sur_a, l_v5, l_p2, l_prem, 20, h(57));
  chequear('T07 SIN_SUBVENCION:20',         lineas(l_tx) = 'SIN_SUBVENCION:20');
  -- T08 bloqueo por tanque (60 L en tanque de 50)
  carga(l_sur_a, l_v1, l_p1, l_gas, 60, h(80));
  chequear('T08 BLOQUEADA',                 l_est = 'BLOQUEADA');
  chequear('T08 sin detalle',               lineas(l_tx) IS NULL);
  chequear('T08 alerta TANQUE_EXCEDIDO',    alertas_de(l_tx, 'TANQUE_EXCEDIDO') = 1);
  chequear('T08 f_ultimas_alertas informa', INSTR(pkg_transacciones.f_ultimas_alertas, 'TANQUE_EXCEDIDO') > 0);
  -- T09 el intento bloqueado no suma: 40 L se aprueban con cuota completa
  carga(l_sur_a, l_v1, l_p1, l_gas, 40, h(81));
  chequear('T09 APROBADA tras bloqueo',     l_est = 'APROBADA' AND lineas(l_tx) = 'CUOTA:40');
  -- T10 tickets correlativos
  chequear('T10 ticket mayor al anterior',  l_tk > l_tk_ant);
  -- T11 validaciones
  espera_error('T11 cantidad cero',               -20001, l_sur_a, l_v1, l_p1, l_gas, 0);
  espera_error('T11 surtidor inactivo',           -20002, l_sur_x, l_v1, l_p1, l_gas, 10);
  espera_error('T11 vehiculo inexistente',        -20003, l_sur_a, -1,   l_p1, l_gas, 10);
  espera_error('T11 combustible distinto a ficha', -20004, l_sur_a, l_v1, l_p1, l_diesel, 10);
  espera_error('T11 persona inexistente',         -20006, l_sur_a, l_v1, -1,   l_gas, 10);
  INSERT INTO combustible (id_unidad, nombre)
    VALUES ((SELECT id_unidad FROM unidad_medida WHERE simbolo = 'L'), 'TST Kerosene')
    RETURNING id_combustible INTO l_kero;
  espera_error('T11 sin precio internacional',    -20005, l_sur_a, l_v3, l_p3, l_kero, 10);
  -- T12 bidon dentro del permiso (viernes)
  bidon(l_sur_a, l_p2, 50, 2, h(104));
  chequear('T12 bidon CUOTA:50',            l_est = 'APROBADA' AND lineas(l_tx) = 'CUOTA:50');
  -- T13 bidon que excede el permiso diario de 100
  bidon(l_sur_a, l_p2, 60, 3, h(106));
  chequear('T13 CUOTA:50|EXCEDE_PERMISO:10', lineas(l_tx) = 'CUOTA:50|EXCEDE_PERMISO:10');
  chequear('T13 alerta BIDON_EXCEDE_PERMISO', alertas_de(l_tx, 'BIDON_EXCEDE_PERMISO') = 1);
  -- T14 bidon sin permiso: bloqueado
  bidon(l_sur_a, l_p1, 20, 1, h(107));
  chequear('T14 bidon sin permiso BLOQUEADA', l_est = 'BLOQUEADA' AND lineas(l_tx) IS NULL);
  chequear('T14 alerta BIDON_SIN_PERMISO',  alertas_de(l_tx, 'BIDON_SIN_PERMISO') = 1);
  -- T15 demasiados recipientes
  BEGIN
    bidon(l_sur_a, l_p2, 20, 4, h(108));
    chequear('T15 rechaza 4 recipientes', FALSE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20007 THEN
        DBMS_OUTPUT.PUT_LINE('OK    T15 rechaza 4 recipientes (-20007)');
      ELSE
        RAISE;
      END IF;
  END;
  -- T16 cuota del departamento de Pando (30) (sabado)
  carga(l_sur_p, l_v1, l_p1, l_gas, 35, h(130));
  chequear('T16 Pando CUOTA:30|EXCEDE_CUOTA:5', lineas(l_tx) = 'CUOTA:30|EXCEDE_CUOTA:5');
  chequear('T16 cuota aplicada = 30',       valor_cuota(l_tx) = 30);
  -- T17 regla historica: en junio la cuota era 50
  carga(l_sur_a, l_v1, l_p1, l_gas, 30, TIMESTAMP '2026-06-15 10:00:00');
  chequear('T17 cuota de junio = 50',       valor_cuota(l_tx) = 50);
  -- T18 cuota disponible el lunes ya agotada
  chequear('T18 cuota disponible lunes = 0',
           pkg_transacciones.f_cuota_disponible(l_v1, l_sur_a, l_gas, h(23)) = 0);
  chequear('T18 cuota disponible martes = 40',
           pkg_transacciones.f_cuota_disponible(l_v1, l_sur_a, l_gas, h(26)) = 40);

  -- Invariantes sobre lo registrado
  SELECT COUNT(*) INTO l_n FROM transaccion t
   WHERE t.estado = 'APROBADA'
     AND t.cantidad_total <> (SELECT NVL(SUM(d.cantidad), 0) FROM detalle_transaccion d
                               WHERE d.id_transaccion = t.id_transaccion);
  chequear('I1 toda APROBADA suma su detalle', l_n = 0);
  SELECT COUNT(*) INTO l_n FROM transaccion t
   WHERE t.estado = 'BLOQUEADA'
     AND EXISTS (SELECT 1 FROM detalle_transaccion d WHERE d.id_transaccion = t.id_transaccion);
  chequear('I2 ninguna BLOQUEADA tiene detalle', l_n = 0);
  SELECT COUNT(*) INTO l_n FROM transaccion t
   WHERE t.estado = 'BLOQUEADA'
     AND NOT EXISTS (SELECT 1 FROM alerta a WHERE a.id_transaccion = t.id_transaccion
                        AND pkg_reglas.f_es_bloqueante(a.id_regla) = 'S');
  chequear('I7 toda BLOQUEADA tiene alerta bloqueante', l_n = 0);

  ROLLBACK TO sp_07;
  SELECT COUNT(*) INTO l_n FROM estacion WHERE nombre LIKE 'TST-%';
  chequear('no quedaron datos de prueba', l_n = 0);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/
