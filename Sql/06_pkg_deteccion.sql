-- ============================================================
-- 06_pkg_deteccion.sql
-- Paquete pkg_deteccion: evalua las reglas de anomalia ANTES de
-- registrar una operacion (para decidir si se bloquea), registra las
-- alertas, concilia estaciones contra YPFB y revisa alertas.
-- Re-ejecutable (CREATE OR REPLACE). El paquete NO hace COMMIT ni
-- ROLLBACK: eso lo decide quien lo llama.
-- Decisiones aplicadas:
--   D-2  una anomalia de TRANSACCION con gravedad ALTA bloquea la carga
--   D-5  alerta en CADA operacion que incumple (no solo al cruzar)
--   Todo acumulado cuenta solo transacciones APROBADA hasta la hora de
--   la operacion, mas la cantidad que se esta evaluando.
-- Errores: -20002 surtidor, -20003 vehiculo, -20004 combustible,
--          -20006 persona, -20008 revision invalida.
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ------------------------------------------------------------
-- Especificacion (contrato del plan v2, seccion 5.2)
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE pkg_deteccion AS
  -- Una regla incumplida por una operacion
  TYPE t_incumplimiento IS RECORD (
    id_regla        NUMBER,
    codigo_regla    VARCHAR2(40),
    bloqueante      CHAR(1),          -- 'S' si bloquea la operacion
    valor_observado NUMBER,
    valor_umbral    NUMBER,
    descripcion     VARCHAR2(400));
  TYPE t_incumplimientos IS TABLE OF t_incumplimiento;

  -- Regla vigente para una operacion: arma el contexto (tipo de vehiculo,
  -- categoria de cilindrada, fronteriza y departamento de la estacion) y
  -- llama a pkg_reglas.f_id_regla_vigente. NULL si ninguna aplica.
  FUNCTION f_id_regla_operacion(
    p_codigo_regla    IN VARCHAR2,
    p_fecha           IN TIMESTAMP,
    p_id_surtidor     IN NUMBER,
    p_id_combustible  IN NUMBER,
    p_id_vehiculo     IN NUMBER   DEFAULT NULL,
    p_codigo_periodo  IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;

  -- Cantidad APROBADA comprada con un permiso de bidon en el periodo del
  -- permiso que contiene p_fecha (sin contar p_id_excluir).
  FUNCTION f_consumo_permiso(
    p_id_permiso  IN NUMBER,
    p_fecha       IN TIMESTAMP,
    p_id_excluir  IN NUMBER DEFAULT NULL) RETURN NUMBER;

  -- Evalua una carga vehicular propuesta (todavia no insertada).
  PROCEDURE p_evaluar_carga(
    p_id_vehiculo    IN  NUMBER,
    p_id_persona     IN  NUMBER,
    p_id_surtidor    IN  NUMBER,
    p_id_combustible IN  NUMBER,
    p_cantidad       IN  NUMBER,
    p_fecha_hora     IN  TIMESTAMP,
    p_resultado      OUT t_incumplimientos);

  -- Evalua una compra de bidon propuesta. p_id_permiso NULL = sin permiso.
  PROCEDURE p_evaluar_bidon(
    p_id_persona     IN  NUMBER,
    p_id_surtidor    IN  NUMBER,
    p_id_combustible IN  NUMBER,
    p_cantidad       IN  NUMBER,
    p_fecha_hora     IN  TIMESTAMP,
    p_id_permiso     IN  NUMBER,
    p_resultado      OUT t_incumplimientos);

  FUNCTION f_hay_bloqueante(p_resultado IN t_incumplimientos) RETURN BOOLEAN;

  -- Codigos incumplidos separados por coma (para mensajes y pruebas)
  FUNCTION f_codigos(p_resultado IN t_incumplimientos) RETURN VARCHAR2;

  -- Inserta una alerta por incumplimiento. No duplica (regla, transaccion).
  -- p_fecha_deteccion NULL = fecha y hora de la transaccion.
  PROCEDURE p_registrar_alertas(
    p_id_transaccion  IN NUMBER,
    p_resultado       IN t_incumplimientos,
    p_fecha_deteccion IN TIMESTAMP DEFAULT NULL);

  -- Vuelve a evaluar una transaccion ya registrada con las reglas vigentes
  -- a su fecha (sin contarse a si misma en el historial) y agrega las
  -- alertas que falten. p_codigos: lista separada por comas para limitar
  -- las reglas (NULL = todas). Devuelve cuantas alertas nuevas creo.
  PROCEDURE p_reevaluar_transaccion(
    p_id_transaccion IN  NUMBER,
    p_codigos        IN  VARCHAR2 DEFAULT NULL,
    p_nuevas         OUT NUMBER);

  -- Conciliacion YPFB por semanas ISO completas en [p_desde, p_hasta)
  PROCEDURE p_conciliar_estacion(
    p_id_estacion IN  NUMBER,
    p_desde       IN  DATE,
    p_hasta       IN  DATE,
    p_nuevas      OUT NUMBER);
  PROCEDURE p_conciliar_todas(
    p_desde  IN  DATE,
    p_hasta  IN  DATE,
    p_nuevas OUT NUMBER);

  -- PENDIENTE -> REVISADA (CONFIRMADA o FALSO_POSITIVO). Solo usuarios
  -- ACTIVO con rol ADMIN o FISCALIZADOR. p_fecha_revision NULL = ahora.
  PROCEDURE p_revisar_alerta(
    p_id_alerta      IN NUMBER,
    p_resultado      IN VARCHAR2,
    p_id_usuario     IN NUMBER,
    p_observacion    IN VARCHAR2  DEFAULT NULL,
    p_fecha_revision IN TIMESTAMP DEFAULT NULL);
END pkg_deteccion;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Cuerpo
-- ------------------------------------------------------------
CREATE OR REPLACE PACKAGE BODY pkg_deteccion AS

  -- Regla encontrada para el contexto actual
  TYPE t_regla IS RECORD (
    id_regla  NUMBER,
    valor     NUMBER,
    valor_sec NUMBER,
    periodo   VARCHAR2(10));
  TYPE t_reglas IS TABLE OF t_regla;

  -- Contexto de la operacion que se evalua
  TYPE t_contexto IS RECORD (
    fecha            TIMESTAMP,
    excluir          NUMBER,
    codigos          VARCHAR2(4000),
    cantidad         NUMBER,
    id_combustible   NUMBER,
    unidad           VARCHAR2(5),
    id_surtidor      NUMBER,
    id_estacion      NUMBER,
    estacion         VARCHAR2(150),
    es_fronteriza    CHAR(1),
    id_departamento  NUMBER,
    id_persona       NUMBER,
    documento        VARCHAR2(40),
    id_vehiculo      NUMBER,
    placa            VARCHAR2(15),
    id_tipo_vehiculo NUMBER,
    id_categoria     NUMBER,
    capacidad_tanque NUMBER,
    id_permiso       NUMBER);
  g       t_contexto;
  g_vacio t_contexto;   -- para limpiar el contexto

  -- ----------------------------------------------------------
  -- Utilitarios
  -- ----------------------------------------------------------
  FUNCTION fmt(p_n IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_n IS NULL THEN
      RETURN '-';
    END IF;
    RETURN RTRIM(RTRIM(TO_CHAR(ROUND(p_n, 3), 'FM9999999999990.000'), '0'), '.');
  END fmt;

  FUNCTION aplica(p_codigo IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN g.codigos IS NULL
        OR INSTR(',' || REPLACE(g.codigos, ' ') || ',', ',' || p_codigo || ',') > 0;
  END aplica;

  PROCEDURE agregar(
    p_res    IN OUT NOCOPY t_incumplimientos,
    p_codigo IN VARCHAR2,
    p_regla  IN t_regla,
    p_obs    IN NUMBER,
    p_umbral IN NUMBER,
    p_desc   IN VARCHAR2) IS
  BEGIN
    p_res.EXTEND;
    p_res(p_res.LAST).id_regla        := p_regla.id_regla;
    p_res(p_res.LAST).codigo_regla    := p_codigo;
    p_res(p_res.LAST).bloqueante      := pkg_reglas.f_es_bloqueante(p_regla.id_regla);
    p_res(p_res.LAST).valor_observado := p_obs;
    p_res(p_res.LAST).valor_umbral    := p_umbral;
    p_res(p_res.LAST).descripcion     := SUBSTR(p_codigo || ': ' || p_desc, 1, 400);
  END agregar;

  -- Carga el contexto de estacion, combustible y persona
  PROCEDURE cargar_contexto_comun(
    p_id_surtidor    IN NUMBER,
    p_id_combustible IN NUMBER,
    p_id_persona     IN NUMBER) IS
  BEGIN
    g.id_surtidor    := p_id_surtidor;
    g.id_combustible := p_id_combustible;
    g.id_persona     := p_id_persona;
    BEGIN
      SELECT s.id_estacion, e.nombre, e.es_fronteriza, m.id_departamento
        INTO g.id_estacion, g.estacion, g.es_fronteriza, g.id_departamento
        FROM surtidor s
        JOIN estacion e  ON e.id_estacion  = s.id_estacion
        JOIN municipio m ON m.id_municipio = e.id_municipio
       WHERE s.id_surtidor = p_id_surtidor;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20002, 'Surtidor inexistente: ' || p_id_surtidor);
    END;
    BEGIN
      SELECT u.simbolo INTO g.unidad
        FROM combustible c
        JOIN unidad_medida u ON u.id_unidad = c.id_unidad
       WHERE c.id_combustible = p_id_combustible;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20004, 'Combustible inexistente: ' || p_id_combustible);
    END;
    g.documento := NULL;
    IF p_id_persona IS NOT NULL THEN
      BEGIN
        SELECT tipo_documento || ' ' || nro_documento INTO g.documento
          FROM persona WHERE id_persona = p_id_persona;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20006, 'Persona inexistente: ' || p_id_persona);
      END;
    END IF;
  END cargar_contexto_comun;

  PROCEDURE cargar_contexto_vehiculo(p_id_vehiculo IN NUMBER) IS
    l_cc NUMBER;
  BEGIN
    g.id_vehiculo := p_id_vehiculo;
    IF p_id_vehiculo IS NULL THEN
      g.placa := NULL; g.id_tipo_vehiculo := NULL; g.id_categoria := NULL; g.capacidad_tanque := NULL;
      RETURN;
    END IF;
    SELECT v.placa, v.id_tipo_vehiculo, f.capacidad_tanque, f.cilindrada
      INTO g.placa, g.id_tipo_vehiculo, g.capacidad_tanque, l_cc
      FROM vehiculo v
      LEFT JOIN ficha_aduana f ON f.id_ficha = v.id_ficha
     WHERE v.id_vehiculo = p_id_vehiculo;
    g.id_categoria := pkg_reglas.f_id_categoria_cilindrada(l_cc);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20003, 'Vehiculo inexistente: ' || p_id_vehiculo);
  END cargar_contexto_vehiculo;

  -- Lee una version de regla
  FUNCTION leer_regla(p_id_regla IN NUMBER) RETURN t_regla IS
    l_r t_regla;
  BEGIN
    SELECT r.id_regla, r.valor, r.valor_secundario, tp.codigo
      INTO l_r.id_regla, l_r.valor, l_r.valor_sec, l_r.periodo
      FROM regla r
      LEFT JOIN tipo_periodo tp ON tp.id_tipo_periodo = r.id_tipo_periodo
     WHERE r.id_regla = p_id_regla;
    RETURN l_r;
  END leer_regla;

  -- Regla ganadora en el contexto actual para un periodo (o sin periodo)
  FUNCTION id_regla_ctx(p_codigo IN VARCHAR2, p_periodo IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN pkg_reglas.f_id_regla_vigente(
             p_codigo, g.fecha,
             g.id_tipo_vehiculo, g.id_combustible,
             pkg_reglas.f_id_tipo_periodo(p_periodo),
             g.es_fronteriza, g.id_categoria, g.id_departamento);
  END id_regla_ctx;

  -- Regla sin periodo (tanque, ubicacion, bidon). FALSE si no hay.
  FUNCTION regla_simple(p_codigo IN VARCHAR2, p_regla OUT t_regla) RETURN BOOLEAN IS
    l_id NUMBER := id_regla_ctx(p_codigo, NULL);
  BEGIN
    IF l_id IS NULL THEN
      RETURN FALSE;
    END IF;
    p_regla := leer_regla(l_id);
    RETURN TRUE;
  END regla_simple;

  -- Reglas por periodo: una por cada periodo (DIA/SEMANA/MES) en que exista
  -- una version vigente. Una regla sin periodo se aplica como DIA.
  FUNCTION reglas_periodicas(p_codigo IN VARCHAR2) RETURN t_reglas IS
    l_res t_reglas := t_reglas();
    l_id  NUMBER;
    l_r   t_regla;
    l_dia DATE := CAST(g.fecha AS DATE);
  BEGIN
    FOR p IN (SELECT DISTINCT NVL(tp.codigo, 'DIA') AS codigo
                FROM regla r
                JOIN tipo_regla tr        ON tr.id_tipo_regla   = r.id_tipo_regla
                LEFT JOIN tipo_periodo tp ON tp.id_tipo_periodo = r.id_tipo_periodo
               WHERE tr.codigo = p_codigo
                 AND r.fecha_inicio <= l_dia
                 AND (r.fecha_fin IS NULL OR l_dia < r.fecha_fin)) LOOP
      l_id := id_regla_ctx(p_codigo, p.codigo);
      IF l_id IS NOT NULL THEN
        l_r := leer_regla(l_id);
        IF NVL(l_r.periodo, 'DIA') = p.codigo THEN
          l_r.periodo := p.codigo;
          l_res.EXTEND;
          l_res(l_res.LAST) := l_r;
        END IF;
      END IF;
    END LOOP;
    RETURN l_res;
  END reglas_periodicas;

  -- ----------------------------------------------------------
  -- Historial APROBADA del vehiculo en [p_desde, fecha de la operacion]
  -- ----------------------------------------------------------
  FUNCTION vol_vehiculo(p_desde IN TIMESTAMP) RETURN NUMBER IS
    l_n NUMBER;
  BEGIN
    SELECT NVL(SUM(t.cantidad_total), 0)
      INTO l_n
      FROM carga_vehicular cv
      JOIN transaccion t ON t.id_transaccion = cv.id_transaccion
     WHERE cv.id_vehiculo    = g.id_vehiculo
       AND t.estado          = 'APROBADA'
       AND t.id_combustible  = g.id_combustible
       AND t.fecha_hora     >= p_desde
       AND t.fecha_hora     <= g.fecha
       AND t.id_transaccion <> g.excluir;
    RETURN l_n;
  END vol_vehiculo;

  FUNCTION cargas_vehiculo(p_desde IN TIMESTAMP) RETURN NUMBER IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*)
      INTO l_n
      FROM carga_vehicular cv
      JOIN transaccion t ON t.id_transaccion = cv.id_transaccion
     WHERE cv.id_vehiculo    = g.id_vehiculo
       AND t.estado          = 'APROBADA'
       AND t.fecha_hora     >= p_desde
       AND t.fecha_hora     <= g.fecha
       AND t.id_transaccion <> g.excluir;
    RETURN l_n;
  END cargas_vehiculo;

  -- Estaciones distintas, contando la de la operacion actual
  FUNCTION estaciones_vehiculo(p_desde IN TIMESTAMP) RETURN NUMBER IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(DISTINCT s.id_estacion)
      INTO l_n
      FROM carga_vehicular cv
      JOIN transaccion t ON t.id_transaccion = cv.id_transaccion
      JOIN surtidor s    ON s.id_surtidor    = t.id_surtidor
     WHERE cv.id_vehiculo    = g.id_vehiculo
       AND t.estado          = 'APROBADA'
       AND t.fecha_hora     >= p_desde
       AND t.fecha_hora     <= g.fecha
       AND t.id_transaccion <> g.excluir
       AND s.id_estacion    <> g.id_estacion;
    RETURN l_n + 1;
  END estaciones_vehiculo;

  -- Vehiculos distintos cargados por la persona, contando el actual
  FUNCTION vehiculos_persona(p_desde IN TIMESTAMP) RETURN NUMBER IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(DISTINCT cv.id_vehiculo)
      INTO l_n
      FROM transaccion t
      JOIN carga_vehicular cv ON cv.id_transaccion = t.id_transaccion
     WHERE t.id_persona      = g.id_persona
       AND t.estado          = 'APROBADA'
       AND t.fecha_hora     >= p_desde
       AND t.fecha_hora     <= g.fecha
       AND t.id_transaccion <> g.excluir
       AND cv.id_vehiculo   <> g.id_vehiculo;
    RETURN l_n + 1;
  END vehiculos_persona;

  -- ----------------------------------------------------------
  -- Detectores de carga vehicular
  -- ----------------------------------------------------------
  PROCEDURE det_exceso_volumen(p_res IN OUT NOCOPY t_incumplimientos) IS
    l_reglas t_reglas;
    l_obs    NUMBER;
  BEGIN
    IF NOT aplica('EXCESO_VOLUMEN') THEN RETURN; END IF;
    l_reglas := reglas_periodicas('EXCESO_VOLUMEN');
    FOR i IN 1 .. l_reglas.COUNT LOOP
      l_obs := vol_vehiculo(pkg_reglas.f_inicio_periodo(g.fecha, l_reglas(i).periodo)) + g.cantidad;
      IF l_obs > l_reglas(i).valor THEN
        agregar(p_res, 'EXCESO_VOLUMEN', l_reglas(i), l_obs, l_reglas(i).valor,
                g.placa || ' acumula ' || fmt(l_obs) || ' ' || g.unidad || ' en el '
                || LOWER(l_reglas(i).periodo) || ' (umbral ' || fmt(l_reglas(i).valor) || ')');
      END IF;
    END LOOP;
  END det_exceso_volumen;

  PROCEDURE det_multiples_estaciones(p_res IN OUT NOCOPY t_incumplimientos) IS
    l_reglas t_reglas;
    l_obs    NUMBER;
  BEGIN
    IF NOT aplica('MULTIPLES_ESTACIONES') THEN RETURN; END IF;
    l_reglas := reglas_periodicas('MULTIPLES_ESTACIONES');
    FOR i IN 1 .. l_reglas.COUNT LOOP
      l_obs := estaciones_vehiculo(pkg_reglas.f_inicio_periodo(g.fecha, l_reglas(i).periodo));
      IF l_obs > l_reglas(i).valor THEN
        agregar(p_res, 'MULTIPLES_ESTACIONES', l_reglas(i), l_obs, l_reglas(i).valor,
                g.placa || ' carga en ' || fmt(l_obs) || ' estaciones en el '
                || LOWER(l_reglas(i).periodo) || ' (umbral ' || fmt(l_reglas(i).valor) || ')');
      END IF;
    END LOOP;
  END det_multiples_estaciones;

  PROCEDURE det_frecuencia(p_res IN OUT NOCOPY t_incumplimientos) IS
    l_reglas t_reglas;
    l_obs    NUMBER;
  BEGIN
    IF NOT aplica('FRECUENCIA_CARGAS') THEN RETURN; END IF;
    l_reglas := reglas_periodicas('FRECUENCIA_CARGAS');
    FOR i IN 1 .. l_reglas.COUNT LOOP
      l_obs := cargas_vehiculo(pkg_reglas.f_inicio_periodo(g.fecha, l_reglas(i).periodo)) + 1;
      IF l_obs > l_reglas(i).valor THEN
        agregar(p_res, 'FRECUENCIA_CARGAS', l_reglas(i), l_obs, l_reglas(i).valor,
                g.placa || ' realiza ' || fmt(l_obs) || ' cargas en el '
                || LOWER(l_reglas(i).periodo) || ' (umbral ' || fmt(l_reglas(i).valor) || ')');
      END IF;
    END LOOP;
  END det_frecuencia;

  -- TANQUE_EXCEDIDO y TANQUE_ACUMULADO: misma logica, distinto parametro
  PROCEDURE det_tanque(p_res IN OUT NOCOPY t_incumplimientos, p_codigo IN VARCHAR2) IS
    l_r      t_regla;
    l_obs    NUMBER;
    l_umbral NUMBER;
  BEGIN
    IF NOT aplica(p_codigo) OR g.capacidad_tanque IS NULL THEN RETURN; END IF;
    IF NOT regla_simple(p_codigo, l_r) OR l_r.valor_sec IS NULL THEN RETURN; END IF;
    l_obs    := vol_vehiculo(g.fecha - NUMTODSINTERVAL(l_r.valor_sec, 'HOUR')) + g.cantidad;
    l_umbral := g.capacidad_tanque * l_r.valor;
    IF l_obs > l_umbral THEN
      agregar(p_res, p_codigo, l_r, l_obs, l_umbral,
              g.placa || ' carga ' || fmt(l_obs) || ' ' || g.unidad || ' en ' || fmt(l_r.valor_sec)
              || ' h con tanque de ' || fmt(g.capacidad_tanque) || ' (umbral ' || fmt(l_umbral) || ')');
    END IF;
  END det_tanque;

  PROCEDURE det_ubicacion_imposible(p_res IN OUT NOCOPY t_incumplimientos) IS
    l_r        t_regla;
    l_prev_est NUMBER;
    l_prev_nom VARCHAR2(150);
    l_prev_ts  TIMESTAMP;
    l_viaje    NUMBER;
    l_min      NUMBER;
    l_umbral   NUMBER;
  BEGIN
    IF NOT aplica('UBICACION_IMPOSIBLE') THEN RETURN; END IF;
    IF NOT regla_simple('UBICACION_IMPOSIBLE', l_r) THEN RETURN; END IF;

    -- Ultima carga aprobada anterior del vehiculo
    BEGIN
      SELECT id_estacion, nombre, fecha_hora
        INTO l_prev_est, l_prev_nom, l_prev_ts
        FROM (SELECT s.id_estacion, e.nombre, t.fecha_hora
                FROM carga_vehicular cv
                JOIN transaccion t ON t.id_transaccion = cv.id_transaccion
                JOIN surtidor s    ON s.id_surtidor    = t.id_surtidor
                JOIN estacion e    ON e.id_estacion    = s.id_estacion
               WHERE cv.id_vehiculo    = g.id_vehiculo
                 AND t.estado          = 'APROBADA'
                 AND t.fecha_hora     <= g.fecha
                 AND t.id_transaccion <> g.excluir
               ORDER BY t.fecha_hora DESC, t.id_transaccion DESC)
       WHERE ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN RETURN;
    END;
    IF l_prev_est = g.id_estacion THEN RETURN; END IF;

    -- Tiempo de viaje estimado (si falta el par, se prueba el inverso)
    BEGIN
      SELECT minutos_estimados
        INTO l_viaje
        FROM (SELECT minutos_estimados, 1 AS prioridad FROM tiempo_viaje
               WHERE id_estacion_origen = l_prev_est AND id_estacion_destino = g.id_estacion
              UNION ALL
              SELECT minutos_estimados, 2 FROM tiempo_viaje
               WHERE id_estacion_origen = g.id_estacion AND id_estacion_destino = l_prev_est
               ORDER BY 2)
       WHERE ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN RETURN;
    END;

    l_min    := ROUND((CAST(g.fecha AS DATE) - CAST(l_prev_ts AS DATE)) * 1440, 1);
    l_umbral := l_viaje * l_r.valor;
    IF l_min < l_umbral THEN
      agregar(p_res, 'UBICACION_IMPOSIBLE', l_r, l_min, l_umbral,
              g.placa || ' pasa de ' || l_prev_nom || ' a ' || g.estacion || ' en ' || fmt(l_min)
              || ' min (viaje estimado ' || fmt(l_viaje) || ' min, minimo ' || fmt(l_umbral) || ')');
    END IF;
  END det_ubicacion_imposible;

  PROCEDURE det_consumo_vs_esperado(p_res IN OUT NOCOPY t_incumplimientos) IS
    l_reglas   t_reglas;
    l_esperado NUMBER;
    l_ini      TIMESTAMP;
    l_dias     NUMBER;
    l_obs      NUMBER;
    l_umbral   NUMBER;
  BEGIN
    IF NOT aplica('CONSUMO_VS_ESPERADO') THEN RETURN; END IF;
    l_esperado := pkg_reglas.f_consumo_esperado_dia(g.id_vehiculo, g.fecha);
    IF l_esperado IS NULL THEN RETURN; END IF;
    l_reglas := reglas_periodicas('CONSUMO_VS_ESPERADO');
    FOR i IN 1 .. l_reglas.COUNT LOOP
      l_ini    := pkg_reglas.f_inicio_periodo(g.fecha, l_reglas(i).periodo);
      l_dias   := CAST(pkg_reglas.f_fin_periodo(g.fecha, l_reglas(i).periodo) AS DATE) - CAST(l_ini AS DATE);
      l_obs    := vol_vehiculo(l_ini) + g.cantidad;
      l_umbral := l_esperado * l_dias * l_reglas(i).valor;
      IF l_obs > l_umbral THEN
        agregar(p_res, 'CONSUMO_VS_ESPERADO', l_reglas(i), l_obs, l_umbral,
                g.placa || ' consume ' || fmt(l_obs) || ' ' || g.unidad || ' en la '
                || LOWER(l_reglas(i).periodo) || '; esperado ' || fmt(l_esperado * l_dias)
                || ' (umbral ' || fmt(l_umbral) || ')');
      END IF;
    END LOOP;
  END det_consumo_vs_esperado;

  PROCEDURE det_concentracion(p_res IN OUT NOCOPY t_incumplimientos) IS
    l_reglas t_reglas;
    l_obs    NUMBER;
  BEGIN
    IF NOT aplica('CONCENTRACION_PROPIETARIO') OR g.id_persona IS NULL THEN RETURN; END IF;
    l_reglas := reglas_periodicas('CONCENTRACION_PROPIETARIO');
    FOR i IN 1 .. l_reglas.COUNT LOOP
      l_obs := vehiculos_persona(pkg_reglas.f_inicio_periodo(g.fecha, l_reglas(i).periodo));
      IF l_obs > l_reglas(i).valor THEN
        agregar(p_res, 'CONCENTRACION_PROPIETARIO', l_reglas(i), l_obs, l_reglas(i).valor,
                'persona ' || g.documento || ' carga ' || fmt(l_obs) || ' vehiculos distintos en la '
                || LOWER(l_reglas(i).periodo) || ' (umbral ' || fmt(l_reglas(i).valor) || ')');
      END IF;
    END LOOP;
  END det_concentracion;

  -- ----------------------------------------------------------
  -- Detectores de bidon
  -- ----------------------------------------------------------
  PROCEDURE det_bidon(p_res IN OUT NOCOPY t_incumplimientos) IS
    l_r          t_regla;
    l_usado      NUMBER;
    l_autorizado NUMBER;
    l_resolucion VARCHAR2(30);
  BEGIN
    IF g.id_permiso IS NULL THEN
      IF aplica('BIDON_SIN_PERMISO') AND regla_simple('BIDON_SIN_PERMISO', l_r) THEN
        agregar(p_res, 'BIDON_SIN_PERMISO', l_r, g.cantidad, 0,
                'persona ' || g.documento || ' compra ' || fmt(g.cantidad) || ' ' || g.unidad
                || ' en bidon sin permiso ANH vigente en ' || g.estacion);
      END IF;
      RETURN;
    END IF;

    IF aplica('BIDON_EXCEDE_PERMISO') AND regla_simple('BIDON_EXCEDE_PERMISO', l_r) THEN
      SELECT cantidad_autorizada, nro_resolucion_anh INTO l_autorizado, l_resolucion
        FROM permiso_bidon WHERE id_permiso = g.id_permiso;
      l_usado := f_consumo_permiso(g.id_permiso, g.fecha, g.excluir) + g.cantidad;
      IF l_usado > l_autorizado THEN
        agregar(p_res, 'BIDON_EXCEDE_PERMISO', l_r, l_usado, l_autorizado,
                'persona ' || g.documento || ' acumula ' || fmt(l_usado) || ' ' || g.unidad
                || ' con el permiso ' || l_resolucion || ' (autorizado ' || fmt(l_autorizado) || ')');
      END IF;
    END IF;
  END det_bidon;

  -- ----------------------------------------------------------
  -- Evaluadores internos (con exclusion y filtro de codigos)
  -- ----------------------------------------------------------
  PROCEDURE evaluar_carga_int(
    p_id_vehiculo    IN  NUMBER,
    p_id_persona     IN  NUMBER,
    p_id_surtidor    IN  NUMBER,
    p_id_combustible IN  NUMBER,
    p_cantidad       IN  NUMBER,
    p_fecha_hora     IN  TIMESTAMP,
    p_excluir        IN  NUMBER,
    p_codigos        IN  VARCHAR2,
    p_resultado      OUT t_incumplimientos) IS
  BEGIN
    g := g_vacio;
    g.fecha      := p_fecha_hora;
    g.excluir    := NVL(p_excluir, -1);
    g.codigos    := p_codigos;
    g.cantidad   := p_cantidad;
    g.id_permiso := NULL;
    cargar_contexto_comun(p_id_surtidor, p_id_combustible, p_id_persona);
    cargar_contexto_vehiculo(p_id_vehiculo);

    p_resultado := t_incumplimientos();
    det_exceso_volumen(p_resultado);
    det_multiples_estaciones(p_resultado);
    det_frecuencia(p_resultado);
    det_tanque(p_resultado, 'TANQUE_EXCEDIDO');
    det_tanque(p_resultado, 'TANQUE_ACUMULADO');
    det_ubicacion_imposible(p_resultado);
    det_consumo_vs_esperado(p_resultado);
    det_concentracion(p_resultado);
  END evaluar_carga_int;

  PROCEDURE evaluar_bidon_int(
    p_id_persona     IN  NUMBER,
    p_id_surtidor    IN  NUMBER,
    p_id_combustible IN  NUMBER,
    p_cantidad       IN  NUMBER,
    p_fecha_hora     IN  TIMESTAMP,
    p_id_permiso     IN  NUMBER,
    p_excluir        IN  NUMBER,
    p_codigos        IN  VARCHAR2,
    p_resultado      OUT t_incumplimientos) IS
  BEGIN
    g := g_vacio;
    g.fecha      := p_fecha_hora;
    g.excluir    := NVL(p_excluir, -1);
    g.codigos    := p_codigos;
    g.cantidad   := p_cantidad;
    g.id_permiso := p_id_permiso;
    cargar_contexto_comun(p_id_surtidor, p_id_combustible, p_id_persona);
    cargar_contexto_vehiculo(NULL);

    p_resultado := t_incumplimientos();
    det_bidon(p_resultado);
  END evaluar_bidon_int;

  FUNCTION insertar_alertas(
    p_id_transaccion  IN NUMBER,
    p_resultado       IN t_incumplimientos,
    p_fecha_deteccion IN TIMESTAMP) RETURN NUMBER IS
    l_fecha  TIMESTAMP := p_fecha_deteccion;
    l_nuevas NUMBER := 0;
  BEGIN
    IF p_resultado IS NULL OR p_resultado.COUNT = 0 THEN
      RETURN 0;
    END IF;
    IF l_fecha IS NULL THEN
      SELECT fecha_hora INTO l_fecha FROM transaccion WHERE id_transaccion = p_id_transaccion;
    END IF;
    FOR i IN 1 .. p_resultado.COUNT LOOP
      BEGIN
        INSERT INTO alerta (id_regla, id_transaccion, fecha_deteccion,
                            valor_observado, valor_umbral, descripcion)
          VALUES (p_resultado(i).id_regla, p_id_transaccion, l_fecha,
                  p_resultado(i).valor_observado, p_resultado(i).valor_umbral,
                  p_resultado(i).descripcion);
        l_nuevas := l_nuevas + 1;
      EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
          NULL;  -- ya existia la alerta (regla, transaccion)
      END;
    END LOOP;
    RETURN l_nuevas;
  END insertar_alertas;

  -- ----------------------------------------------------------
  -- Publicos
  -- ----------------------------------------------------------
  FUNCTION f_id_regla_operacion(
    p_codigo_regla    IN VARCHAR2,
    p_fecha           IN TIMESTAMP,
    p_id_surtidor     IN NUMBER,
    p_id_combustible  IN NUMBER,
    p_id_vehiculo     IN NUMBER   DEFAULT NULL,
    p_codigo_periodo  IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
  BEGIN
    g := g_vacio;
    g.fecha := p_fecha;
    cargar_contexto_comun(p_id_surtidor, p_id_combustible, NULL);
    cargar_contexto_vehiculo(p_id_vehiculo);
    RETURN id_regla_ctx(p_codigo_regla, p_codigo_periodo);
  END f_id_regla_operacion;

  FUNCTION f_consumo_permiso(
    p_id_permiso  IN NUMBER,
    p_fecha       IN TIMESTAMP,
    p_id_excluir  IN NUMBER DEFAULT NULL) RETURN NUMBER IS
    l_periodo VARCHAR2(10);
    l_n       NUMBER;
  BEGIN
    SELECT tp.codigo INTO l_periodo
      FROM permiso_bidon pb
      JOIN tipo_periodo tp ON tp.id_tipo_periodo = pb.id_tipo_periodo
     WHERE pb.id_permiso = p_id_permiso;
    SELECT NVL(SUM(t.cantidad_total), 0)
      INTO l_n
      FROM compra_bidon cb
      JOIN transaccion t ON t.id_transaccion = cb.id_transaccion
     WHERE cb.id_permiso     = p_id_permiso
       AND t.estado          = 'APROBADA'
       AND t.fecha_hora     >= pkg_reglas.f_inicio_periodo(p_fecha, l_periodo)
       AND t.fecha_hora     <= p_fecha
       AND t.id_transaccion <> NVL(p_id_excluir, -1);
    RETURN l_n;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END f_consumo_permiso;

  PROCEDURE p_evaluar_carga(
    p_id_vehiculo    IN  NUMBER,
    p_id_persona     IN  NUMBER,
    p_id_surtidor    IN  NUMBER,
    p_id_combustible IN  NUMBER,
    p_cantidad       IN  NUMBER,
    p_fecha_hora     IN  TIMESTAMP,
    p_resultado      OUT t_incumplimientos) IS
  BEGIN
    evaluar_carga_int(p_id_vehiculo, p_id_persona, p_id_surtidor, p_id_combustible,
                      p_cantidad, p_fecha_hora, NULL, NULL, p_resultado);
  END p_evaluar_carga;

  PROCEDURE p_evaluar_bidon(
    p_id_persona     IN  NUMBER,
    p_id_surtidor    IN  NUMBER,
    p_id_combustible IN  NUMBER,
    p_cantidad       IN  NUMBER,
    p_fecha_hora     IN  TIMESTAMP,
    p_id_permiso     IN  NUMBER,
    p_resultado      OUT t_incumplimientos) IS
  BEGIN
    evaluar_bidon_int(p_id_persona, p_id_surtidor, p_id_combustible, p_cantidad,
                      p_fecha_hora, p_id_permiso, NULL, NULL, p_resultado);
  END p_evaluar_bidon;

  FUNCTION f_hay_bloqueante(p_resultado IN t_incumplimientos) RETURN BOOLEAN IS
  BEGIN
    IF p_resultado IS NULL THEN
      RETURN FALSE;
    END IF;
    FOR i IN 1 .. p_resultado.COUNT LOOP
      IF p_resultado(i).bloqueante = 'S' THEN
        RETURN TRUE;
      END IF;
    END LOOP;
    RETURN FALSE;
  END f_hay_bloqueante;

  FUNCTION f_codigos(p_resultado IN t_incumplimientos) RETURN VARCHAR2 IS
    l_txt VARCHAR2(4000);
  BEGIN
    IF p_resultado IS NULL THEN
      RETURN NULL;
    END IF;
    FOR i IN 1 .. p_resultado.COUNT LOOP
      l_txt := l_txt || CASE WHEN i > 1 THEN ',' END || p_resultado(i).codigo_regla;
    END LOOP;
    RETURN l_txt;
  END f_codigos;

  PROCEDURE p_registrar_alertas(
    p_id_transaccion  IN NUMBER,
    p_resultado       IN t_incumplimientos,
    p_fecha_deteccion IN TIMESTAMP DEFAULT NULL) IS
    l_n NUMBER;
  BEGIN
    l_n := insertar_alertas(p_id_transaccion, p_resultado, p_fecha_deteccion);
  END p_registrar_alertas;

  PROCEDURE p_reevaluar_transaccion(
    p_id_transaccion IN  NUMBER,
    p_codigos        IN  VARCHAR2 DEFAULT NULL,
    p_nuevas         OUT NUMBER) IS
    l_tipo     transaccion.tipo_transaccion%TYPE;
    l_surtidor NUMBER;
    l_comb     NUMBER;
    l_persona  NUMBER;
    l_fecha    TIMESTAMP;
    l_cantidad NUMBER;
    l_vehiculo NUMBER;
    l_permiso  NUMBER;
    l_res      t_incumplimientos;
  BEGIN
    SELECT t.tipo_transaccion, t.id_surtidor, t.id_combustible, t.id_persona,
           t.fecha_hora, t.cantidad_total, cv.id_vehiculo, cb.id_permiso
      INTO l_tipo, l_surtidor, l_comb, l_persona, l_fecha, l_cantidad, l_vehiculo, l_permiso
      FROM transaccion t
      LEFT JOIN carga_vehicular cv ON cv.id_transaccion = t.id_transaccion
      LEFT JOIN compra_bidon cb    ON cb.id_transaccion = t.id_transaccion
     WHERE t.id_transaccion = p_id_transaccion;

    IF l_tipo = 'VEHICULAR' THEN
      evaluar_carga_int(l_vehiculo, l_persona, l_surtidor, l_comb, l_cantidad, l_fecha,
                        p_id_transaccion, p_codigos, l_res);
    ELSE
      evaluar_bidon_int(l_persona, l_surtidor, l_comb, l_cantidad, l_fecha, l_permiso,
                        p_id_transaccion, p_codigos, l_res);
    END IF;
    p_nuevas := insertar_alertas(p_id_transaccion, l_res, SYSTIMESTAMP);
  END p_reevaluar_transaccion;

  PROCEDURE p_conciliar_estacion(
    p_id_estacion IN  NUMBER,
    p_desde       IN  DATE,
    p_hasta       IN  DATE,
    p_nuevas      OUT NUMBER) IS
    l_es_front CHAR(1);
    l_depto    NUMBER;
    l_id_regla NUMBER;
    l_tol      NUMBER;
    l_umbral   NUMBER;
    l_desc     VARCHAR2(400);
  BEGIN
    p_nuevas := 0;
    SELECT e.es_fronteriza, m.id_departamento
      INTO l_es_front, l_depto
      FROM estacion e JOIN municipio m ON m.id_municipio = e.id_municipio
     WHERE e.id_estacion = p_id_estacion;

    FOR c IN (SELECT id_combustible, combustible, estacion, semana,
                     recibido, vendido, saldo_inicio, disponible
                FROM v_conciliacion_estacion
               WHERE id_estacion = p_id_estacion
                 AND semana     >= TRUNC(p_desde, 'IW')
                 AND semana + 7 <= p_hasta          -- solo semanas completas
               ORDER BY id_combustible, semana) LOOP
      l_id_regla := pkg_reglas.f_id_regla_vigente(
                      'DESBALANCE_YPFB', CAST(c.semana AS TIMESTAMP),
                      p_id_combustible  => c.id_combustible,
                      p_id_tipo_periodo => pkg_reglas.f_id_tipo_periodo('SEMANA'),
                      p_es_fronteriza   => l_es_front,
                      p_id_departamento => l_depto);
      IF l_id_regla IS NOT NULL THEN
        SELECT valor INTO l_tol FROM regla WHERE id_regla = l_id_regla;
        l_umbral := GREATEST(c.disponible, 0) * (1 + l_tol / 100);
        IF c.vendido > l_umbral THEN
          -- el texto se arma en PL/SQL: fmt es privada y no se puede usar en SQL
          l_desc := SUBSTR('DESBALANCE_YPFB: ' || c.estacion || ' ' || c.combustible
                           || ' semana ' || TO_CHAR(c.semana, 'YYYY-MM-DD')
                           || ' vende ' || fmt(c.vendido) || ' con ' || fmt(c.disponible)
                           || ' disponible (saldo ' || fmt(c.saldo_inicio) || ' + recibido '
                           || fmt(c.recibido) || '; umbral ' || fmt(l_umbral) || ')', 1, 400);
          BEGIN
            INSERT INTO alerta (id_regla, id_estacion, periodo_inicio, fecha_deteccion,
                                valor_observado, valor_umbral, descripcion)
              VALUES (l_id_regla, p_id_estacion, c.semana, CAST(c.semana + 7 AS TIMESTAMP),
                      c.vendido, l_umbral, l_desc);
            p_nuevas := p_nuevas + 1;
          EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
              NULL;  -- ya conciliada
          END;
        END IF;
      END IF;
    END LOOP;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20002, 'Estacion inexistente: ' || p_id_estacion);
  END p_conciliar_estacion;

  PROCEDURE p_conciliar_todas(
    p_desde  IN  DATE,
    p_hasta  IN  DATE,
    p_nuevas OUT NUMBER) IS
    l_n NUMBER;
  BEGIN
    p_nuevas := 0;
    FOR e IN (SELECT DISTINCT id_estacion FROM tanque_estacion ORDER BY id_estacion) LOOP
      p_conciliar_estacion(e.id_estacion, p_desde, p_hasta, l_n);
      p_nuevas := p_nuevas + l_n;
    END LOOP;
  END p_conciliar_todas;

  PROCEDURE p_revisar_alerta(
    p_id_alerta      IN NUMBER,
    p_resultado      IN VARCHAR2,
    p_id_usuario     IN NUMBER,
    p_observacion    IN VARCHAR2  DEFAULT NULL,
    p_fecha_revision IN TIMESTAMP DEFAULT NULL) IS
    l_estado alerta.estado_revision%TYPE;
    l_n      NUMBER;
  BEGIN
    IF p_resultado IS NULL OR p_resultado NOT IN ('CONFIRMADA', 'FALSO_POSITIVO') THEN
      RAISE_APPLICATION_ERROR(-20008, 'Resultado de revision invalido: ' || NVL(p_resultado, 'NULL'));
    END IF;

    SELECT COUNT(*) INTO l_n
      FROM usuario_app
     WHERE id_usuario = p_id_usuario
       AND estado     = 'ACTIVO'
       AND rol IN ('ADMIN', 'FISCALIZADOR');
    IF l_n = 0 THEN
      RAISE_APPLICATION_ERROR(-20008, 'El usuario ' || p_id_usuario
                                      || ' no puede revisar alertas (debe ser ADMIN o FISCALIZADOR activo)');
    END IF;

    BEGIN
      SELECT estado_revision INTO l_estado
        FROM alerta WHERE id_alerta = p_id_alerta
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20008, 'Alerta inexistente: ' || p_id_alerta);
    END;
    IF l_estado <> 'PENDIENTE' THEN
      RAISE_APPLICATION_ERROR(-20008, 'La alerta ' || p_id_alerta || ' ya fue revisada');
    END IF;

    UPDATE alerta
       SET estado_revision      = 'REVISADA',
           resultado_revision   = p_resultado,
           id_usuario_revision  = p_id_usuario,
           fecha_revision       = NVL(p_fecha_revision, SYSTIMESTAMP),
           observacion_revision = SUBSTR(p_observacion, 1, 400)
     WHERE id_alerta = p_id_alerta;
  END p_revisar_alerta;

END pkg_deteccion;
/
SHOW ERRORS

-- ------------------------------------------------------------
-- Verificacion: compila y detecta lo que dice el plan.
-- Crea un escenario minimo dentro de un SAVEPOINT y lo deshace.
-- Fechas fijas: semana del lunes 2026-11-16 (cuota AUTO = 40).
-- ------------------------------------------------------------
DECLARE
  l_schema VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  l_n      NUMBER;
  l_gas    NUMBER; l_auto NUMBER; l_moto NUMBER;
  l_est_a  NUMBER; l_est_b NUMBER; l_est_c NUMBER;
  l_sur_a  NUMBER; l_sur_b NUMBER; l_sur_c NUMBER;
  l_p1     NUMBER; l_p2 NUMBER;
  l_v1     NUMBER; l_v2 NUMBER; l_v3 NUMBER; l_v4 NUMBER; l_v5 NUMBER;
  l_fiscal NUMBER;
  l_tx     NUMBER;
  l_alerta NUMBER;
  l_res    pkg_deteccion.t_incumplimientos;
  l_ts     TIMESTAMP;
  c_lunes  CONSTANT TIMESTAMP := TIMESTAMP '2026-11-16 00:00:00';

  PROCEDURE chequear(p_nombre IN VARCHAR2, p_ok IN BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      DBMS_OUTPUT.PUT_LINE('OK    ' || p_nombre);
    ELSE
      RAISE_APPLICATION_ERROR(-20999, '06_pkg_deteccion: FALLO ' || p_nombre);
    END IF;
  END chequear;

  FUNCTION h(p_horas IN NUMBER) RETURN TIMESTAMP IS
  BEGIN
    RETURN c_lunes + NUMTODSINTERVAL(p_horas, 'HOUR');
  END h;

  FUNCTION id_muni(p_nombre IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT id_municipio INTO l_id FROM municipio WHERE nombre = p_nombre;
    RETURN l_id;
  END id_muni;

  FUNCTION nueva_estacion(p_muni IN VARCHAR2, p_nombre IN VARCHAR2, p_front IN CHAR,
                          p_surtidor OUT NUMBER) RETURN NUMBER IS
    l_id NUMBER;
    l_mu NUMBER := id_muni(p_muni);
  BEGIN
    INSERT INTO estacion (id_municipio, nombre, nit, zona, latitud, longitud, es_fronteriza)
      VALUES (l_mu, p_nombre, 'NIT-' || p_nombre, 'Prueba', -17, -66, p_front)
      RETURNING id_estacion INTO l_id;
    INSERT INTO surtidor (id_estacion, codigo) VALUES (l_id, 'S1')
      RETURNING id_surtidor INTO p_surtidor;
    RETURN l_id;
  END nueva_estacion;

  FUNCTION nueva_persona(p_doc IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    INSERT INTO persona (tipo_documento, nro_documento, nombres, apellido_paterno, nacionalidad, fecha_registro)
      VALUES ('CI', p_doc, 'Prueba', p_doc, 'BOLIVIANA', DATE '2026-01-01')
      RETURNING id_persona INTO l_id;
    RETURN l_id;
  END nueva_persona;

  FUNCTION nuevo_vehiculo(p_placa IN VARCHAR2, p_tipo IN NUMBER, p_cc IN NUMBER, p_tanque IN NUMBER)
    RETURN NUMBER IS
    l_ficha NUMBER;
    l_id    NUMBER;
  BEGIN
    IF p_cc IS NULL THEN  -- extranjero
      INSERT INTO vehiculo (id_tipo_vehiculo, placa, pais_placa, fecha_registro)
        VALUES (p_tipo, p_placa, 'PER', DATE '2026-01-01') RETURNING id_vehiculo INTO l_id;
    ELSE
      INSERT INTO ficha_aduana (nro_chasis, id_combustible, marca, modelo, anio_fabricacion, cilindrada, capacidad_tanque)
        VALUES ('CH-' || p_placa, l_gas, 'Marca', 'Modelo', 2018, p_cc, p_tanque) RETURNING id_ficha INTO l_ficha;
      INSERT INTO vehiculo (id_tipo_vehiculo, id_ficha, placa, codigo_rfid, fecha_registro)
        VALUES (p_tipo, l_ficha, p_placa, 'RFID-' || p_placa, DATE '2026-01-01') RETURNING id_vehiculo INTO l_id;
    END IF;
    RETURN l_id;
  END nuevo_vehiculo;

  -- Carga aprobada directa (historial), sin pasar por pkg_transacciones
  FUNCTION carga(p_veh IN NUMBER, p_sur IN NUMBER, p_per IN NUMBER, p_cant IN NUMBER, p_ts IN TIMESTAMP)
    RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    INSERT INTO transaccion (id_surtidor, id_combustible, id_persona, fecha_hora, cantidad_total,
                             tipo_transaccion, huella_verificada)
      VALUES (p_sur, l_gas, p_per, p_ts, p_cant, 'VEHICULAR', 'S')
      RETURNING id_transaccion INTO l_id;
    INSERT INTO carga_vehicular (id_transaccion, id_vehiculo, rfid_leido) VALUES (l_id, p_veh, 'S');
    RETURN l_id;
  END carga;

  FUNCTION tiene(p_res IN pkg_deteccion.t_incumplimientos, p_codigo IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN INSTR(',' || pkg_deteccion.f_codigos(p_res) || ',', ',' || p_codigo || ',') > 0;
  END tiene;
BEGIN
  SELECT COUNT(*) INTO l_n FROM all_objects
   WHERE owner = l_schema AND object_name = 'PKG_DETECCION' AND status = 'VALID';
  chequear('pkg_deteccion (especificacion y cuerpo) VALID', l_n = 2);

  SAVEPOINT sp_06;
  SELECT id_combustible   INTO l_gas  FROM combustible   WHERE nombre = 'Gasolina Especial';
  SELECT id_tipo_vehiculo INTO l_auto FROM tipo_vehiculo WHERE nombre = 'AUTO';
  SELECT id_tipo_vehiculo INTO l_moto FROM tipo_vehiculo WHERE nombre = 'MOTO';

  -- Escenario: A (Cochabamba), B (Quillacollo), C (Desaguadero, fronteriza)
  l_est_a := nueva_estacion('Cochabamba',  'TST-A', 'N', l_sur_a);
  l_est_b := nueva_estacion('Quillacollo', 'TST-B', 'N', l_sur_b);
  l_est_c := nueva_estacion('Desaguadero', 'TST-C', 'S', l_sur_c);
  INSERT INTO tiempo_viaje VALUES (l_est_a, l_est_b, 30,  DATE '2026-01-01');
  INSERT INTO tiempo_viaje VALUES (l_est_a, l_est_c, 420, DATE '2026-01-01');
  INSERT INTO tanque_estacion VALUES (l_est_a, l_gas, 20000, 1000, DATE '2026-11-02');
  l_p1 := nueva_persona('TST-P1');
  l_p2 := nueva_persona('TST-P2');
  l_v1 := nuevo_vehiculo('TST-001', l_auto, 1600, 50);   -- esperado 8/dia
  l_v2 := nuevo_vehiculo('TST-002', l_auto, 1000, 40);
  l_v3 := nuevo_vehiculo('TST-003', l_auto, NULL, NULL);  -- extranjero
  l_v4 := nuevo_vehiculo('TST-004', l_moto, 150, 12);
  l_v5 := nuevo_vehiculo('TST-005', l_auto, 1800, 55);
  INSERT INTO usuario_app (username, password_hash, sal, rol)
    VALUES ('tst_fiscal', 'x', 'x', 'FISCALIZADOR') RETURNING id_usuario INTO l_fiscal;
  SAVEPOINT sp_06_base;

  -- 1. Carga normal sin historial: sin incumplimientos
  pkg_deteccion.p_evaluar_carga(l_v1, l_p1, l_sur_a, l_gas, 30, h(8), l_res);
  chequear('carga normal -> 0 incumplimientos', l_res.COUNT = 0);

  -- 2. 60 L con tanque de 50 (umbral 55): TANQUE_EXCEDIDO, bloquea
  pkg_deteccion.p_evaluar_carga(l_v1, l_p1, l_sur_a, l_gas, 60, h(8), l_res);
  chequear('60 L en tanque 50 -> TANQUE_EXCEDIDO', tiene(l_res, 'TANQUE_EXCEDIDO'));
  chequear('TANQUE_EXCEDIDO bloquea', pkg_deteccion.f_hay_bloqueante(l_res));

  -- 3. 45 L + 45 L el mismo dia: EXCESO_VOLUMEN (90 > 80) y CONSUMO_VS_ESPERADO (90 > 8*7*1.5 = 84), no bloquean
  l_tx := carga(l_v1, l_sur_a, l_p1, 45, h(8));
  pkg_deteccion.p_evaluar_carga(l_v1, l_p1, l_sur_a, l_gas, 45, h(14), l_res);
  chequear('45+45 L -> EXCESO_VOLUMEN',      tiene(l_res, 'EXCESO_VOLUMEN'));
  chequear('45+45 L -> CONSUMO_VS_ESPERADO', tiene(l_res, 'CONSUMO_VS_ESPERADO'));
  chequear('45+45 L -> no bloquea',          NOT pkg_deteccion.f_hay_bloqueante(l_res));

  -- 4. Registrar alertas dos veces no duplica (D-5 + indice unico)
  l_tx := carga(l_v1, l_sur_a, l_p1, 45, h(14));
  pkg_deteccion.p_registrar_alertas(l_tx, l_res);
  pkg_deteccion.p_registrar_alertas(l_tx, l_res);
  SELECT COUNT(*) INTO l_n FROM alerta WHERE id_transaccion = l_tx;
  chequear('alertas registradas sin duplicar = 2', l_n = 2);
  l_ts := h(14);
  SELECT COUNT(*) INTO l_n FROM alerta
   WHERE id_transaccion = l_tx AND fecha_deteccion = l_ts AND valor_observado = 90;
  chequear('alerta con fecha de la carga y valor observado', l_n >= 1);
  ROLLBACK TO sp_06_base;

  -- 5. A las 08:00 en A y a las 09:00 en C (viaje 420 min, minimo 336): UBICACION_IMPOSIBLE
  l_tx := carga(l_v1, l_sur_a, l_p1, 20, h(8));
  pkg_deteccion.p_evaluar_carga(l_v1, l_p1, l_sur_c, l_gas, 10, h(9), l_res);
  chequear('A 08:00 -> C 09:00 -> UBICACION_IMPOSIBLE', tiene(l_res, 'UBICACION_IMPOSIBLE'));
  chequear('UBICACION_IMPOSIBLE bloquea', pkg_deteccion.f_hay_bloqueante(l_res));
  -- 6. A 08:00 -> B 12:00 (viaje 30 min): sin ubicacion imposible
  pkg_deteccion.p_evaluar_carga(l_v1, l_p1, l_sur_b, l_gas, 10, h(12), l_res);
  chequear('A 08:00 -> B 12:00 -> sin UBICACION_IMPOSIBLE', NOT tiene(l_res, 'UBICACION_IMPOSIBLE'));
  -- 7. Tercera estacion en el dia: MULTIPLES_ESTACIONES (3 > 2)
  l_tx := carga(l_v1, l_sur_b, l_p1, 10, h(12));
  pkg_deteccion.p_evaluar_carga(l_v1, l_p1, l_sur_c, l_gas, 10, h(20), l_res);
  chequear('tres estaciones en el dia -> MULTIPLES_ESTACIONES', tiene(l_res, 'MULTIPLES_ESTACIONES'));
  ROLLBACK TO sp_06_base;

  -- 8. Moto con 3 cargas previas: la cuarta -> FRECUENCIA_CARGAS (4 > 3)
  l_tx := carga(l_v4, l_sur_a, l_p2, 3, h(7));
  l_tx := carga(l_v4, l_sur_a, l_p2, 3, h(10));
  l_tx := carga(l_v4, l_sur_a, l_p2, 3, h(13));
  pkg_deteccion.p_evaluar_carga(l_v4, l_p2, l_sur_a, l_gas, 3, h(16), l_res);
  chequear('cuarta carga del dia -> FRECUENCIA_CARGAS', tiene(l_res, 'FRECUENCIA_CARGAS'));
  ROLLBACK TO sp_06_base;

  -- 9. Cuatro cargas de 30 L en 24 h (tanque 50, umbral 100): TANQUE_ACUMULADO en la cuarta
  l_tx := carga(l_v1, l_sur_a, l_p1, 30, h(0));
  l_tx := carga(l_v1, l_sur_a, l_p1, 30, h(5));
  l_tx := carga(l_v1, l_sur_a, l_p1, 30, h(10));
  pkg_deteccion.p_evaluar_carga(l_v1, l_p1, l_sur_a, l_gas, 30, h(15), l_res);
  chequear('120 L en 24 h con tanque 50 -> TANQUE_ACUMULADO', tiene(l_res, 'TANQUE_ACUMULADO'));
  chequear('TANQUE_ACUMULADO bloquea', pkg_deteccion.f_hay_bloqueante(l_res));
  ROLLBACK TO sp_06_base;

  -- 10. Auto de 1.000 cc: 30 + 30 L en el dia (umbral por cilindrada 50) -> EXCESO_VOLUMEN
  l_tx := carga(l_v2, l_sur_a, l_p1, 30, h(8));
  pkg_deteccion.p_evaluar_carga(l_v2, l_p1, l_sur_a, l_gas, 30, h(18), l_res);
  chequear('1.000 cc con 60 L -> EXCESO_VOLUMEN (umbral 50)', tiene(l_res, 'EXCESO_VOLUMEN'));
  ROLLBACK TO sp_06_base;

  -- 11. Auto en estacion fronteriza: 65 L (umbral fronterizo 60, ALTA) -> bloquea
  pkg_deteccion.p_evaluar_carga(l_v5, l_p1, l_sur_c, l_gas, 50, h(8), l_res);
  chequear('50 L en frontera -> sin EXCESO_VOLUMEN', NOT tiene(l_res, 'EXCESO_VOLUMEN'));
  l_tx := carga(l_v5, l_sur_c, l_p1, 50, h(8));
  pkg_deteccion.p_evaluar_carga(l_v5, l_p1, l_sur_c, l_gas, 15, h(20), l_res);
  chequear('65 L en frontera -> EXCESO_VOLUMEN que bloquea',
           tiene(l_res, 'EXCESO_VOLUMEN') AND pkg_deteccion.f_hay_bloqueante(l_res));
  ROLLBACK TO sp_06_base;

  -- 12. Una persona carga 4 vehiculos distintos en la semana -> CONCENTRACION_PROPIETARIO (4 > 3)
  l_tx := carga(l_v1, l_sur_a, l_p2, 10, h(8));
  l_tx := carga(l_v2, l_sur_a, l_p2, 10, h(32));
  l_tx := carga(l_v3, l_sur_a, l_p2, 10, h(56));
  pkg_deteccion.p_evaluar_carga(l_v4, l_p2, l_sur_a, l_gas, 3, h(80), l_res);
  chequear('cuatro vehiculos en la semana -> CONCENTRACION_PROPIETARIO', tiene(l_res, 'CONCENTRACION_PROPIETARIO'));
  ROLLBACK TO sp_06_base;

  -- 13. Bidon sin permiso -> BIDON_SIN_PERMISO (ALTA, bloquea)
  pkg_deteccion.p_evaluar_bidon(l_p1, l_sur_a, l_gas, 20, h(8), NULL, l_res);
  chequear('bidon sin permiso -> BIDON_SIN_PERMISO que bloquea',
           tiene(l_res, 'BIDON_SIN_PERMISO') AND pkg_deteccion.f_hay_bloqueante(l_res));

  -- 14. Conciliacion: semana 2026-11-02, saldo 1000 + recibido 500, vendido 1700 (> 1575)
  INSERT INTO recepcion_combustible (id_estacion, id_combustible, nro_guia_ypfb, nro_lote, cantidad, fecha_hora)
    VALUES (l_est_a, l_gas, 'GUIA-TST-1', 'LOTE-TST-1', 500, TIMESTAMP '2026-11-03 09:00:00');
  l_tx := carga(l_v1, l_sur_a, l_p1, 1700, TIMESTAMP '2026-11-04 10:00:00');
  pkg_deteccion.p_conciliar_estacion(l_est_a, DATE '2026-11-02', DATE '2026-11-16', l_n);
  chequear('conciliacion -> 1 alerta DESBALANCE_YPFB', l_n = 1);
  pkg_deteccion.p_conciliar_estacion(l_est_a, DATE '2026-11-02', DATE '2026-11-16', l_n);
  chequear('conciliacion repetida -> 0 alertas nuevas', l_n = 0);

  -- 15. Revision de alertas
  SELECT MAX(id_alerta) INTO l_alerta FROM alerta WHERE id_estacion = l_est_a;
  pkg_deteccion.p_revisar_alerta(l_alerta, 'CONFIRMADA', l_fiscal, 'Prueba');
  SELECT COUNT(*) INTO l_n FROM alerta
   WHERE id_alerta = l_alerta AND estado_revision = 'REVISADA' AND id_usuario_revision = l_fiscal;
  chequear('alerta revisada con usuario', l_n = 1);
  BEGIN
    pkg_deteccion.p_revisar_alerta(l_alerta, 'FALSO_POSITIVO', l_fiscal);
    chequear('rechaza segunda revision', FALSE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20008 THEN
        DBMS_OUTPUT.PUT_LINE('OK    rechaza segunda revision (-20008)');
      ELSE
        RAISE;
      END IF;
  END;

  ROLLBACK TO sp_06;
  SELECT COUNT(*) INTO l_n FROM estacion WHERE nombre LIKE 'TST-%';
  chequear('no quedaron datos de prueba', l_n = 0);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/
