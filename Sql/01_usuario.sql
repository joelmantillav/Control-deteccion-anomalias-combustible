-- ============================================================
-- 01_usuario.sql
-- Crea el esquema "combustible" dentro del PDB FREEPDB1
-- (se ejecuta como SYS al crear la base por primera vez)
-- ============================================================
ALTER SESSION SET CONTAINER = FREEPDB1;

CREATE USER combustible IDENTIFIED BY "combustible123"
  DEFAULT TABLESPACE users
  QUOTA UNLIMITED ON users;

GRANT CREATE SESSION,
      CREATE TABLE,
      CREATE VIEW,
      CREATE SEQUENCE,
      CREATE PROCEDURE,
      CREATE TRIGGER,
      CREATE TYPE,
      CREATE SYNONYM TO combustible;
