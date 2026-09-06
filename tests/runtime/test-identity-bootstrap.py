#!/usr/bin/env python3
import copy
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
compose = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))

postgres_image = "postgres@sha256:a02db8cac496f15b094798a38254f14d6e00741f709360e5e00bb6668ea31636"
connection = "host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt"

def mounts(service):
    result = {}
    for volume in service.get("volumes", []):
        target = volume.get("target")
        if target in result:
            raise AssertionError("duplicate client mount")
        result[target] = (volume.get("source"), volume.get("read_only"), volume.get("type"))
    return result

def validate(value):
    services = value["services"]
    if set(services) != {"postgres", "postgres-admin", "postgres-bootstrap", "pgbackrest", "redis", "migrator", "api", "bff"}:
        raise AssertionError("service inventory")
    if value["networks"]["state"].get("internal") is not True:
        raise AssertionError("state network")
    server_mounts = mounts(services["postgres"])
    for forbidden in ("/run/secrets/database/migrator_password", "/run/secrets/database/runtime_password"):
        if forbidden in server_mounts:
            raise AssertionError("server credential isolation")
    expected = {
        "postgres-admin": {
            "/run/secrets/database/bootstrap.pgpass",
            "/run/tls/postgres/ca.crt",
        },
        "postgres-bootstrap": {
            "/run/secrets/database/bootstrap.pgpass",
            "/run/secrets/database/migrator_password",
            "/run/secrets/database/runtime_password",
            "/run/tls/postgres/ca.crt",
        },
    }
    for name, expected_targets in expected.items():
        service = services[name]
        if service.get("image") != postgres_image or service.get("platform") != "linux/arm64/v8":
            raise AssertionError(name + " image")
        if service.get("user") != "10001:10001" or service.get("read_only") is not True:
            raise AssertionError(name + " identity")
        if service.get("restart") != "no" or service.get("cap_drop") != ["ALL"]:
            raise AssertionError(name + " lifetime")
        if service.get("security_opt") != ["no-new-privileges:true"]:
            raise AssertionError(name + " security")
        if service.get("profiles") != ["administration"] or service.get("networks") != {"state": None}:
            raise AssertionError(name + " scope")
        if service.get("entrypoint") != ["psql"]:
            raise AssertionError(name + " entrypoint")
        if service.get("environment") != {"PGPASSFILE": "/run/secrets/database/bootstrap.pgpass"}:
            raise AssertionError(name + " pgpass")
        observed_mounts = mounts(service)
        if set(observed_mounts) != expected_targets:
            raise AssertionError(name + " mounts")
        if any(read_only is not True or kind != "bind" for _, read_only, kind in observed_mounts.values()):
            raise AssertionError(name + " mount mode")
    pgbackrest = services["pgbackrest"]
    if pgbackrest.get("environment") != {"PGBACKREST_CONFIG": "/etc/pgbackrest.conf"}:
        raise AssertionError("pgbackrest config selection")
    pgbackrest_mounts = mounts(pgbackrest)
    if pgbackrest_mounts.get("/etc/pgbackrest.conf") != (
        "/etc/platform/identity/pgbackrest.conf", True, "bind"
    ) or "/etc/pgbackrest/pgbackrest.conf" in pgbackrest_mounts:
        raise AssertionError("pgbackrest traversable config mount")
    if pgbackrest_mounts.get("/var/lib/postgresql/18/docker/pg_wal/platform-spool") != (
        "identity_wal_spool", None, "volume"
    ):
        raise AssertionError("pgbackrest nested archive input")
    if pgbackrest.get("healthcheck", {}).get("test") != [
        "CMD", "/opt/platform/pgbackrest-sidecar", "--stanza=identity", "check"
    ]:
        raise AssertionError("pgbackrest wrapped health check")
    if services["migrator"].get("profiles") != ["migration"] or services["migrator"].get("restart") != "no":
        raise AssertionError("one-shot migrator profile")

validate(compose)
mutations = []
for name, operation in (
    ("bootstrap-missing-runtime", lambda value: value["services"]["postgres-bootstrap"]["volumes"].pop()),
    ("admin-extra-secret", lambda value: value["services"]["postgres-admin"]["volumes"].append(copy.deepcopy(value["services"]["postgres-bootstrap"]["volumes"][1]))),
    ("server-secret-leak", lambda value: value["services"]["postgres"]["volumes"].append(copy.deepcopy(value["services"]["postgres-bootstrap"]["volumes"][1]))),
    ("wrong-uid", lambda value: value["services"]["postgres-admin"].__setitem__("user", "0:0")),
    ("writable-root", lambda value: value["services"]["postgres-admin"].__setitem__("read_only", False)),
    ("capability", lambda value: value["services"]["postgres-admin"].__setitem__("cap_drop", [])),
    ("restart", lambda value: value["services"]["postgres-admin"].__setitem__("restart", "always")),
    ("public-network", lambda value: value["networks"]["state"].__setitem__("internal", False)),
    ("pgbackrest-default-config", lambda value: value["services"]["pgbackrest"].__setitem__("environment", {})),
    ("pgbackrest-direct-health", lambda value: value["services"]["pgbackrest"]["healthcheck"].__setitem__("test", ["CMD", "pgbackrest", "--stanza=identity", "check"])),
    ("pgbackrest-missing-nested-spool", lambda value: value["services"]["pgbackrest"].__setitem__("volumes", [item for item in value["services"]["pgbackrest"]["volumes"] if item.get("target") != "/var/lib/postgresql/18/docker/pg_wal/platform-spool"])),
    ("migrator-default-profile", lambda value: value["services"]["migrator"].pop("profiles")),
):
    candidate = copy.deepcopy(compose)
    operation(candidate)
    try:
        validate(candidate)
    except AssertionError:
        mutations.append(name)
    else:
        raise SystemExit("Identity PostgreSQL client mutation was accepted: " + name)
if len(mutations) != 12:
    raise SystemExit("Identity PostgreSQL client mutation count drifted.")

scripts = {
    name: (root / "deploy/ssm" / name).read_text(encoding="utf-8")
    for name in (
        "deploy-identity.sh", "backup-identity.sh", "verify-identity.sh",
        "rollback-identity.sh", "restore-identity.sh",
    )
}
pgbackrest_sidecar = (root / "config/runtime/pgbackrest-sidecar.sh").read_text(encoding="utf-8")

def validate_scripts(value):
    deploy = value["deploy-identity.sh"]
    if deploy.count("run_postgres_client postgres-bootstrap") != 1:
        raise AssertionError("bootstrap client call")
    if deploy.count("run_postgres_client postgres-admin") != 3:
        raise AssertionError("deployment admin calls")
    nginx_target = 'readonly nginx_configuration="$(rooted /etc/nginx/conf.d/portfolio.conf)"'
    if deploy.count(nginx_target) != 1 or value["rollback-identity.sh"].count(nginx_target) != 1:
        raise AssertionError("combined nginx target")
    if "nginx/conf.d/identity-runtime.conf" in deploy or "nginx/conf.d/identity-runtime.conf" in value["rollback-identity.sh"]:
        raise AssertionError("duplicate nginx target")
    if 'parent="$(dirname -- "$target")"' not in deploy or '[[ -d "$parent" ]]' not in deploy:
        raise AssertionError("atomic parent preservation")
    if 'install -d -m 0755 "$(dirname -- "$target")"' in deploy:
        raise AssertionError("atomic parent mode relaxation")
    if deploy.count("stop_preactivation_services || status=1") != 1:
        raise AssertionError("first activation service restoration")
    if deploy.count("systemctl reset-failed identity-stack.service") != 1:
        raise AssertionError("first activation failed-unit restoration")
    if "validate_generation_directory" not in deploy or "700:0:0" not in deploy:
        raise AssertionError("generation mode guard")
    expected_inputs = (
        'require_postgres_client_input "$generation/secrets/database/bootstrap.pgpass" 600:10001:10001',
        'require_postgres_client_input "$generation/secrets/database/migrator_password" 440:0:10001',
        'require_postgres_client_input "$generation/secrets/database/runtime_password" 440:0:10001',
        'require_postgres_client_input "$generation/tls/postgres-client/ca.crt" 440:0:10001',
    )
    if any(deploy.count(item) != 1 for item in expected_inputs):
        raise AssertionError("input metadata")
    if deploy.count('[[ -f "$path" && ! -L "$path" ]]') != 1:
        raise AssertionError("input type")
    if deploy.index("\nvalidate_postgres_client_inputs\n") > deploy.index("deployment_stage=image_validation"):
        raise AssertionError("input validation order")
    bootstrap = 'run_postgres_client postgres-bootstrap < "$generation/postgres-roles.sql"'
    audit = 'run_postgres_client postgres-admin --set IDENTITY_POST_MIGRATION_AUDIT=1 < "$generation/postgres-roles.sql"'
    if deploy.count(bootstrap) != 1 or deploy.count(audit) != 1:
        raise AssertionError("SQL stdin")
    if "run --rm --no-deps --no-TTY \"$service\"" not in deploy:
        raise AssertionError("ephemeral lifetime")
    for stage in ("client_input_validation", "database_readiness", "database_bootstrap", "migration", "migration_head", "grant_audit", "recovery_marker", "activation"):
        if len(re.findall(r"^deployment_stage=" + re.escape(stage) + r"$", deploy, re.M)) != 1:
            raise AssertionError("deployment stage: " + stage)
    for name in ("deploy-identity.sh", "backup-identity.sh", "verify-identity.sh", "rollback-identity.sh"):
        if re.search(r"compose[^\n]*exec[^\n]*postgres(?:[^\n]*\n){0,2}[^\n]*psql", value[name]):
            raise AssertionError("in-server SQL client: " + name)
    if value["restore-identity.sh"].count("run_restore_psql") < 4:
        raise AssertionError("restore client calls")
    if connection not in deploy or connection not in value["restore-identity.sh"]:
        raise AssertionError("verify-full connection")
    if "--network none" in value["restore-identity.sh"] and "identity-restore" in value["restore-identity.sh"]:
        raise AssertionError("restore network")
    if re.search(r"--file\s+\"?\$generation/postgres-roles[.]sql", deploy):
        raise AssertionError("unmounted host SQL path")
    wrapper = "/opt/platform/pgbackrest-sidecar"
    if deploy.count(wrapper) != 4 or value["backup-identity.sh"].count(wrapper) != 3:
        raise AssertionError("pgbackrest wrapper callers")
    stanza_create = "--entrypoint " + wrapper + " pgbackrest --stanza=identity stanza-create"
    archiver_start = "up --detach --wait pgbackrest"
    archive_mountpoint = "install -d -m 0700 /var/lib/postgresql/18/docker/pg_wal/platform-spool"
    if deploy.count(stanza_create) != 1 or deploy.count(archiver_start) != 1:
        raise AssertionError("pgbackrest serialized readiness")
    if deploy.count(archive_mountpoint) != 1:
        raise AssertionError("pgbackrest archive mountpoint")
    if not deploy.index(archive_mountpoint) < deploy.index(stanza_create) < deploy.index(archiver_start):
        raise AssertionError("pgbackrest stanza/start order")
    if re.search(r"exec[^\n]*pgbackrest(?:[^\n]*\n){0,1}[^\n]*stanza-create", deploy):
        raise AssertionError("pgbackrest competing stanza creator")
    if value["restore-identity.sh"].count("--entrypoint " + wrapper) != 1:
        raise AssertionError("pgbackrest restore wrapper")
    if "PGBACKREST_REPO1_CIPHER_PASS" not in pgbackrest_sidecar or "440:0:65532" not in pgbackrest_sidecar:
        raise AssertionError("pgbackrest cipher wrapper")
    if "archive_input_root=/var/lib/postgresql/18/docker/pg_wal/platform-spool" not in pgbackrest_sidecar:
        raise AssertionError("pgbackrest nested archive source")
    if "'%d:%i'" not in pgbackrest_sidecar:
        raise AssertionError("pgbackrest archive inode proof")
    if '--no-archive-async archive-push "$archive_input"' not in pgbackrest_sidecar:
        raise AssertionError("pgbackrest synchronous queue drain")
    if "repo1-cipher-pass-command" in (root / "config/runtime/pgbackrest.conf.tftpl").read_text(encoding="utf-8"):
        raise AssertionError("unsupported pgbackrest cipher command")

validate_scripts(scripts)
script_mutations = []
for name, old, new in (
    ("symlink-input", '[[ -f "$path" && ! -L "$path" ]]', '[[ -f "$path" ]]'),
    ("pgpass-mode", "600:10001:10001", "440:0:10001"),
    ("unreadable-secret-mode", 'require_postgres_client_input "$generation/secrets/database/migrator_password" 440:0:10001', 'require_postgres_client_input "$generation/secrets/database/migrator_password" 400:0:10001'),
    ("wrong-hostname", "host=postgres port=5432", "host=not-postgres port=5432"),
    ("tls-downgrade", "sslmode=verify-full", "sslmode=require"),
    ("wrong-ca", "sslrootcert=/run/tls/postgres/ca.crt", "sslrootcert=/tmp/ca.crt"),
    ("missing-stdin", 'run_postgres_client postgres-bootstrap < "$generation/postgres-roles.sql"', "run_postgres_client postgres-bootstrap"),
    ("persistent-client", 'run --rm --no-deps --no-TTY "$service"', 'run --no-deps --no-TTY "$service"'),
    ("duplicate-nginx-target", 'nginx/conf.d/portfolio.conf', 'nginx/conf.d/identity-runtime.conf'),
    ("parent-mode-relaxation", '[[ -d "$parent" ]]', 'install -d -m 0755 "$parent"'),
    ("missing-first-activation-cleanup", "stop_preactivation_services || status=1", ": # candidate cleanup removed"),
    ("missing-failed-unit-reset", "systemctl reset-failed identity-stack.service", ": # failed cache retained"),
    ("missing-generation-mode-guard", "700:0:0", "755:0:0"),
):
    candidate = dict(scripts)
    target = "deploy-identity.sh"
    if old not in candidate[target]:
        raise SystemExit("Identity script mutation source drifted: " + name)
    candidate[target] = candidate[target].replace(old, new, 1)
    try:
        validate_scripts(candidate)
    except AssertionError:
        script_mutations.append(name)
    else:
        raise SystemExit("Identity client script mutation was accepted: " + name)
if len(script_mutations) != 13:
    raise SystemExit("Identity client script mutation count drifted.")

print("Identity PostgreSQL clients use exact split mounts, UID 10001, verify-full TLS, and an internal network.")
print("Identity PostgreSQL server retains narrow credentials; twelve independent client/backup/migration mutations were rejected.")
print("Identity metadata, UID, TLS hostname/CA, SQL stdin, and ephemeral-lifetime mutations were rejected.")
print("Identity bootstrap, migration-head, grant-audit, marker, backup, verify, rollback, and restore callers are coherent.")
