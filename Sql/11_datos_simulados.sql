-- ============================================================
-- 11_datos_simulados.sql
-- Poblacion de datos sinteticos coherentes (enunciado, seccion 3.4).
-- Todo es ficticio. Determinista: semilla fija (DBMS_RANDOM.SEED).
-- Ventana: 182 dias que terminan el dia de la carga (TRUNC(SYSDATE)),
-- para que las consultas de "ultimos N dias" devuelvan filas.
-- Las operaciones se generan en orden cronologico y TODAS pasan por
-- pkg_transacciones (precios, bloqueos y alertas coherentes), con los
-- triggers activos.
-- Volumen minimo exigido -> generado:
--   usuarios (personas) 1.000 -> 1.200 + escenarios
--   vehiculos           1.500 -> 1.600 + escenarios
--   estaciones             20 -> 25 (14 en Cochabamba, 6 ciudades, 5 fronterizas)
--   operaciones        50.000 -> mas de 55.000 (se verifica al final)
--   historial          6 meses -> 182 dias
-- Perfiles: normal, taxi (uso intensivo legitimo), acopiador, contrabando
-- en frontera, placa clonada, tanque excedido, cilindrada baja con
-- consumo alto, extranjero, extranjero en frontera, persona que carga
-- muchos vehiculos, bidon con y sin permiso, estaciones con desbalance
-- YPFB y un lote adulterado con reclamos.
-- NO es re-ejecutable (inserta datos). Para repetir: down -v y up -d.
-- Tarda varios minutos.
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = combustible;
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF

-- ============================================================
-- A. MAESTROS Y 182 DIAS DE OPERACIONES
-- ============================================================
DECLARE
  c_fin    CONSTANT DATE := TRUNC(SYSDATE);
  c_inicio CONSTANT DATE := TRUNC(SYSDATE) - 182;
  c_alta   CONSTANT DATE := GREATEST(TRUNC(SYSDATE) - 212, DATE '2026-01-01');

  TYPE t_n IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;
  TYPE t_v IS TABLE OF VARCHAR2(100) INDEX BY PLS_INTEGER;
  TYPE t_d IS TABLE OF DATE          INDEX BY PLS_INTEGER;

  -- Evento del dia (se ejecutan en orden de hora: la clave es HHMMSS + secuencia)
  TYPE t_ev IS RECORD (
    tipo    CHAR(1),        -- C = carga vehicular, B = bidon
    veh     PLS_INTEGER,
    persona NUMBER,
    k       PLS_INTEGER,    -- estacion
    f       PLS_INTEGER,    -- combustible (1 gas, 2 diesel, 3 GNV, 4 premium)
    cant    NUMBER,
    ts      DATE,
    huella  CHAR(1),
    rfid    CHAR(1),
    recip   NUMBER);
  TYPE t_evs IS TABLE OF t_ev INDEX BY VARCHAR2(20);
  ev    t_evs;
  l_seq PLS_INTEGER := 0;

  -- Catalogos
  comb   t_n;                -- id_combustible por codigo 1..4
  l_moto NUMBER; l_auto NUMBER; l_pesado NUMBER;
  l_semana NUMBER;
  l_regla_max NUMBER;

  -- Estaciones
  ne      PLS_INTEGER := 0;
  e_id    t_n; e_nom t_v; e_depto t_v; e_front t_v; e_gnv t_v; e_prem t_v; e_sub t_v;
  e_peso  t_n; e_nsur t_n;
  sur     t_n;               -- surtidores activos: k * 10 + j
  stock   t_n;               -- existencia fisica: k * 10 + f
  cap     t_n;
  l_nrec  PLS_INTEGER := 0;

  -- Modelos de vehiculo
  nm      PLS_INTEGER := 0;
  mo_tipo t_v; mo_f t_n; mo_marca t_v; mo_modelo t_v; mo_cc t_n; mo_tank t_n; mo_peso t_n; mo_pais t_v;

  -- Personas
  np      PLS_INTEGER := 0;
  p_id    t_n; p_hue t_v;
  nombres   t_v; apellidos t_v;

  -- Vehiculos
  nv      PLS_INTEGER := 0;
  va_id t_n; va_tipo t_v; va_f t_n; va_tank t_n; va_cc t_n; va_c t_n; va_owner t_n;
  va_home t_n; va_sec t_n; va_far t_n; va_prof t_v; va_next t_d; va_last t_d; va_ext t_v;
  benef_owner t_n;           -- beneficios abiertos por persona

  -- Bidones y concentracion
  b_per t_n; b_perm t_n; b_f t_n; b_k t_n; b_fin t_d;
  s_per t_n; s_k t_n;
  c_per t_n; c_veh t_n; c_act t_v;

  -- Horas del dia (peso relativo por hora)
  w_hora t_n;
  l_wtot NUMBER := 0;

  -- Contadores
  n_aprob NUMBER := 0; n_bloq NUMBER := 0; n_err NUMBER := 0; n_rec NUMBER := 0;
  l_dummy NUMBER;
  l_cant  NUMBER;

  -- ----------------------------------------------------------
  -- Utilitarios
  -- ----------------------------------------------------------
  FUNCTION rnd RETURN NUMBER IS
  BEGIN
    RETURN DBMS_RANDOM.VALUE;
  END rnd;

  FUNCTION entre(p_a IN NUMBER, p_b IN NUMBER) RETURN NUMBER IS
  BEGIN
    RETURN DBMS_RANDOM.VALUE(p_a, p_b);
  END entre;

  FUNCTION entero(p_a IN NUMBER, p_b IN NUMBER) RETURN NUMBER IS
  BEGIN
    RETURN TRUNC(DBMS_RANDOM.VALUE(p_a, p_b + 1));
  END entero;

  -- Fraccion del dia segun la distribucion horaria
  FUNCTION hora RETURN NUMBER IS
    l_r   NUMBER := DBMS_RANDOM.VALUE(0, l_wtot);
    l_acc NUMBER := 0;
  BEGIN
    FOR h IN 0 .. 23 LOOP
      l_acc := l_acc + w_hora(h);
      IF l_r < l_acc THEN
        RETURN (h + DBMS_RANDOM.VALUE(0, 0.98)) / 24;
      END IF;
    END LOOP;
    RETURN 23.5 / 24;
  END hora;

  FUNCTION vende(p_k IN PLS_INTEGER, p_f IN PLS_INTEGER) RETURN BOOLEAN IS
  BEGIN
    RETURN p_f IN (1, 2) OR (p_f = 3 AND e_gnv(p_k) = 'S') OR (p_f = 4 AND e_prem(p_k) = 'S');
  END vende;

  -- Estacion al azar (ponderada) que vende p_f.
  -- p_modo: TODAS, NOFRONT, FRONT, DEPTO (mismo depto que p_ref), OTRO (otro depto que p_ref)
  FUNCTION est_azar(p_f IN PLS_INTEGER, p_modo IN VARCHAR2, p_ref IN PLS_INTEGER DEFAULT NULL,
                    p_excluir IN PLS_INTEGER DEFAULT NULL) RETURN PLS_INTEGER IS
    l_tot NUMBER := 0;
    l_r   NUMBER;
    l_ok  BOOLEAN;
  BEGIN
    FOR pasada IN 1 .. 2 LOOP
      l_r := DBMS_RANDOM.VALUE(0, GREATEST(l_tot, 0.0001));
      l_tot := 0;
      FOR k IN 1 .. ne LOOP
        l_ok := vende(k, p_f) AND (p_excluir IS NULL OR k <> p_excluir)
                AND (p_modo = 'TODAS'
                     OR (p_modo = 'NOFRONT' AND e_front(k) = 'N')
                     OR (p_modo = 'FRONT'   AND e_front(k) = 'S')
                     OR (p_modo = 'DEPTO'   AND e_depto(k) = e_depto(p_ref))
                     OR (p_modo = 'OTRO'    AND e_depto(k) <> e_depto(p_ref) AND e_front(k) = 'N'));
        IF l_ok THEN
          l_tot := l_tot + e_peso(k);
          IF pasada = 2 AND l_r < l_tot THEN
            RETURN k;
          END IF;
        END IF;
      END LOOP;
      IF l_tot = 0 THEN
        RETURN NULL;
      END IF;
    END LOOP;
    RETURN NULL;
  END estacion;

  -- ----------------------------------------------------------
  -- Altas de maestros
  -- ----------------------------------------------------------
  PROCEDURE add_est(p_nom IN VARCHAR2, p_muni IN VARCHAR2, p_zona IN VARCHAR2,
                    p_lat IN NUMBER, p_lon IN NUMBER, p_front IN CHAR,
                    p_gnv IN CHAR, p_prem IN CHAR, p_peso IN NUMBER, p_sub IN CHAR DEFAULT 'N') IS
    l_mu    NUMBER;
    l_dep   VARCHAR2(50);
    l_id    NUMBER;
    l_sid   NUMBER;
    l_nsur  PLS_INTEGER;
    l_nit   VARCHAR2(20);
    l_dir   VARCHAR2(250);
    l_cap   NUMBER;
  BEGIN
    ne := ne + 1;
    SELECT m.id_municipio, d.nombre INTO l_mu, l_dep
      FROM municipio m JOIN departamento d ON d.id_departamento = m.id_departamento
     WHERE m.nombre = p_muni;
    l_nit := TO_CHAR(1020304000 + ne * 17);
    l_dir := 'Av. principal s/n, zona ' || p_zona;
    INSERT INTO estacion (id_municipio, nombre, nit, zona, direccion, latitud, longitud, es_fronteriza)
      VALUES (l_mu, p_nom, l_nit, p_zona, l_dir, p_lat, p_lon, p_front)
      RETURNING id_estacion INTO l_id;
    e_id(ne) := l_id; e_nom(ne) := p_nom; e_depto(ne) := l_dep; e_front(ne) := p_front;
    e_gnv(ne) := p_gnv; e_prem(ne) := p_prem; e_peso(ne) := p_peso; e_sub(ne) := p_sub;

    l_nsur := 3 + MOD(ne, 2);
    FOR j IN 1 .. l_nsur LOOP
      INSERT INTO surtidor (id_estacion, codigo) VALUES (l_id, 'S' || j) RETURNING id_surtidor INTO l_sid;
      sur(ne * 10 + j) := l_sid;
    END LOOP;
    e_nsur(ne) := l_nsur;
    IF MOD(ne, 5) = 0 THEN   -- un surtidor fuera de servicio en algunas estaciones
      INSERT INTO surtidor (id_estacion, codigo, estado) VALUES (l_id, 'S9', 'INACTIVO');
    END IF;

    FOR f IN 1 .. 4 LOOP
      IF vende(ne, f) THEN
        l_cap := CASE f WHEN 1 THEN 12000 WHEN 2 THEN 15000 ELSE 4000 END;
        cap(ne * 10 + f)   := l_cap;
        stock(ne * 10 + f) := l_cap * 0.6;
        INSERT INTO tanque_estacion (id_estacion, id_combustible, capacidad, saldo_inicial, fecha_saldo_inicial)
          VALUES (l_id, comb(f), l_cap, l_cap * 0.6, c_inicio);
      END IF;
    END LOOP;
  END add_est;

  PROCEDURE add_mod(p_tipo IN VARCHAR2, p_f IN PLS_INTEGER, p_marca IN VARCHAR2, p_modelo IN VARCHAR2,
                    p_cc IN NUMBER, p_tank IN NUMBER, p_peso IN NUMBER, p_pais IN VARCHAR2) IS
  BEGIN
    nm := nm + 1;
    mo_tipo(nm) := p_tipo; mo_f(nm) := p_f; mo_marca(nm) := p_marca; mo_modelo(nm) := p_modelo;
    mo_cc(nm) := p_cc; mo_tank(nm) := p_tank; mo_peso(nm) := p_peso; mo_pais(nm) := p_pais;
  END add_mod;

  FUNCTION modelo(p_tipo IN VARCHAR2, p_f IN PLS_INTEGER) RETURN PLS_INTEGER IS
    l_tot NUMBER := 0;
    l_r   NUMBER;
    l_acc NUMBER := 0;
  BEGIN
    FOR m IN 1 .. nm LOOP
      IF mo_tipo(m) = p_tipo AND mo_f(m) = p_f THEN l_tot := l_tot + mo_peso(m); END IF;
    END LOOP;
    l_r := DBMS_RANDOM.VALUE(0, l_tot);
    FOR m IN 1 .. nm LOOP
      IF mo_tipo(m) = p_tipo AND mo_f(m) = p_f THEN
        l_acc := l_acc + mo_peso(m);
        IF l_r < l_acc THEN RETURN m; END IF;
      END IF;
    END LOOP;
    RETURN NULL;
  END modelo;

  PROCEDURE add_persona(p_extranjero IN BOOLEAN) IS
    l_id     NUMBER;
    l_tipo   VARCHAR2(10);
    l_doc    VARCHAR2(20);
    l_nac    VARCHAR2(50);
    l_nom    VARCHAR2(100);
    l_ap1    VARCHAR2(60);
    l_ap2    VARCHAR2(60);
    l_reg    DATE;
  BEGIN
    np := np + 1;
    l_nom := nombres(entero(1, nombres.COUNT));
    IF rnd < 0.3 THEN
      l_nom := l_nom || ' ' || nombres(entero(1, nombres.COUNT));
    END IF;
    l_ap1 := apellidos(entero(1, apellidos.COUNT));
    l_ap2 := apellidos(entero(1, apellidos.COUNT));
    IF p_extranjero THEN
      l_tipo := 'PASAPORTE';
      l_nac  := CASE MOD(np, 4) WHEN 0 THEN 'PERUANA' WHEN 1 THEN 'ARGENTINA' WHEN 2 THEN 'CHILENA' ELSE 'BRASILENA' END;
      l_doc  := SUBSTR(l_nac, 1, 2) || TO_CHAR(4500000 + np * 31);
    ELSE
      l_tipo := 'CI';
      l_nac  := 'BOLIVIANA';
      l_doc  := TO_CHAR(3000000 + np * 37);
    END IF;
    l_reg := c_alta - entero(30, 3000);
    INSERT INTO persona (tipo_documento, nro_documento, nombres, apellido_paterno, apellido_materno,
                         nacionalidad, fecha_registro)
      VALUES (l_tipo, l_doc, l_nom, l_ap1, l_ap2, l_nac, l_reg)
      RETURNING id_persona INTO l_id;
    p_id(np) := l_id;
    -- Huella: casi todos los bolivianos (sin huella -> no pueden tener beneficio)
    IF NOT p_extranjero AND MOD(np, 33) <> 0 THEN
      INSERT INTO huella_digital (id_persona, plantilla, fecha_enrolamiento)
        VALUES (l_id, TO_BLOB(UTL_RAW.CAST_TO_RAW('HUELLA-SIMULADA-' || l_doc)), l_reg);
      p_hue(np) := 'S';
    ELSE
      p_hue(np) := 'N';
    END IF;
  END add_persona;

  -- Perfil de un vehiculo nacional segun su modelo (cuotas aproximadas por probabilidad)
  FUNCTION perfil(p_tipo IN VARCHAR2, p_f IN PLS_INTEGER, p_tank IN NUMBER, p_cc IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_tipo = 'AUTO' AND p_f = 1 AND p_tank >= 63 AND rnd < 0.40 THEN RETURN 'FRO'; END IF;
    IF p_tipo = 'AUTO' AND p_f = 1 AND p_cc <= 1100 AND rnd < 0.30 THEN RETURN 'CCB'; END IF;
    IF p_tipo = 'AUTO' AND p_f IN (1, 3) AND p_tank < 60 AND rnd < 0.07 THEN RETURN 'TAX'; END IF;
    IF p_tipo = 'AUTO' AND p_f = 1 AND p_tank BETWEEN 40 AND 56 AND rnd < 0.05 THEN RETURN 'ACO'; END IF;
    IF p_tipo = 'AUTO' AND p_f = 1 AND rnd < 0.015 THEN RETURN 'CLO'; END IF;
    IF p_tipo IN ('AUTO', 'MOTO') AND p_f = 1 AND rnd < 0.013 THEN RETURN 'TQX'; END IF;
    RETURN 'NOR';
  END perfil;

  PROCEDURE add_vehiculo(p_owner IN PLS_INTEGER, p_extranjero IN BOOLEAN) IS
    l_tipo   VARCHAR2(10);
    l_f      PLS_INTEGER;
    l_m      PLS_INTEGER;
    l_r      NUMBER := rnd;
    l_ficha  NUMBER;
    l_id     NUMBER;
    l_tipo_id NUMBER;
    l_placa  VARCHAR2(15);
    l_pais   VARCHAR2(3);
    l_rfid   VARCHAR2(40);
    l_alta   DATE;
    l_clase  VARCHAR2(30);
    l_serv   VARCHAR2(20);
    l_anio   NUMBER;
    l_chasis VARCHAR2(30);
    l_dui    VARCHAR2(30);
    l_esp    NUMBER;
    l_mod    VARCHAR2(50);
    l_marca  VARCHAR2(50);
    l_ppais  VARCHAR2(50);
    l_cc     NUMBER;
    l_tank   NUMBER;
  BEGIN
    nv := nv + 1;
    -- tipo y combustible
    IF p_extranjero THEN
      l_tipo := CASE WHEN l_r < 0.85 THEN 'AUTO' ELSE 'PESADO' END;
      l_f    := CASE WHEN l_tipo = 'PESADO' THEN 2 WHEN rnd < 0.8 THEN 1 ELSE 2 END;
    ELSE
      l_tipo := CASE WHEN l_r < 0.20 THEN 'MOTO' WHEN l_r < 0.90 THEN 'AUTO' ELSE 'PESADO' END;
      l_r := rnd;
      l_f := CASE l_tipo WHEN 'MOTO' THEN 1 WHEN 'PESADO' THEN 2
                         ELSE CASE WHEN l_r < 0.76 THEN 1 WHEN l_r < 0.88 THEN 3 WHEN l_r < 0.94 THEN 4 ELSE 2 END END;
    END IF;
    l_m := modelo(l_tipo, l_f);
    l_marca := mo_marca(l_m); l_mod := mo_modelo(l_m); l_cc := mo_cc(l_m); l_tank := mo_tank(l_m);
    l_ppais := mo_pais(l_m);
    l_tipo_id := CASE l_tipo WHEN 'MOTO' THEN l_moto WHEN 'AUTO' THEN l_auto ELSE l_pesado END;
    l_alta := c_alta - entero(0, 2500);

    va_tipo(nv) := l_tipo; va_f(nv) := l_f; va_tank(nv) := l_tank; va_cc(nv) := l_cc;
    va_owner(nv) := p_owner;
    va_ext(nv) := CASE WHEN p_extranjero THEN 'S' ELSE 'N' END;

    IF p_extranjero THEN
      l_pais  := CASE MOD(nv, 4) WHEN 0 THEN 'PER' WHEN 1 THEN 'ARG' WHEN 2 THEN 'CHL' ELSE 'BRA' END;
      l_placa := CHR(65 + MOD(nv, 26)) || CHR(65 + MOD(nv * 7, 26)) || CHR(65 + MOD(nv * 13, 26))
                 || '-' || LPAD(MOD(nv, 1000), 3, '0');
      l_alta := c_inicio - entero(1, 60);   -- fuera del SQL: entero es local
      INSERT INTO vehiculo (id_tipo_vehiculo, placa, pais_placa, fecha_registro)
        VALUES (l_tipo_id, l_placa, l_pais, l_alta)
        RETURNING id_vehiculo INTO l_id;
      va_prof(nv) := CASE WHEN l_tipo = 'AUTO' AND l_f = 1 AND rnd < 0.30 THEN 'EXF' ELSE 'EXT' END;
    ELSE
      l_anio   := entero(2005, 2025);
      l_chasis := 'CHS' || LPAD(nv, 8, '0');
      l_dui    := 'DUI-' || TO_CHAR(l_alta, 'YYYY') || '-' || LPAD(nv, 6, '0');
      INSERT INTO ficha_aduana (nro_chasis, nro_dui, id_combustible, marca, modelo, anio_fabricacion,
                                cilindrada, capacidad_tanque, pais_procedencia, fecha_nacionalizacion)
        VALUES (l_chasis, l_dui, comb(l_f), l_marca, l_mod, l_anio, l_cc, l_tank, l_ppais, l_alta)
        RETURNING id_ficha INTO l_ficha;
      l_placa := TO_CHAR(1000 + nv) || CHR(65 + MOD(nv * 3, 26)) || CHR(65 + MOD(nv * 11, 26))
                 || CHR(65 + MOD(nv * 17, 26));
      l_rfid  := 'RFID' || LPAD(nv, 8, '0');
      INSERT INTO vehiculo (id_tipo_vehiculo, id_ficha, placa, pais_placa, codigo_rfid, fecha_registro)
        VALUES (l_tipo_id, l_ficha, l_placa, 'BOL', l_rfid, l_alta)
        RETURNING id_vehiculo INTO l_id;
      va_prof(nv) := perfil(l_tipo, l_f, l_tank, l_cc);

      l_clase := CASE l_tipo WHEN 'MOTO' THEN 'MOTOCICLETA' WHEN 'PESADO' THEN 'CAMION'
                   ELSE CASE WHEN l_tank >= 63 THEN 'CAMIONETA' ELSE 'AUTOMOVIL' END END;
      l_serv  := CASE WHEN va_prof(nv) = 'TAX' OR (l_tipo = 'PESADO' AND rnd < 0.3) THEN 'PUBLICO' ELSE 'PARTICULAR' END;
      INSERT INTO registro_ruat (id_vehiculo, id_persona, clase, servicio, fecha_alta)
        VALUES (l_id, p_id(p_owner), l_clase, l_serv, l_alta);

      -- Beneficio: titular con huella, maximo 2 por persona, ~90 % lo tramito
      IF p_hue(p_owner) = 'S' AND NVL(benef_owner(p_owner), 0) < 2 AND rnd < 0.9 THEN
        INSERT INTO registro_beneficio (id_vehiculo, id_persona, id_regla, fecha_inicio)
          VALUES (l_id, p_id(p_owner), l_regla_max, c_alta);
        benef_owner(p_owner) := NVL(benef_owner(p_owner), 0) + 1;
      END IF;
    END IF;
    va_id(nv) := l_id;

    -- Estaciones habituales
    IF va_prof(nv) IN ('FRO', 'EXF') THEN
      va_home(nv) := est_azar(l_f, 'FRONT');
    ELSIF p_extranjero AND rnd < 0.6 THEN
      va_home(nv) := est_azar(l_f, 'FRONT');
    ELSE
      va_home(nv) := est_azar(l_f, 'NOFRONT');
    END IF;
    IF va_home(nv) IS NULL THEN
      va_home(nv) := est_azar(l_f, 'TODAS');
    END IF;
    va_sec(nv) := NVL(est_azar(l_f, 'DEPTO', va_home(nv), va_home(nv)), va_home(nv));
    va_far(nv) := NVL(est_azar(l_f, 'OTRO', va_home(nv)), va_sec(nv));

    -- Consumo diario segun su regla CONSUMO_ESPERADO y el perfil
    l_esp := NVL(pkg_reglas.f_consumo_esperado_dia(l_id, CAST(c_inicio AS TIMESTAMP)), 8);
    va_c(nv) := l_esp * CASE va_prof(nv)
                          WHEN 'TAX' THEN entre(2.2, 2.8)
                          WHEN 'CCB' THEN entre(2.0, 2.4)
                          WHEN 'EXT' THEN entre(0.6, 1.0)
                          WHEN 'EXF' THEN entre(0.6, 1.0)
                          ELSE entre(0.6, 1.15) END;
    va_next(nv) := c_inicio + entre(0, va_tank(nv) * 0.65 / va_c(nv));
    va_last(nv) := va_next(nv) - va_tank(nv) * 0.65 / va_c(nv);
  END add_vehiculo;

  -- ----------------------------------------------------------
  -- Eventos
  -- ----------------------------------------------------------
  PROCEDURE add_ev(p_tipo IN CHAR, p_veh IN PLS_INTEGER, p_persona IN NUMBER, p_k IN PLS_INTEGER,
                   p_f IN PLS_INTEGER, p_cant IN NUMBER, p_ts IN DATE, p_huella IN CHAR, p_rfid IN CHAR,
                   p_recip IN NUMBER DEFAULT NULL) IS
    l_e   t_ev;
    l_seg NUMBER;
  BEGIN
    IF p_k IS NULL OR p_cant IS NULL OR p_cant <= 0 THEN
      RETURN;
    END IF;
    l_seq := l_seq + 1;
    l_e.tipo := p_tipo; l_e.veh := p_veh; l_e.persona := p_persona; l_e.k := p_k; l_e.f := p_f;
    l_e.cant := ROUND(p_cant, 1); l_e.ts := p_ts; l_e.huella := p_huella; l_e.rfid := p_rfid;
    l_e.recip := p_recip;
    l_seg := TRUNC((p_ts - TRUNC(p_ts)) * 86400);
    ev(TO_CHAR(l_seg, 'FM00000') || LPAD(l_seq, 7, '0')) := l_e;
  END add_ev;

  -- Quien carga: el titular casi siempre; a veces un chofer u otra persona
  PROCEDURE quien(p_i IN PLS_INTEGER, p_persona OUT NUMBER, p_huella OUT CHAR, p_rfid OUT CHAR) IS
    l_r NUMBER := rnd;
    l_j PLS_INTEGER;
  BEGIN
    IF va_ext(p_i) = 'S' THEN
      p_persona := p_id(va_owner(p_i)); p_huella := 'S'; p_rfid := 'N';
      RETURN;
    END IF;
    IF l_r < 0.84 THEN
      l_j := va_owner(p_i);
    ELSIF l_r < 0.94 THEN
      l_j := entero(1056, 1150);         -- chofer
    ELSE
      l_j := entero(1, 990);             -- otro propietario
    END IF;
    p_persona := p_id(l_j);
    p_huella  := CASE WHEN p_hue(l_j) = 'N' OR rnd < 0.02 THEN 'N' ELSE 'S' END;
    p_rfid    := CASE WHEN rnd < 0.01 THEN 'N' ELSE 'S' END;
  END quien;

  -- Huella de quien carga: 'N' si la persona no tiene huella enrolada
  FUNCTION hue(p_j IN PLS_INTEGER) RETURN CHAR IS
  BEGIN
    RETURN p_hue(p_j);
  END hue;

  PROCEDURE planificar_vehiculo(p_i IN PLS_INTEGER, p_dia IN DATE) IS
    l_t     DATE;
    l_gap   NUMBER;
    l_q     NUMBER;
    l_k     PLS_INTEGER;
    l_r     NUMBER;
    l_per   NUMBER;
    l_hue   CHAR(1);
    l_rfid  CHAR(1);
    l_n     PLS_INTEGER := 0;
    l_hoy   DATE := NULL;   -- ultima carga normal del dia
    l_base  DATE;
  BEGIN
    -- Cargas normales (hasta 2 por dia)
    WHILE va_next(p_i) < p_dia + 1 AND l_n < 2 LOOP
      IF va_ext(p_i) = 'S' AND rnd > 0.35 THEN
        va_next(p_i) := p_dia + entero(1, 3) + hora;   -- el vehiculo no esta en Bolivia
        EXIT;
      END IF;
      l_t := GREATEST(va_next(p_i), p_dia + hora);
      EXIT WHEN l_t >= p_dia + 1;
      l_gap := l_t - va_last(p_i);
      l_q   := LEAST(GREATEST(va_c(p_i) * l_gap * entre(0.9, 1.1), va_tank(p_i) * 0.15), va_tank(p_i) * 0.95);
      l_r   := rnd;
      l_k   := CASE WHEN l_r < 0.85 THEN va_home(p_i)
                    WHEN l_r < 0.97 OR l_gap < 1.5 THEN va_sec(p_i)
                    ELSE va_far(p_i) END;
      quien(p_i, l_per, l_hue, l_rfid);
      add_ev('C', p_i, l_per, l_k, va_f(p_i), l_q, l_t, l_hue, l_rfid);
      va_last(p_i) := l_t;
      va_next(p_i) := l_t + va_tank(p_i) * entre(0.5, 0.8) / va_c(p_i);
      l_hoy := l_t;
      l_n := l_n + 1;
    END LOOP;

    -- Comportamientos anomalos
    CASE va_prof(p_i)
      WHEN 'ACO' THEN      -- acopiador: dos cargas extra en el dia, en dos estaciones
        IF rnd < 0.40 THEN
          l_base := p_dia + entre(7, 10) / 24;
          add_ev('C', p_i, p_id(va_owner(p_i)), va_sec(p_i), va_f(p_i), entre(25, 35),
                 l_base + entre(3, 5) / 24, hue(va_owner(p_i)), 'S');
          add_ev('C', p_i, p_id(va_owner(p_i)), va_home(p_i), va_f(p_i), entre(25, 35),
                 LEAST(l_base + entre(7, 10) / 24, p_dia + 0.999), hue(va_owner(p_i)), 'S');
        END IF;
      WHEN 'FRO' THEN      -- contrabando en frontera
        IF rnd < 0.30 THEN
          l_base := p_dia + entre(8, 13) / 24;
          add_ev('C', p_i, p_id(va_owner(p_i)), va_home(p_i), 1, entre(50, 70), l_base, hue(va_owner(p_i)), 'S');
          IF rnd < 0.30 THEN
            add_ev('C', p_i, p_id(va_owner(p_i)), va_home(p_i), 1, entre(20, 40),
                   l_base + entre(4, 6) / 24, hue(va_owner(p_i)), 'S');
          END IF;
        END IF;
      WHEN 'EXF' THEN      -- extranjero comprando en frontera
        IF rnd < 0.25 THEN
          l_base := p_dia + entre(8, 13) / 24;
          add_ev('C', p_i, p_id(va_owner(p_i)), va_home(p_i), va_f(p_i), entre(45, 70), l_base, 'S', 'N');
          IF rnd < 0.35 THEN
            add_ev('C', p_i, p_id(va_owner(p_i)), va_home(p_i), va_f(p_i), entre(25, 45),
                   l_base + entre(4, 6) / 24, 'S', 'N');
          END IF;
        END IF;
      WHEN 'CLO' THEN      -- placa clonada: otra carga lejos poco despues
        IF l_hoy IS NOT NULL AND rnd < 0.15 AND l_hoy + 2.5 / 24 < p_dia + 1 THEN
          l_r := entero(1056, 1150);   -- otra persona con la placa clonada
          add_ev('C', p_i, p_id(l_r), va_far(p_i), va_f(p_i), entre(15, 25),
                 l_hoy + entre(1, 2) / 24, hue(l_r), 'S');
        END IF;
      WHEN 'TQX' THEN      -- carga mayor que el tanque (tanque adicional oculto)
        IF rnd < 0.05 THEN
          add_ev('C', p_i, p_id(va_owner(p_i)), va_home(p_i), va_f(p_i),
                 va_tank(p_i) * entre(1.2, 1.4), p_dia + hora, hue(va_owner(p_i)), 'S');
        END IF;
      ELSE
        NULL;
    END CASE;
  END planificar_vehiculo;

  PROCEDURE ejecutar(p_e IN t_ev) IS
    l_sur  NUMBER;
    l_tx   NUMBER;
    l_tk   NUMBER;
    l_est  VARCHAR2(10);
  BEGIN
    l_sur := sur(p_e.k * 10 + entero(1, e_nsur(p_e.k)));
    SAVEPOINT sp_op;
    IF p_e.tipo = 'C' THEN
      pkg_transacciones.p_registrar_carga_vehicular(
        p_id_surtidor => l_sur, p_id_vehiculo => va_id(p_e.veh), p_id_persona => p_e.persona,
        p_id_combustible => comb(p_e.f), p_cantidad => p_e.cant, p_fecha_hora => CAST(p_e.ts AS TIMESTAMP),
        p_huella_verificada => p_e.huella, p_rfid_leido => p_e.rfid,
        p_id_transaccion => l_tx, p_nro_ticket => l_tk, p_estado => l_est);
    ELSE
      pkg_transacciones.p_registrar_compra_bidon(
        p_id_surtidor => l_sur, p_id_persona => p_e.persona, p_id_combustible => comb(p_e.f),
        p_cantidad => p_e.cant, p_nro_recipientes => p_e.recip, p_motivo_declarado => 'Uso declarado',
        p_fecha_hora => CAST(p_e.ts AS TIMESTAMP), p_huella_verificada => p_e.huella,
        p_id_transaccion => l_tx, p_nro_ticket => l_tk, p_estado => l_est);
    END IF;
    IF l_est = 'APROBADA' THEN
      stock(p_e.k * 10 + p_e.f) := stock(p_e.k * 10 + p_e.f) - p_e.cant;
      n_aprob := n_aprob + 1;
    ELSE
      n_bloq := n_bloq + 1;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK TO sp_op;
      n_err := n_err + 1;
      IF n_err <= 10 THEN
        DBMS_OUTPUT.PUT_LINE('  aviso: operacion rechazada: ' || SUBSTR(SQLERRM, 1, 200));
      END IF;
  END ejecutar;

  -- Recepciones YPFB a las 06:00 cuando el tanque baja del 30 %.
  -- Estaciones con e_sub = 'S' registran solo el 70 % de lo que reciben
  -- (desbalance que detecta la conciliacion).
  PROCEDURE recepciones(p_dia IN DATE) IS
    l_q    NUMBER;
    l_reg  NUMBER;
    l_guia VARCHAR2(30);
    l_lote VARCHAR2(30);
    l_ts   TIMESTAMP;
    l_eid  NUMBER;
    l_cid  NUMBER;
  BEGIN
    FOR k IN 1 .. ne LOOP
      FOR f IN 1 .. 4 LOOP
        IF vende(k, f) AND stock(k * 10 + f) < cap(k * 10 + f) * 0.30 THEN
          l_q := ROUND((cap(k * 10 + f) * 0.85 - stock(k * 10 + f)) / 100) * 100;
          stock(k * 10 + f) := stock(k * 10 + f) + l_q;
          l_reg  := CASE WHEN e_sub(k) = 'S' THEN ROUND(l_q * 0.7) ELSE l_q END;
          l_nrec := l_nrec + 1;
          l_guia := 'GUIA-' || TO_CHAR(p_dia, 'YYYYMMDD') || '-' || LPAD(l_nrec, 5, '0');
          l_lote := 'L' || TO_CHAR(p_dia, 'YYMM') || '-' || LPAD(l_nrec, 5, '0');
          l_ts   := CAST(p_dia + entre(5.5, 7) / 24 AS TIMESTAMP);
          l_eid  := e_id(k);
          l_cid  := comb(f);
          INSERT INTO recepcion_combustible (id_estacion, id_combustible, nro_guia_ypfb, nro_lote, cantidad, fecha_hora)
            VALUES (l_eid, l_cid, l_guia, l_lote, l_reg, l_ts);
          n_rec := n_rec + 1;
        END IF;
      END LOOP;
    END LOOP;
  END recepciones;

  PROCEDURE planificar_bidones(p_dia IN DATE) IS
  BEGIN
    FOR b IN 1 .. b_per.COUNT LOOP
      IF rnd < 0.18 THEN
        add_ev('B', NULL, p_id(b_per(b)), b_k(b), b_f(b), entre(20, 60), p_dia + entre(7, 18) / 24, 'S', 'S',
               entero(1, 3));
      END IF;
      IF b <= 10 AND rnd < 0.06 THEN   -- compra grande que excede el permiso semanal
        add_ev('B', NULL, p_id(b_per(b)), b_k(b), b_f(b), entre(150, 180), p_dia + entre(7, 18) / 24, 'S', 'S', 3);
      END IF;
    END LOOP;
    FOR s IN 1 .. s_per.COUNT LOOP     -- sin permiso: se bloquea
      IF rnd < 0.05 THEN
        add_ev('B', NULL, p_id(s_per(s)), s_k(s), 1, entre(20, 40), p_dia + entre(7, 18) / 24, 'S', 'S',
               entero(1, 2));
      END IF;
    END LOOP;
  END planificar_bidones;

  -- Personas que cargan muchos vehiculos ajenos en una semana
  PROCEDURE planificar_concentracion(p_dia IN DATE) IS
    l_dow PLS_INTEGER := p_dia - TRUNC(p_dia, 'IW');   -- 0 = lunes
    l_v   PLS_INTEGER;
  BEGIN
    FOR c IN 1 .. c_per.COUNT LOOP
      IF l_dow = 0 THEN
        c_act(c) := CASE WHEN rnd < 0.35 THEN 'S' ELSE 'N' END;
      END IF;
      IF c_act(c) = 'S' AND l_dow < 5 AND rnd < 0.8 THEN
        l_v := c_veh(c * 10 + l_dow + 1);
        add_ev('C', l_v, p_id(c_per(c)), va_home(l_v), va_f(l_v), entre(15, 25),
               p_dia + entre(9, 19) / 24, 'S', 'S');
      END IF;
    END LOOP;
  END planificar_concentracion;

BEGIN
  IF c_inicio < DATE '2026-01-01' THEN
    RAISE_APPLICATION_ERROR(-20999, '11_datos_simulados: la ventana empieza antes de 2026-01-01 (no hay precios ni reglas)');
  END IF;
  DBMS_RANDOM.SEED(42);
  DBMS_OUTPUT.PUT_LINE('Ventana de datos: ' || TO_CHAR(c_inicio, 'YYYY-MM-DD') || ' a ' || TO_CHAR(c_fin - 1, 'YYYY-MM-DD'));

  -- Catalogos
  SELECT id_combustible INTO comb(1) FROM combustible WHERE nombre = 'Gasolina Especial';
  SELECT id_combustible INTO comb(2) FROM combustible WHERE nombre = 'Diesel Oil';
  SELECT id_combustible INTO comb(3) FROM combustible WHERE nombre = 'GNV';
  SELECT id_combustible INTO comb(4) FROM combustible WHERE nombre = 'Gasolina Premium';
  SELECT id_tipo_vehiculo INTO l_moto   FROM tipo_vehiculo WHERE nombre = 'MOTO';
  SELECT id_tipo_vehiculo INTO l_auto   FROM tipo_vehiculo WHERE nombre = 'AUTO';
  SELECT id_tipo_vehiculo INTO l_pesado FROM tipo_vehiculo WHERE nombre = 'PESADO';
  l_semana    := pkg_reglas.f_id_tipo_periodo('SEMANA');
  l_regla_max := pkg_reglas.f_id_regla_vigente('MAX_VEHICULOS_PERSONA', CAST(c_alta AS TIMESTAMP));

  -- Distribucion horaria (picos de manana, mediodia y tarde)
  FOR h IN 0 .. 23 LOOP
    w_hora(h) := CASE WHEN h < 5 THEN 1 WHEN h = 5 THEN 2 WHEN h = 6 THEN 4 WHEN h IN (7, 8) THEN 9
                      WHEN h IN (9, 10, 11) THEN 6 WHEN h IN (12, 13) THEN 7 WHEN h IN (14, 15, 16) THEN 6
                      WHEN h IN (17, 18, 19) THEN 9 WHEN h = 20 THEN 6 WHEN h = 21 THEN 4 ELSE 2 END;
    l_wtot := l_wtot + w_hora(h);
  END LOOP;

  -- Nombres (sin tildes)
  FOR r IN (SELECT ROWNUM AS n, COLUMN_VALUE AS v FROM TABLE(sys.odcivarchar2list(
              'Juan','Maria','Carlos','Ana','Luis','Rosa','Jorge','Carmen','Miguel','Patricia',
              'Jose','Silvia','Pedro','Lucia','Mario','Elena','Fernando','Gabriela','Ricardo','Veronica',
              'Marco','Daniela','Raul','Claudia','Hugo','Monica','Victor','Paola','Ramiro','Sandra',
              'Wilson','Roxana','Freddy','Ximena','Edwin','Karina','Rodrigo','Lorena','Alvaro','Teresa'))) LOOP
    nombres(r.n) := r.v;
  END LOOP;
  FOR r IN (SELECT ROWNUM AS n, COLUMN_VALUE AS v FROM TABLE(sys.odcivarchar2list(
              'Mamani','Quispe','Flores','Rojas','Vargas','Gutierrez','Choque','Condori','Lopez','Fernandez',
              'Torrez','Gonzales','Perez','Rodriguez','Garcia','Mendoza','Romero','Herrera','Vasquez','Morales',
              'Castro','Ortiz','Salazar','Aguilar','Rocha','Soliz','Medina','Arce','Zurita','Villarroel',
              'Guzman','Montano','Camacho','Alvarez','Cruz','Limachi','Huanca','Colque','Ticona','Apaza'))) LOOP
    apellidos(r.n) := r.v;
  END LOOP;

  -- Modelos: tipo, combustible, marca, modelo, cc, tanque, peso, pais
  add_mod('MOTO', 1, 'Honda',    'Wave 110',        110,  4,   30, 'Japon');
  add_mod('MOTO', 1, 'Suzuki',   'GN 125',          125,  10,  25, 'Japon');
  add_mod('MOTO', 1, 'Yamaha',   'FZ 150',          150,  12,  25, 'Japon');
  add_mod('MOTO', 1, 'Bajaj',    'Pulsar 200',      200,  15,  15, 'India');
  add_mod('MOTO', 1, 'Honda',    'XR 250',          250,  10,  5,  'Japon');
  add_mod('AUTO', 1, 'Suzuki',   'Alto 1.0',        1000, 35,  10, 'Japon');
  add_mod('AUTO', 1, 'Suzuki',   'Swift 1.2',       1200, 37,  8,  'Japon');
  add_mod('AUTO', 1, 'Toyota',   'Yaris 1.3',       1300, 42,  10, 'Japon');
  add_mod('AUTO', 1, 'Hyundai',  'Accent 1.4',      1400, 43,  10, 'Corea');
  add_mod('AUTO', 1, 'Kia',      'Rio 1.4',         1400, 45,  8,  'Corea');
  add_mod('AUTO', 1, 'Toyota',   'Corolla 1.6',     1600, 50,  14, 'Japon');
  add_mod('AUTO', 1, 'Nissan',   'Sentra 1.8',      1800, 50,  8,  'Japon');
  add_mod('AUTO', 1, 'Toyota',   'Corolla 1.8',     1800, 50,  8,  'Japon');
  add_mod('AUTO', 1, 'Honda',    'Civic 2.0',       2000, 47,  5,  'Japon');
  add_mod('AUTO', 1, 'Toyota',   'RAV4 2.0',        2000, 55,  6,  'Japon');
  add_mod('AUTO', 1, 'Mitsubishi','Outlander 2.4',  2400, 63,  4,  'Japon');
  add_mod('AUTO', 1, 'Toyota',   'Hilux 2.7',       2700, 80,  4,  'Japon');
  add_mod('AUTO', 1, 'Toyota',   '4Runner 4.0',     4000, 87,  2,  'Japon');
  add_mod('AUTO', 3, 'Toyota',   'Probox 1.5 GNV',  1500, 13,  10, 'Japon');
  add_mod('AUTO', 3, 'Nissan',   'Sunny 1.5 GNV',   1500, 13,  6,  'Japon');
  add_mod('AUTO', 3, 'Toyota',   'Corolla 1.8 GNV', 1800, 15,  6,  'Japon');
  add_mod('AUTO', 2, 'Toyota',   'Hilux 2.8 Diesel', 2800, 80, 6,  'Japon');
  add_mod('AUTO', 2, 'Toyota',   'Land Cruiser 4.5', 4500, 130, 3, 'Japon');
  add_mod('AUTO', 4, 'BMW',      '320i 2.0',        2000, 59,  3,  'Alemania');
  add_mod('AUTO', 4, 'Mercedes-Benz', 'C200 1.5',   1500, 66,  3,  'Alemania');
  add_mod('AUTO', 4, 'Audi',     'A4 2.0',          2000, 54,  2,  'Alemania');
  add_mod('PESADO', 2, 'Volvo',  'FH 540',          12800, 600, 4, 'Suecia');
  add_mod('PESADO', 2, 'Scania', 'R450',            13000, 700, 3, 'Suecia');
  add_mod('PESADO', 2, 'Mercedes-Benz', 'Actros 2646', 11900, 500, 3, 'Alemania');
  add_mod('PESADO', 2, 'Hino',   '500 GH',          7700, 200,  5, 'Japon');
  add_mod('PESADO', 2, 'Mitsubishi', 'Fuso Canter', 4900, 100,  6, 'Japon');
  add_mod('PESADO', 2, 'Toyota', 'Coaster (bus)',   4000, 95,   4, 'Japon');

  -- Estaciones: nombre, municipio, zona, lat, lon, fronteriza, GNV, premium, peso [, subregistra]
  add_est('EESS Blanco Galindo',  'Cochabamba',  'Oeste',          -17.3935, -66.1981, 'N', 'S', 'S', 6);
  add_est('EESS America',         'Cochabamba',  'Norte',          -17.3770, -66.1570, 'N', 'S', 'S', 6);
  add_est('EESS Heroinas',        'Cochabamba',  'Centro',         -17.3925, -66.1570, 'N', 'S', 'S', 6);
  add_est('EESS Petrolera',       'Cochabamba',  'Sur',            -17.4180, -66.1350, 'N', 'S', 'N', 5, 'S');
  add_est('EESS Recoleta',        'Cochabamba',  'Noreste',        -17.3700, -66.1450, 'N', 'N', 'N', 4);
  add_est('EESS Sacaba',          'Sacaba',      'Centro Sacaba',  -17.4040, -66.0400, 'N', 'S', 'N', 4);
  add_est('EESS Quillacollo',     'Quillacollo', 'Plaza Bolivar',  -17.3920, -66.2780, 'N', 'S', 'N', 4);
  add_est('EESS Tiquipaya',       'Tiquipaya',   'Central',        -17.3380, -66.2150, 'N', 'N', 'N', 3);
  add_est('EESS Colcapirhua',     'Colcapirhua', 'Avenida',        -17.3870, -66.2380, 'N', 'N', 'N', 3);
  add_est('EESS Vinto',           'Vinto',       'Carretera',      -17.3970, -66.3130, 'N', 'N', 'N', 2);
  add_est('EESS Sipe Sipe',       'Sipe Sipe',   'Central',        -17.4500, -66.3550, 'N', 'N', 'N', 2);
  add_est('EESS Punata',          'Punata',      'Valle Alto',     -17.5460, -65.8380, 'N', 'N', 'N', 2);
  add_est('EESS Villa Tunari',    'Villa Tunari','Tropico',        -16.9740, -65.4200, 'N', 'N', 'N', 2);
  add_est('EESS Chimore',         'Chimore',     'Tropico',        -16.9930, -65.1530, 'N', 'N', 'N', 2);
  add_est('EESS Obrajes',         'La Paz',      'Zona Sur',       -16.5200, -68.1120, 'N', 'S', 'S', 5);
  add_est('EESS Ceja',            'El Alto',     'Ceja',           -16.5000, -68.1630, 'N', 'S', 'N', 4);
  add_est('EESS Cuarto Anillo',   'Santa Cruz de la Sierra', 'Equipetrol', -17.7830, -63.1820, 'N', 'S', 'S', 5);
  add_est('EESS Oruro Norte',     'Oruro',       'Norte',          -17.9600, -67.1100, 'N', 'N', 'N', 3);
  add_est('EESS Sucre Centro',    'Sucre',       'Centro',         -19.0400, -65.2600, 'N', 'N', 'N', 3);
  add_est('EESS Tarija',          'Tarija',      'Centro',         -21.5350, -64.7300, 'N', 'N', 'N', 3);
  add_est('EESS Desaguadero',     'Desaguadero', 'Frontera Peru',  -16.5660, -69.0400, 'S', 'N', 'N', 1);
  add_est('EESS Yacuiba',         'Yacuiba',     'Frontera Argentina', -22.0150, -63.6770, 'S', 'N', 'N', 1, 'S');
  add_est('EESS Villazon',        'Villazon',    'Frontera Argentina', -22.0870, -65.5950, 'S', 'N', 'N', 1);
  add_est('EESS Puerto Suarez',   'Puerto Suarez','Frontera Brasil', -18.9630, -57.7980, 'S', 'N', 'N', 1);
  add_est('EESS Cobija',          'Cobija',      'Frontera Brasil', -11.0270, -68.7690, 'S', 'N', 'N', 1);

  -- Tiempo de viaje entre todas las estaciones (distancia haversine; 30 km/h en
  -- la ciudad, 60 km/h con factor de ruta 1.3 en carretera)
  INSERT INTO tiempo_viaje (id_estacion_origen, id_estacion_destino, minutos_estimados, fecha_estimacion)
  SELECT ida, idb,
         GREATEST(5, ROUND(CASE WHEN km < 20 THEN km / 30 * 60 ELSE km * 1.3 END)),
         c_inicio
    FROM (SELECT a.id_estacion AS ida, b.id_estacion AS idb,
                 6371 * 2 * ASIN(SQRT(POWER(SIN((b.latitud - a.latitud) * ACOS(-1) / 360), 2)
                   + COS(a.latitud * ACOS(-1) / 180) * COS(b.latitud * ACOS(-1) / 180)
                   * POWER(SIN((b.longitud - a.longitud) * ACOS(-1) / 360), 2))) AS km
            FROM estacion a JOIN estacion b ON b.id_estacion <> a.id_estacion);
  DBMS_OUTPUT.PUT_LINE('Estaciones: ' || ne || ' | tiempos de viaje: ' || SQL%ROWCOUNT);

  -- Personas: 1..990 propietarios, 991..1150 otros bolivianos, 1151..1200 extranjeros
  FOR j IN 1 .. 1150 LOOP add_persona(FALSE); END LOOP;
  FOR j IN 1 .. 50   LOOP add_persona(TRUE);  END LOOP;
  DBMS_OUTPUT.PUT_LINE('Personas: ' || np);

  -- Vehiculos nacionales: 600 duenios de 1, 300 de 2, 60 de 3 y 30 de 4 (1.500)
  FOR j IN 1 .. 990 LOOP
    FOR v IN 1 .. CASE WHEN j <= 600 THEN 1 WHEN j <= 900 THEN 2 WHEN j <= 960 THEN 3 ELSE 4 END LOOP
      add_vehiculo(j, FALSE);
    END LOOP;
  END LOOP;
  -- Extranjeros: 2 por persona extranjera (100)
  FOR j IN 1151 .. 1200 LOOP
    add_vehiculo(j, TRUE);
    add_vehiculo(j, TRUE);
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('Vehiculos: ' || nv);
  COMMIT;

  -- Permisos de bidon: personas 991..1030 (5 vencen a mitad de la ventana)
  FOR b IN 1 .. 40 LOOP
    b_per(b) := 990 + b;
    b_f(b)   := CASE WHEN MOD(b, 10) < 3 THEN 1 ELSE 2 END;
    b_k(b)   := est_azar(b_f(b), 'NOFRONT');
    b_fin(b) := CASE WHEN b > 35 THEN c_inicio + 90 ELSE c_fin + 180 END;
    l_cant   := ROUND(entre(150, 300), -1);
    INSERT INTO permiso_bidon (id_persona, id_combustible, id_tipo_periodo, nro_resolucion_anh, motivo,
                               cantidad_autorizada, fecha_emision, fecha_inicio, fecha_fin)
      VALUES (p_id(b_per(b)), comb(b_f(b)), l_semana,
              'ANH-RA-' || TO_CHAR(c_inicio, 'YYYY') || '-' || LPAD(b, 4, '0'),
              CASE MOD(b, 4) WHEN 0 THEN 'Generador electrico' WHEN 1 THEN 'Maquinaria agricola'
                             WHEN 2 THEN 'Bomba de agua' ELSE 'Comunidad sin estacion cercana' END,
              l_cant, c_inicio - 15, c_inicio - 10, b_fin(b))
      RETURNING id_permiso INTO b_perm(b);
  END LOOP;
  -- Sin permiso: personas 1031..1045
  FOR s IN 1 .. 15 LOOP
    s_per(s) := 1030 + s;
    s_k(s)   := est_azar(1, 'TODAS');
  END LOOP;
  -- Concentracion: personas 1046..1055, cada una con 5 vehiculos ajenos normales
  FOR c IN 1 .. 10 LOOP
    c_per(c) := 1045 + c;
    c_act(c) := 'N';
    FOR m IN 1 .. 5 LOOP
      LOOP
        l_dummy := entero(1, 1500);
        EXIT WHEN va_prof(l_dummy) = 'NOR' AND va_tipo(l_dummy) = 'AUTO' AND va_f(l_dummy) = 1;
      END LOOP;
      c_veh(c * 10 + m) := l_dummy;
    END LOOP;
  END LOOP;

  -- Usuarios de la aplicacion (clave aleatoria; 12_seguridad.sh fija las claves demo)
  pkg_usuarios.p_crear_usuario('admin', 'Tmp' || DBMS_RANDOM.STRING('x', 16) || '7z', 'ADMIN', p_id_usuario => l_dummy);
  FOR u IN 1 .. 6 LOOP
    pkg_usuarios.p_crear_usuario('fiscal' || LPAD(u, 2, '0'), 'Tmp' || DBMS_RANDOM.STRING('x', 16) || '7z',
                                 'FISCALIZADOR', p_id_usuario => l_dummy);
  END LOOP;
  FOR u IN 1 .. 4 LOOP
    pkg_usuarios.p_crear_usuario('analista' || LPAD(u, 2, '0'), 'Tmp' || DBMS_RANDOM.STRING('x', 16) || '7z',
                                 'ANALISTA', p_id_usuario => l_dummy);
  END LOOP;
  FOR k IN 1 .. ne LOOP
    pkg_usuarios.p_crear_usuario('operador' || LPAD(k, 2, '0'), 'Tmp' || DBMS_RANDOM.STRING('x', 16) || '7z',
                                 'OPERADOR', p_id_estacion => e_id(k), p_id_usuario => l_dummy);
  END LOOP;
  COMMIT;

  -- 182 dias en orden cronologico
  FOR d IN 0 .. 181 LOOP
    recepciones(c_inicio + d);
    FOR i IN 1 .. nv LOOP
      planificar_vehiculo(i, c_inicio + d);
    END LOOP;
    planificar_bidones(c_inicio + d);
    planificar_concentracion(c_inicio + d);

    DECLARE
      l_key VARCHAR2(20) := ev.FIRST;
    BEGIN
      WHILE l_key IS NOT NULL LOOP
        ejecutar(ev(l_key));
        l_key := ev.NEXT(l_key);
      END LOOP;
    END;
    ev.DELETE;
    COMMIT;
    IF MOD(d + 1, 30) = 0 THEN
      DBMS_OUTPUT.PUT_LINE('  dia ' || (d + 1) || ': aprobadas ' || n_aprob || ', bloqueadas ' || n_bloq
                           || ', rechazadas ' || n_err);
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('Operaciones: aprobadas ' || n_aprob || ', bloqueadas ' || n_bloq
                       || ', rechazadas por validacion ' || n_err || ' | recepciones YPFB ' || n_rec);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/

-- ============================================================
-- B. ESCENARIOS DE DEMOSTRACION (placas DEM-)
-- Fechas relativas al dia de la carga; cada escenario usa sus propios
-- vehiculos y personas, para que se vea solo lo que demuestra.
-- ============================================================
DECLARE
  c_fin  CONSTANT DATE := TRUNC(SYSDATE);
  c_lun  CONSTANT DATE := TRUNC(TRUNC(SYSDATE) - 7, 'IW');   -- lunes de la semana pasada
  l_gas  NUMBER; l_auto NUMBER; l_moto NUMBER; l_max NUMBER; l_semana NUMBER;
  l_tx   NUMBER; l_tk NUMBER; l_est VARCHAR2(10);
  l_n    PLS_INTEGER := 0;

  FUNCTION surtidor_de(p_estacion IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT MIN(s.id_surtidor) INTO l_id
      FROM surtidor s JOIN estacion e ON e.id_estacion = s.id_estacion
     WHERE e.nombre = p_estacion AND s.estado = 'ACTIVO';
    RETURN l_id;
  END sur;

  FUNCTION nueva_persona(p_doc IN VARCHAR2, p_huella IN BOOLEAN DEFAULT TRUE) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    INSERT INTO persona (tipo_documento, nro_documento, nombres, apellido_paterno, nacionalidad, fecha_registro)
      VALUES ('CI', p_doc, 'Demo', 'Escenario ' || p_doc, 'BOLIVIANA', c_fin - 400)
      RETURNING id_persona INTO l_id;
    IF p_huella THEN
      INSERT INTO huella_digital (id_persona, plantilla, fecha_enrolamiento)
        VALUES (l_id, TO_BLOB(UTL_RAW.CAST_TO_RAW('HUELLA-' || p_doc)), c_fin - 400);
    END IF;
    RETURN l_id;
  END persona;

  -- Vehiculo nacional con duenio propio, RUAT y beneficio
  FUNCTION nuevo_vehiculo(p_placa IN VARCHAR2, p_tipo IN NUMBER, p_marca IN VARCHAR2, p_modelo IN VARCHAR2,
                    p_cc IN NUMBER, p_tanque IN NUMBER, p_duenio OUT NUMBER) RETURN NUMBER IS
    l_f  NUMBER;
    l_id NUMBER;
  BEGIN
    p_duenio := nueva_persona('DEM-P' || SUBSTR(p_placa, 5));
    INSERT INTO ficha_aduana (nro_chasis, id_combustible, marca, modelo, anio_fabricacion, cilindrada, capacidad_tanque)
      VALUES ('CHS-' || p_placa, l_gas, p_marca, p_modelo, 2019, p_cc, p_tanque) RETURNING id_ficha INTO l_f;
    INSERT INTO vehiculo (id_tipo_vehiculo, id_ficha, placa, codigo_rfid, fecha_registro)
      VALUES (p_tipo, l_f, p_placa, 'RFID-' || p_placa, c_fin - 400) RETURNING id_vehiculo INTO l_id;
    INSERT INTO registro_ruat (id_vehiculo, id_persona, clase, servicio, fecha_alta)
      VALUES (l_id, p_duenio, 'AUTOMOVIL', 'PARTICULAR', c_fin - 400);
    INSERT INTO registro_beneficio (id_vehiculo, id_persona, id_regla, fecha_inicio)
      VALUES (l_id, p_duenio, l_max, c_fin - 200);
    RETURN l_id;
  END vehiculo;

  PROCEDURE carga(p_esc IN VARCHAR2, p_estacion IN VARCHAR2, p_veh IN NUMBER, p_per IN NUMBER,
                  p_cant IN NUMBER, p_ts IN DATE) IS
  BEGIN
    pkg_transacciones.p_registrar_carga_vehicular(
      p_id_surtidor => surtidor_de(p_estacion), p_id_vehiculo => p_veh, p_id_persona => p_per,
      p_id_combustible => l_gas, p_cantidad => p_cant, p_fecha_hora => CAST(p_ts AS TIMESTAMP),
      p_id_transaccion => l_tx, p_nro_ticket => l_tk, p_estado => l_est);
    l_n := l_n + 1;
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_esc, 4) || TO_CHAR(p_ts, 'YYYY-MM-DD HH24:MI') || '  '
                         || RPAD(p_estacion, 20) || LPAD(p_cant, 5) || ' L  ' || RPAD(l_est, 10)
                         || NVL(pkg_transacciones.f_ultimas_alertas, '-'));
  END carga;

  PROCEDURE bidon(p_esc IN VARCHAR2, p_estacion IN VARCHAR2, p_per IN NUMBER, p_cant IN NUMBER, p_ts IN DATE) IS
  BEGIN
    pkg_transacciones.p_registrar_compra_bidon(
      p_id_surtidor => surtidor_de(p_estacion), p_id_persona => p_per, p_id_combustible => l_gas,
      p_cantidad => p_cant, p_nro_recipientes => 2, p_motivo_declarado => 'Generador',
      p_fecha_hora => CAST(p_ts AS TIMESTAMP),
      p_id_transaccion => l_tx, p_nro_ticket => l_tk, p_estado => l_est);
    l_n := l_n + 1;
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_esc, 4) || TO_CHAR(p_ts, 'YYYY-MM-DD HH24:MI') || '  '
                         || RPAD(p_estacion, 20) || LPAD(p_cant, 5) || ' L  ' || RPAD(l_est, 10)
                         || NVL(pkg_transacciones.f_ultimas_alertas, '-') || ' (bidon)');
  END bidon;

  -- variables de escenario
  v01 NUMBER; v02 NUMBER; v03 NUMBER; v04 NUMBER; v05 NUMBER; v06 NUMBER; v10 NUMBER;
  v11 NUMBER; v12 NUMBER; v15 NUMBER; v131 NUMBER; v132 NUMBER; v133 NUMBER; v134 NUMBER;
  p01 NUMBER; p02 NUMBER; p03 NUMBER; p04 NUMBER; p05 NUMBER; p06 NUMBER; p07 NUMBER; p08 NUMBER;
  p10 NUMBER; p11 NUMBER; p12 NUMBER; p13 NUMBER; p15 NUMBER; px NUMBER;
BEGIN
  SELECT id_combustible   INTO l_gas  FROM combustible   WHERE nombre = 'Gasolina Especial';
  SELECT id_tipo_vehiculo INTO l_auto FROM tipo_vehiculo WHERE nombre = 'AUTO';
  SELECT id_tipo_vehiculo INTO l_moto FROM tipo_vehiculo WHERE nombre = 'MOTO';
  l_max    := pkg_reglas.f_id_regla_vigente('MAX_VEHICULOS_PERSONA', CAST(c_fin - 200 AS TIMESTAMP));
  l_semana := pkg_reglas.f_id_tipo_periodo('SEMANA');

  v01 := nuevo_vehiculo('DEM-001', l_auto, 'Toyota', 'Corolla 1.6', 1600, 50, p01);
  v02 := nuevo_vehiculo('DEM-002', l_auto, 'Toyota', 'Corolla 1.6', 1600, 50, p02);
  v03 := nuevo_vehiculo('DEM-003', l_moto, 'Yamaha', 'FZ 150',      150,  12, p03);
  v04 := nuevo_vehiculo('DEM-004', l_auto, 'Toyota', 'Corolla 1.6', 1600, 50, p04);
  v05 := nuevo_vehiculo('DEM-005', l_auto, 'Toyota', 'Corolla 1.6', 1600, 50, p05);
  v06 := nuevo_vehiculo('DEM-006', l_auto, 'Toyota', 'Corolla 1.6', 1600, 50, p06);
  v11 := nuevo_vehiculo('DEM-011', l_auto, 'Toyota', 'Hilux 2.7',   2700, 80, p11);
  v12 := nuevo_vehiculo('DEM-012', l_auto, 'Suzuki', 'Alto 1.0',    1000, 35, p12);
  v15 := nuevo_vehiculo('DEM-015', l_auto, 'Toyota', 'Corolla 1.6', 1600, 50, p15);
  v131 := nuevo_vehiculo('DEM-131', l_auto, 'Kia', 'Rio 1.4', 1400, 45, px);
  v132 := nuevo_vehiculo('DEM-132', l_auto, 'Kia', 'Rio 1.4', 1400, 45, px);
  v133 := nuevo_vehiculo('DEM-133', l_auto, 'Kia', 'Rio 1.4', 1400, 45, px);
  v134 := nuevo_vehiculo('DEM-134', l_auto, 'Kia', 'Rio 1.4', 1400, 45, px);
  p07 := nueva_persona('DEM-P007');
  p08 := nueva_persona('DEM-P008');
  p10 := nueva_persona('DEM-P010');
  p13 := nueva_persona('DEM-P013');
  INSERT INTO vehiculo (id_tipo_vehiculo, placa, pais_placa, fecha_registro)
    VALUES (l_auto, 'DEM-010', 'PER', c_fin - 30) RETURNING id_vehiculo INTO v10;
  INSERT INTO permiso_bidon (id_persona, id_combustible, id_tipo_periodo, nro_resolucion_anh, motivo,
                             cantidad_autorizada, fecha_emision, fecha_inicio, fecha_fin)
    VALUES (p08, l_gas, l_semana, 'ANH-RA-DEM-0008', 'Generador electrico', 100,
            c_fin - 60, c_fin - 60, c_fin + 300);

  DBMS_OUTPUT.PUT_LINE('Escenarios de demostracion (esc, fecha, estacion, litros, estado, reglas incumplidas):');
  -- D01 exceso de volumen: 45 + 45 L en el dia (umbral 80)
  carga('D01', 'EESS Heroinas', v01, p01, 45, c_fin - 3 + 8 / 24);
  carga('D01', 'EESS Heroinas', v01, p01, 45, c_fin - 3 + 15 / 24);
  -- D02 tres estaciones en el dia
  carga('D02', 'EESS Heroinas',    v02, p02, 15, c_fin - 4 + 8 / 24);
  carga('D02', 'EESS Quillacollo', v02, p02, 15, c_fin - 4 + 12 / 24);
  carga('D02', 'EESS Sacaba',      v02, p02, 15, c_fin - 4 + 17 / 24);
  -- D03 moto: cuatro cargas en el dia
  carga('D03', 'EESS Heroinas', v03, p03, 3, c_fin - 5 + 7 / 24);
  carga('D03', 'EESS Heroinas', v03, p03, 3, c_fin - 5 + 10 / 24);
  carga('D03', 'EESS Heroinas', v03, p03, 3, c_fin - 5 + 13 / 24);
  carga('D03', 'EESS Heroinas', v03, p03, 3, c_fin - 5 + 16 / 24);
  -- D04 60 L en tanque de 50: bloqueada
  carga('D04', 'EESS America', v04, p04, 60, c_fin - 6 + 9 / 24);
  -- D05 cuatro cargas de 30 L en 24 h con tanque de 50: la cuarta bloqueada
  carga('D05', 'EESS America', v05, p05, 30, c_fin - 7 + 0.5 / 24);
  carga('D05', 'EESS America', v05, p05, 30, c_fin - 7 + 5.5 / 24);
  carga('D05', 'EESS America', v05, p05, 30, c_fin - 7 + 10.5 / 24);
  carga('D05', 'EESS America', v05, p05, 30, c_fin - 7 + 15.5 / 24);
  -- D06 Cochabamba y 90 minutos despues en Desaguadero: bloqueada
  carga('D06', 'EESS Heroinas',    v06, p06, 20, c_fin - 8 + 8 / 24);
  carga('D06', 'EESS Desaguadero', v06, p06, 10, c_fin - 8 + 9.5 / 24);
  -- D07 bidon sin permiso: bloqueado
  bidon('D07', 'EESS Punata', p07, 20, c_fin - 9 + 10 / 24);
  -- D08 bidon que excede el permiso semanal de 100
  bidon('D08', 'EESS Punata', p08, 60, c_fin - 10 + 9 / 24);
  bidon('D08', 'EESS Punata', p08, 60, c_fin - 10 + 16 / 24);
  -- D10 extranjero: precio internacional, sin alerta
  carga('D10', 'EESS Heroinas', v10, p10, 30, c_fin - 2 + 11 / 24);
  -- D11 65 L en estacion fronteriza (umbral 60, ALTA): bloqueada
  carga('D11', 'EESS Yacuiba', v11, p11, 65, c_fin - 11 + 10 / 24);
  -- D12 auto de 1.000 cc: 25 L lunes, martes y miercoles (esperado 6 x 7 x 1.5 = 63)
  carga('D12', 'EESS Recoleta', v12, p12, 25, c_lun + 8 / 24);
  carga('D12', 'EESS Recoleta', v12, p12, 25, c_lun + 1 + 8 / 24);
  carga('D12', 'EESS Recoleta', v12, p12, 25, c_lun + 2 + 8 / 24);
  -- D13 una persona carga cuatro vehiculos ajenos en la semana
  carga('D13', 'EESS Blanco Galindo', v131, p13, 15, c_lun + 9 / 24);
  carga('D13', 'EESS Blanco Galindo', v132, p13, 15, c_lun + 1 + 9 / 24);
  carga('D13', 'EESS Blanco Galindo', v133, p13, 15, c_lun + 2 + 9 / 24);
  carga('D13', 'EESS Blanco Galindo', v134, p13, 15, c_lun + 3 + 9 / 24);
  -- D15 cuota del departamento de Pando (30 L)
  carga('D15', 'EESS Cobija', v15, p15, 35, c_fin - 1 + 10 / 24);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Escenarios: ' || l_n || ' operaciones');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/

-- ============================================================
-- C. RECLAMOS DE CALIDAD (un lote adulterado y reclamos dispersos)
-- ============================================================
DECLARE
  c_fin    CONSTANT DATE := TRUNC(SYSDATE);
  c_inicio CONSTANT DATE := TRUNC(SYSDATE) - 182;
  l_rec    NUMBER; l_est NUMBER; l_comb NUMBER; l_fecha TIMESTAMP;
  l_per    NUMBER;
  l_ts     TIMESTAMP;
  l_tipo   VARCHAR2(20);
  l_estado VARCHAR2(12);
  l_res    VARCHAR2(12);
  l_desc   VARCHAR2(400);
  l_r      NUMBER;
  l_n      PLS_INTEGER := 0;
  TYPE t_n IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  l_pers   t_n;

  FUNCTION persona_al_azar RETURN NUMBER IS
  BEGIN
    RETURN l_pers(1 + TRUNC(DBMS_RANDOM.VALUE(0, l_pers.COUNT)));
  END persona_al_azar;
BEGIN
  DBMS_RANDOM.SEED(43);
  SELECT id_persona BULK COLLECT INTO l_pers FROM persona WHERE nro_documento NOT LIKE 'DEM%' ORDER BY id_persona;

  -- Lote adulterado: la primera recepcion de gasolina de EESS America despues del
  -- dia 60 (si no hubiera, la primera de gasolina de cualquier estacion)
  SELECT id_recepcion, id_estacion, id_combustible, fecha_hora
    INTO l_rec, l_est, l_comb, l_fecha
    FROM (SELECT r.id_recepcion, r.id_estacion, r.id_combustible, r.fecha_hora
            FROM recepcion_combustible r
            JOIN estacion e    ON e.id_estacion    = r.id_estacion
            JOIN combustible c ON c.id_combustible = r.id_combustible
           WHERE c.nombre = 'Gasolina Especial'
             AND r.fecha_hora >= c_inicio + 60
           ORDER BY CASE WHEN e.nombre = 'EESS America' THEN 0 ELSE 1 END, r.fecha_hora)
   WHERE ROWNUM = 1;
  FOR i IN 1 .. 50 LOOP
    l_ts     := l_fecha + NUMTODSINTERVAL(DBMS_RANDOM.VALUE(0.2, 14), 'DAY');
    l_estado := CASE WHEN CAST(l_ts AS DATE) < c_fin - 20 THEN 'CERRADO' ELSE 'EN_ANALISIS' END;
    l_res    := CASE WHEN l_estado = 'CERRADO' THEN 'CONFIRMADO' END;
    l_per    := persona_al_azar;
    l_desc   := CASE MOD(i, 3) WHEN 0 THEN 'Motor falla despues de cargar'
                               WHEN 1 THEN 'Combustible con color y olor extrano'
                               ELSE 'Perdida de potencia y humo negro' END;
    INSERT INTO reclamo_calidad (id_estacion, id_combustible, id_recepcion, id_persona, fecha_hora,
                                 tipo_reclamo, descripcion, estado, resultado)
      VALUES (l_est, l_comb, l_rec, l_per, l_ts, 'ADULTERACION', l_desc, l_estado, l_res);
    l_n := l_n + 1;
  END LOOP;

  -- Reclamos dispersos en todas las estaciones
  FOR i IN 1 .. 100 LOOP
    SELECT id_estacion, id_combustible INTO l_est, l_comb
      FROM (SELECT id_estacion, id_combustible FROM tanque_estacion
             WHERE id_combustible IN (SELECT id_combustible FROM combustible
                                       WHERE nombre IN ('Gasolina Especial', 'Diesel Oil'))
             ORDER BY DBMS_RANDOM.VALUE)
     WHERE ROWNUM = 1;
    l_ts := CAST(c_inicio AS TIMESTAMP) + NUMTODSINTERVAL(DBMS_RANDOM.VALUE(1, 181), 'DAY');
    l_rec := NULL;
    IF DBMS_RANDOM.VALUE < 0.7 THEN
      SELECT MAX(id_recepcion) INTO l_rec
        FROM recepcion_combustible
       WHERE id_estacion = l_est AND id_combustible = l_comb AND fecha_hora <= l_ts;
    END IF;
    l_r    := DBMS_RANDOM.VALUE;
    l_tipo := CASE WHEN l_r < 0.40 THEN 'VOLUMEN_INCOMPLETO' WHEN l_r < 0.55 THEN 'CONTAMINACION'
                   WHEN l_r < 0.70 THEN 'ADULTERACION' ELSE 'OTRO' END;
    IF CAST(l_ts AS DATE) < c_fin - 30 THEN
      l_estado := 'CERRADO';
      l_res    := CASE WHEN DBMS_RANDOM.VALUE < 0.2 THEN 'CONFIRMADO' ELSE 'DESCARTADO' END;
    ELSE
      l_estado := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN 'ABIERTO' ELSE 'EN_ANALISIS' END;
      l_res    := NULL;
    END IF;
    l_per  := persona_al_azar;
    l_desc := CASE l_tipo WHEN 'VOLUMEN_INCOMPLETO' THEN 'El surtidor despacho menos de lo cobrado'
                          WHEN 'CONTAMINACION' THEN 'Agua o sedimentos en el combustible'
                          WHEN 'ADULTERACION' THEN 'Sospecha de mezcla con otro producto'
                          ELSE 'Atencion o funcionamiento del surtidor' END;
    INSERT INTO reclamo_calidad (id_estacion, id_combustible, id_recepcion, id_persona, fecha_hora,
                                 tipo_reclamo, descripcion, estado, resultado)
      VALUES (l_est, l_comb, l_rec, l_per, l_ts, l_tipo, l_desc, l_estado, l_res);
    l_n := l_n + 1;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Reclamos de calidad: ' || l_n);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/

-- ============================================================
-- D. CONCILIACION YPFB Y REVISION DE ALERTAS
-- Se revisan ~60 % de las alertas con mas de 7 dias. Probabilidad de
-- falso positivo segun gravedad: BAJA 70 %, MEDIA 35 %, ALTA 8 %.
-- ============================================================
DECLARE
  c_fin    CONSTANT DATE := TRUNC(SYSDATE);
  c_inicio CONSTANT DATE := TRUNC(SYSDATE) - 182;
  TYPE t_n IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  l_fisc   t_n;
  l_nuevas NUMBER;
  l_res    VARCHAR2(20);
  l_ts     TIMESTAMP;
  l_n      PLS_INTEGER := 0;
  l_obs    VARCHAR2(400);
BEGIN
  DBMS_RANDOM.SEED(44);
  pkg_deteccion.p_conciliar_todas(c_inicio, c_fin, l_nuevas);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Conciliacion YPFB: ' || l_nuevas || ' alertas de estacion');

  SELECT id_usuario BULK COLLECT INTO l_fisc FROM usuario_app WHERE rol = 'FISCALIZADOR' ORDER BY id_usuario;
  FOR a IN (SELECT a.id_alerta, a.fecha_deteccion, r.gravedad
              FROM alerta a JOIN regla r ON r.id_regla = a.id_regla
             WHERE a.estado_revision = 'PENDIENTE'
               AND a.fecha_deteccion < CAST(c_fin - 7 AS TIMESTAMP)
             ORDER BY a.id_alerta) LOOP
    IF DBMS_RANDOM.VALUE < 0.6 THEN
      l_res := CASE WHEN DBMS_RANDOM.VALUE < CASE a.gravedad WHEN 'BAJA' THEN 0.70 WHEN 'MEDIA' THEN 0.35 ELSE 0.08 END
                    THEN 'FALSO_POSITIVO' ELSE 'CONFIRMADA' END;
      l_obs := CASE l_res WHEN 'FALSO_POSITIVO' THEN 'Uso justificado (servicio publico o viaje)'
                          ELSE 'Comportamiento irregular verificado' END;
      l_ts  := LEAST(a.fecha_deteccion + NUMTODSINTERVAL(DBMS_RANDOM.VALUE(0.5, 6), 'DAY'),
                     CAST(c_fin AS TIMESTAMP) - NUMTODSINTERVAL(1, 'HOUR'));
      pkg_deteccion.p_revisar_alerta(a.id_alerta, l_res, l_fisc(1 + MOD(l_n, l_fisc.COUNT)), l_obs, l_ts);
      l_n := l_n + 1;
      IF MOD(l_n, 2000) = 0 THEN
        COMMIT;
      END IF;
    END IF;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Alertas revisadas: ' || l_n);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/

-- ============================================================
-- E. VISTAS MATERIALIZADAS Y ESTADISTICAS DEL OPTIMIZADOR
-- ============================================================
BEGIN
  pkg_analisis.p_refrescar_vistas_materializadas;
  DBMS_STATS.GATHER_SCHEMA_STATS(ownname => SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'), cascade => TRUE);
  DBMS_OUTPUT.PUT_LINE('Vistas materializadas refrescadas y estadisticas recolectadas');
END;
/

-- ============================================================
-- F. VERIFICACION: minimos del enunciado, cobertura de reglas e invariantes
-- ============================================================
DECLARE
  c_fin CONSTANT DATE := TRUNC(SYSDATE);
  l_n   NUMBER;
  l_falla VARCHAR2(4000);

  PROCEDURE minimo(p_nombre IN VARCHAR2, p_valor IN NUMBER, p_minimo IN NUMBER) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_nombre, 36) || LPAD(p_valor, 8) || '  (minimo ' || p_minimo || ')');
    IF p_valor < p_minimo THEN
      l_falla := l_falla || p_nombre || '; ';
    END IF;
  END minimo;
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Volumen ---');
  SELECT COUNT(*) INTO l_n FROM persona;      minimo('Personas (usuarios del sistema)', l_n, 1000);
  SELECT COUNT(*) INTO l_n FROM vehiculo;     minimo('Vehiculos', l_n, 1500);
  SELECT COUNT(*) INTO l_n FROM estacion;     minimo('Estaciones de servicio', l_n, 20);
  SELECT COUNT(*) INTO l_n FROM transaccion;  minimo('Operaciones de abastecimiento', l_n, 50000);
  SELECT COUNT(*) INTO l_n FROM transaccion WHERE estado = 'BLOQUEADA'; minimo('  de ellas bloqueadas', l_n, 1);
  SELECT TRUNC(CAST(MAX(fecha_hora) AS DATE) - CAST(MIN(fecha_hora) AS DATE)) INTO l_n FROM transaccion;
  minimo('Dias de historial', l_n, 180);
  SELECT COUNT(*) INTO l_n FROM recepcion_combustible; minimo('Recepciones YPFB (despachos)', l_n, 1);
  SELECT COUNT(*) INTO l_n FROM alerta;       minimo('Alertas', l_n, 1);
  SELECT COUNT(*) INTO l_n FROM alerta WHERE estado_revision = 'REVISADA'; minimo('  revisadas', l_n, 1);
  SELECT COUNT(*) INTO l_n FROM reclamo_calidad; minimo('Reclamos de calidad', l_n, 1);
  SELECT COUNT(*) INTO l_n FROM usuario_app;  minimo('Usuarios de la aplicacion', l_n, 1);
  SELECT COUNT(DISTINCT f.cilindrada) INTO l_n FROM ficha_aduana f; minimo('Cilindradas distintas', l_n, 5);
  SELECT COUNT(DISTINCT f.marca || f.modelo) INTO l_n FROM ficha_aduana f; minimo('Modelos distintos', l_n, 10);
  SELECT COUNT(DISTINCT f.capacidad_tanque) INTO l_n FROM ficha_aduana f; minimo('Capacidades de tanque', l_n, 5);
  SELECT COUNT(*) INTO l_n FROM (SELECT id_persona FROM registro_ruat WHERE fecha_baja IS NULL
                                  GROUP BY id_persona HAVING COUNT(*) > 1);
  minimo('Propietarios con varios vehiculos', l_n, 1);
  SELECT COUNT(*) INTO l_n FROM mv_ventas_estacion_dia; minimo('Filas en mv_ventas_estacion_dia', l_n, 1);
  SELECT COUNT(*) INTO l_n FROM v_consumo_vehiculo_dia WHERE dia >= c_fin - 30; minimo('Consumos en los ultimos 30 dias', l_n, 1);

  DBMS_OUTPUT.PUT_LINE('--- Alertas por regla (todas las reglas de anomalia deben aparecer) ---');
  FOR r IN (SELECT tr.codigo, COUNT(a.id_alerta) AS n,
                   SUM(CASE WHEN t.estado = 'BLOQUEADA' THEN 1 ELSE 0 END) AS bloq
              FROM tipo_regla tr
              LEFT JOIN regla r       ON r.id_tipo_regla = tr.id_tipo_regla
              LEFT JOIN alerta a      ON a.id_regla = r.id_regla
              LEFT JOIN transaccion t ON t.id_transaccion = a.id_transaccion
             WHERE tr.familia = 'ANOMALIA'
             GROUP BY tr.codigo ORDER BY tr.codigo) LOOP
    DBMS_OUTPUT.PUT_LINE(RPAD(r.codigo, 28) || LPAD(r.n, 8) || ' alertas, ' || r.bloq || ' en operaciones bloqueadas');
    IF r.n = 0 THEN
      l_falla := l_falla || 'sin alertas ' || r.codigo || '; ';
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('--- Invariantes (deben ser 0) ---');
  SELECT COUNT(*) INTO l_n FROM transaccion t
   WHERE t.estado = 'APROBADA'
     AND t.cantidad_total <> (SELECT NVL(SUM(d.cantidad), 0) FROM detalle_transaccion d
                               WHERE d.id_transaccion = t.id_transaccion);
  DBMS_OUTPUT.PUT_LINE('I1 aprobadas que no suman su detalle      ' || l_n);
  IF l_n > 0 THEN l_falla := l_falla || 'I1; '; END IF;
  SELECT COUNT(*) INTO l_n FROM transaccion t
   WHERE t.estado = 'BLOQUEADA' AND EXISTS (SELECT 1 FROM detalle_transaccion d WHERE d.id_transaccion = t.id_transaccion);
  DBMS_OUTPUT.PUT_LINE('I2 bloqueadas con detalle                 ' || l_n);
  IF l_n > 0 THEN l_falla := l_falla || 'I2; '; END IF;
  SELECT COUNT(*) INTO l_n FROM transaccion t
   WHERE t.estado = 'BLOQUEADA'
     AND NOT EXISTS (SELECT 1 FROM alerta a JOIN regla r ON r.id_regla = a.id_regla
                       JOIN tipo_regla tr ON tr.id_tipo_regla = r.id_tipo_regla
                      WHERE a.id_transaccion = t.id_transaccion
                        AND tr.familia = 'ANOMALIA' AND tr.evaluacion = 'TRANSACCION' AND r.gravedad = 'ALTA');
  DBMS_OUTPUT.PUT_LINE('I7 bloqueadas sin alerta bloqueante       ' || l_n);
  IF l_n > 0 THEN l_falla := l_falla || 'I7; '; END IF;
  SELECT COUNT(*) INTO l_n FROM transaccion t
   WHERE t.estado = 'APROBADA'
     AND EXISTS (SELECT 1 FROM alerta a JOIN regla r ON r.id_regla = a.id_regla
                   JOIN tipo_regla tr ON tr.id_tipo_regla = r.id_tipo_regla
                  WHERE a.id_transaccion = t.id_transaccion
                    AND tr.familia = 'ANOMALIA' AND tr.evaluacion = 'TRANSACCION' AND r.gravedad = 'ALTA');
  DBMS_OUTPUT.PUT_LINE('I8 aprobadas con alerta bloqueante        ' || l_n);
  IF l_n > 0 THEN l_falla := l_falla || 'I8; '; END IF;
  SELECT COUNT(*) INTO l_n FROM transaccion t
   WHERE t.estado = 'APROBADA' AND NOT EXISTS (SELECT 1 FROM detalle_transaccion d WHERE d.id_transaccion = t.id_transaccion);
  DBMS_OUTPUT.PUT_LINE('I9 aprobadas sin detalle                  ' || l_n);
  IF l_n > 0 THEN l_falla := l_falla || 'I9; '; END IF;

  IF l_falla IS NOT NULL THEN
    RAISE_APPLICATION_ERROR(-20999, '11_datos_simulados: ' || SUBSTR(l_falla, 1, 3000));
  END IF;
  DBMS_OUTPUT.PUT_LINE('OK    datos simulados completos y coherentes');
END;
/
