\set ON_ERROR_STOP on

\if :{?IDENTITY_POST_MIGRATION_AUDIT}

DO $$
DECLARE
  table_grants text[];
  update_columns text[];
BEGIN
  IF (SELECT version_num FROM identity.alembic_version) <> '0001_initial_identity_schema' THEN
    RAISE EXCEPTION 'identity migration head contract mismatch';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'identity_service_owner'
      AND (rolcanlogin OR rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
  ) OR EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'identity_service_migrator'
      AND (NOT rolcanlogin OR NOT rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
  ) OR EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'identity_service_app'
      AND (NOT rolcanlogin OR rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
  ) THEN
    RAISE EXCEPTION 'identity role attribute contract mismatch';
  END IF;

  IF (SELECT count(*) FROM pg_auth_members membership
      JOIN pg_roles granted ON granted.oid = membership.roleid
      JOIN pg_roles member ON member.oid = membership.member
      WHERE granted.rolname IN ('identity_service_owner', 'identity_service_migrator', 'identity_service_app')
         OR member.rolname IN ('identity_service_owner', 'identity_service_migrator', 'identity_service_app')) <> 1
    OR EXISTS (
      SELECT 1 FROM pg_auth_members membership
      JOIN pg_roles granted ON granted.oid = membership.roleid
      JOIN pg_roles member ON member.oid = membership.member
      WHERE (granted.rolname IN ('identity_service_owner', 'identity_service_migrator', 'identity_service_app')
          OR member.rolname IN ('identity_service_owner', 'identity_service_migrator', 'identity_service_app'))
        AND NOT (
          granted.rolname = 'identity_service_owner'
          AND member.rolname = 'identity_service_migrator'
          AND NOT membership.admin_option
          AND membership.inherit_option
          AND membership.set_option
        )
    ) THEN
    RAISE EXCEPTION 'identity role membership contract mismatch';
  END IF;

  IF (SELECT schema_owner FROM information_schema.schemata WHERE schema_name = 'identity') <> 'identity_service_owner'
    OR has_database_privilege('public', current_database(), 'CONNECT')
    OR has_database_privilege('public', current_database(), 'CREATE')
    OR has_database_privilege('public', current_database(), 'TEMP')
    OR has_schema_privilege('public', 'public', 'USAGE')
    OR has_schema_privilege('public', 'public', 'CREATE')
    OR has_schema_privilege('public', 'identity', 'USAGE')
    OR has_schema_privilege('public', 'identity', 'CREATE') THEN
    RAISE EXCEPTION 'identity ownership or public privilege contract mismatch';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_class WHERE relowner = 'identity_service_app'::regrole)
    OR EXISTS (SELECT 1 FROM pg_namespace WHERE nspowner = 'identity_service_app'::regrole)
    OR EXISTS (SELECT 1 FROM pg_proc WHERE proowner = 'identity_service_app'::regrole)
    OR EXISTS (SELECT 1 FROM pg_type WHERE typowner = 'identity_service_app'::regrole)
    OR EXISTS (SELECT 1 FROM pg_database WHERE datdba = 'identity_service_app'::regrole) THEN
    RAISE EXCEPTION 'identity runtime role ownership contract mismatch';
  END IF;

  IF (SELECT array_agg(table_name::text ORDER BY table_name) FROM information_schema.tables
      WHERE table_schema = 'identity' AND table_type = 'BASE TABLE')
      IS DISTINCT FROM ARRAY['alembic_version', 'profiles', 'provider_identities', 'users']::text[]
    OR EXISTS (SELECT 1 FROM information_schema.sequences WHERE sequence_schema = 'identity') THEN
    RAISE EXCEPTION 'identity current-head object inventory mismatch';
  END IF;

  SELECT array_agg(table_name::text || ':' || privilege_type::text ORDER BY table_name, privilege_type)
    INTO table_grants
    FROM information_schema.role_table_grants
    WHERE grantee = 'identity_service_app';
  IF table_grants IS DISTINCT FROM ARRAY[
    'alembic_version:SELECT',
    'profiles:INSERT', 'profiles:SELECT',
    'provider_identities:INSERT', 'provider_identities:SELECT',
    'users:INSERT', 'users:SELECT'
  ]::text[] THEN
    RAISE EXCEPTION 'identity runtime table privilege contract mismatch';
  END IF;

  SELECT array_agg(table_name::text || '.' || column_name::text ORDER BY table_name, column_name)
    INTO update_columns
    FROM information_schema.role_column_grants
    WHERE grantee = 'identity_service_app' AND privilege_type = 'UPDATE';
  IF update_columns IS DISTINCT FROM ARRAY[
    'profiles.display_name_override', 'profiles.provider_avatar_url',
    'profiles.provider_display_name', 'profiles.provider_email',
    'profiles.provider_email_verified', 'profiles.updated_at', 'profiles.version',
    'provider_identities.claims_synced_at', 'provider_identities.last_auth_time',
    'provider_identities.last_seen_at'
  ]::text[] THEN
    RAISE EXCEPTION 'identity runtime column privilege contract mismatch';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE grantee = 'identity_service_app' AND table_schema <> 'identity')
    OR EXISTS (SELECT 1 FROM information_schema.role_usage_grants WHERE grantee = 'identity_service_app')
    OR EXISTS (SELECT 1 FROM information_schema.role_routine_grants WHERE grantee = 'identity_service_app')
    OR has_schema_privilege('identity_service_app', 'identity', 'CREATE')
    OR NOT has_schema_privilege('identity_service_app', 'identity', 'USAGE') THEN
    RAISE EXCEPTION 'identity runtime extra privilege contract mismatch';
  END IF;
END
$$;

\else

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity_service_owner') THEN
    CREATE ROLE identity_service_owner NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  ELSIF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'identity_service_owner'
    AND (rolcanlogin OR rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'identity owner role drift';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity_service_migrator') THEN
    CREATE ROLE identity_service_migrator LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  ELSIF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'identity_service_migrator'
    AND (NOT rolcanlogin OR NOT rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'identity migrator role drift';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity_service_app') THEN
    CREATE ROLE identity_service_app LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  ELSIF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'identity_service_app'
    AND (NOT rolcanlogin OR rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'identity application role drift';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_auth_members membership
    JOIN pg_roles granted ON granted.oid = membership.roleid
    JOIN pg_roles member ON member.oid = membership.member
    WHERE (granted.rolname IN ('identity_service_owner', 'identity_service_migrator', 'identity_service_app')
        OR member.rolname IN ('identity_service_owner', 'identity_service_migrator', 'identity_service_app'))
      AND NOT (
        granted.rolname = 'identity_service_owner'
        AND member.rolname = 'identity_service_migrator'
        AND NOT membership.admin_option
        AND membership.inherit_option
        AND membership.set_option
      )
  ) THEN
    RAISE EXCEPTION 'identity role membership drift';
  END IF;
END
$$;

CREATE TEMP TABLE identity_service_migrator_password(value text);
CREATE TEMP TABLE identity_service_app_password(value text);
\copy identity_service_migrator_password FROM '/run/secrets/database/migrator_password'
\copy identity_service_app_password FROM '/run/secrets/database/runtime_password'
SELECT format('ALTER ROLE identity_service_migrator PASSWORD %L', value) FROM identity_service_migrator_password \gexec
SELECT format('ALTER ROLE identity_service_app PASSWORD %L', value) FROM identity_service_app_password \gexec

GRANT identity_service_owner TO identity_service_migrator WITH ADMIN FALSE, INHERIT TRUE, SET TRUE;
REVOKE ALL ON DATABASE identity FROM PUBLIC;
GRANT CONNECT ON DATABASE identity TO identity_service_migrator, identity_service_app;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA IF NOT EXISTS identity AUTHORIZATION identity_service_owner;

DO $$
BEGIN
  IF (SELECT schema_owner FROM information_schema.schemata WHERE schema_name = 'identity') <> 'identity_service_owner' THEN
    RAISE EXCEPTION 'identity schema ownership drift';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class WHERE relowner = 'identity_service_app'::regrole)
    OR EXISTS (SELECT 1 FROM pg_namespace WHERE nspowner = 'identity_service_app'::regrole)
    OR EXISTS (SELECT 1 FROM pg_proc WHERE proowner = 'identity_service_app'::regrole)
    OR EXISTS (SELECT 1 FROM pg_type WHERE typowner = 'identity_service_app'::regrole) THEN
    RAISE EXCEPTION 'identity application ownership drift';
  END IF;
END
$$;

REVOKE ALL ON SCHEMA identity FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA identity TO identity_service_migrator;
GRANT USAGE ON SCHEMA identity TO identity_service_app;

\endif
