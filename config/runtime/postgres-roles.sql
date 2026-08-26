\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity_owner') THEN
    CREATE ROLE identity_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity_migrator') THEN
    CREATE ROLE identity_migrator LOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity_runtime') THEN
    CREATE ROLE identity_runtime LOGIN NOINHERIT;
  END IF;
END
$$;

CREATE TEMP TABLE identity_migrator_password(value text);
CREATE TEMP TABLE identity_runtime_password(value text);
COPY identity_migrator_password FROM '/run/secrets/database/migrator_password';
COPY identity_runtime_password FROM '/run/secrets/database/runtime_password';
SELECT format('ALTER ROLE identity_migrator PASSWORD %L', value) FROM identity_migrator_password \gexec
SELECT format('ALTER ROLE identity_runtime PASSWORD %L', value) FROM identity_runtime_password \gexec

GRANT identity_owner TO identity_migrator;
ALTER DATABASE identity OWNER TO identity_owner;
REVOKE ALL ON DATABASE identity FROM PUBLIC;
GRANT CONNECT ON DATABASE identity TO identity_migrator, identity_runtime;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO identity_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE identity_owner IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE identity_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO identity_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE identity_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO identity_runtime;
