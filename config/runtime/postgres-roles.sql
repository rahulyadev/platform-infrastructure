\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity_service_owner') THEN
    CREATE ROLE identity_service_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity_service_migrator') THEN
    CREATE ROLE identity_service_migrator LOGIN INHERIT;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity_service_app') THEN
    CREATE ROLE identity_service_app LOGIN NOINHERIT;
  END IF;
END
$$;

CREATE TEMP TABLE identity_service_migrator_password(value text);
CREATE TEMP TABLE identity_service_app_password(value text);
\copy identity_service_migrator_password FROM '/run/secrets/database/migrator_password'
\copy identity_service_app_password FROM '/run/secrets/database/runtime_password'
SELECT format('ALTER ROLE identity_service_migrator PASSWORD %L', value) FROM identity_service_migrator_password \gexec
SELECT format('ALTER ROLE identity_service_app PASSWORD %L', value) FROM identity_service_app_password \gexec

GRANT identity_service_owner TO identity_service_migrator;
REVOKE ALL ON DATABASE identity FROM PUBLIC;
GRANT CONNECT ON DATABASE identity TO identity_service_migrator, identity_service_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA IF NOT EXISTS identity AUTHORIZATION identity_service_owner;
REVOKE ALL ON SCHEMA identity FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA identity TO identity_service_migrator;
GRANT USAGE ON SCHEMA identity TO identity_service_app;
