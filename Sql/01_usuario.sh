#!/bin/bash
# ============================================================
# 01_usuario.sh
# Crea el tablespace y el usuario duenio del esquema "combustible"
# dentro del PDB FREEPDB1.
# Es .sh (y no .sql) para leer la contrasenia desde la variable de
# entorno COMBUSTIBLE_PWD (archivo .env, que NO se sube a git).
# El contenedor lo ejecuta con "source", como usuario oracle, solo la
# primera vez (volumen vacio), antes que los .sql (orden alfabetico).
# Los usuarios de aplicacion, auditor, etc. y el perfil de contrasenias
# se crean en el script de seguridad.
# ============================================================

if [ -z "${COMBUSTIBLE_PWD:-}" ]; then
  echo "[ERROR] 01_usuario.sh: falta la variable COMBUSTIBLE_PWD (ver .env.example)"
  return 1 2>/dev/null || exit 1
fi

# Carpeta para exportaciones Data Pump (dentro del volumen persistente)
mkdir -p /opt/oracle/oradata/backup

"$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET SERVEROUTPUT ON
ALTER SESSION SET CONTAINER = FREEPDB1;

-- Tablespace propio del proyecto, en la misma carpeta que USERS
DECLARE
  l_dir VARCHAR2(512);
BEGIN
  SELECT SUBSTR(file_name, 1, INSTR(file_name, '/', -1))
    INTO l_dir
    FROM dba_data_files
   WHERE tablespace_name = 'USERS'
     AND ROWNUM = 1;
  EXECUTE IMMEDIATE 'CREATE TABLESPACE tbs_combustible DATAFILE ''' || l_dir ||
                    'tbs_combustible01.dbf'' SIZE 256M AUTOEXTEND ON NEXT 64M MAXSIZE 6G';
  DBMS_OUTPUT.PUT_LINE('Tablespace tbs_combustible creado en ' || l_dir);
END;
/

-- Duenio del esquema: solo crea objetos (no lo usa la aplicacion)
CREATE USER combustible IDENTIFIED BY "${COMBUSTIBLE_PWD}"
  DEFAULT TABLESPACE tbs_combustible
  QUOTA UNLIMITED ON tbs_combustible;

GRANT CREATE SESSION,
      CREATE TABLE,
      CREATE VIEW,
      CREATE MATERIALIZED VIEW,
      CREATE SEQUENCE,
      CREATE PROCEDURE,
      CREATE TRIGGER,
      CREATE TYPE,
      CREATE JOB TO combustible;

-- Hash de contrasenias de usuario_app (SHA-512)
GRANT EXECUTE ON SYS.DBMS_CRYPTO TO combustible;

-- Directorio para Data Pump (respaldo y recuperacion)
CREATE OR REPLACE DIRECTORY dir_backup AS '/opt/oracle/oradata/backup';

BEGIN
  DBMS_OUTPUT.PUT_LINE('Usuario combustible creado');
END;
/
EXIT
EOF
