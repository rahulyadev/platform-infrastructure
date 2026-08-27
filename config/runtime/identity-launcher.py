#!/usr/bin/env python3
"""Fixed, file-backed launcher for the published production Identity images."""

from __future__ import annotations

import os
import pathlib
import re
import ssl
import stat
import sys
import urllib.parse


API_UID = 10001
BFF_UID = 10002
IDENTITY_ORIGIN = "https://identity.rahuly.in"
BFF_ORIGIN = "https://rahuly.in"
AUTH_DOMAIN = "auth.rahuly.in"
RESOURCE = "identity-service://api"
SCOPES = [
    "openid",
    "identity-service://api/profile.read",
    "identity-service://api/profile.write",
]
REDIS_NAMESPACE = "reference-bff:production:portfolio:identity"
EXPECTED_SECRET_FILES = {
    "api": {
        pathlib.Path("/run/secrets/database"): {"runtime_password"},
        pathlib.Path("/run/tls/postgres"): {"ca.crt"},
    },
    "migrator": {
        pathlib.Path("/run/secrets/database"): {"migrator_password"},
        pathlib.Path("/run/tls/postgres"): {"ca.crt"},
    },
    "bff": {
        pathlib.Path("/run/secrets/client"): {"client_secret"},
        pathlib.Path("/run/secrets/redis"): {"bff_password"},
        pathlib.Path("/run/tls/redis"): {"ca.crt"},
    },
}


def fail() -> "NoReturn":
    print("Identity launcher rejected its fixed runtime contract.", file=sys.stderr)
    raise SystemExit(70)


def exact_directory(directory: pathlib.Path, expected: set[str]) -> None:
    try:
        observed = {entry.name for entry in os.scandir(directory)}
    except OSError:
        fail()
    if observed != expected:
        fail()


def read_secret(path: pathlib.Path, expected_gid: int) -> str:
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
            fail()
        if metadata.st_uid != 0 or metadata.st_gid != expected_gid:
            fail()
        if stat.S_IMODE(metadata.st_mode) != 0o440 or not 32 <= metadata.st_size <= 256:
            fail()
        raw = path.read_bytes()
    except OSError:
        fail()
    if any(byte < 0x21 or byte > 0x7E for byte in raw):
        fail()
    try:
        value = raw.decode("ascii")
    except UnicodeDecodeError:
        fail()
    if not value or value != value.strip():
        fail()
    return value


def validate_ca_file(path: pathlib.Path, expected_gid: int) -> bytes:
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
            fail()
        if metadata.st_uid != 0 or metadata.st_gid != expected_gid:
            fail()
        if stat.S_IMODE(metadata.st_mode) != 0o440 or not 256 <= metadata.st_size <= 32768:
            fail()
        value = path.read_bytes()
    except OSError:
        fail()
    if not value.startswith(b"-----BEGIN CERTIFICATE-----\n") or not value.rstrip().endswith(
        b"-----END CERTIFICATE-----"
    ):
        fail()
    return value


def fixed_cognito_inputs() -> tuple[str, str, str]:
    issuer = os.environ.get("PLATFORM_COGNITO_ISSUER", "")
    jwks = os.environ.get("PLATFORM_COGNITO_JWKS_URL", "")
    client_id = os.environ.get("PLATFORM_COGNITO_CLIENT_ID", "")
    issuer_pattern = re.compile(
        r"^https://cognito-idp\.ap-south-1\.amazonaws\.com/ap-south-1_[A-Za-z0-9]+$"
    )
    if not issuer_pattern.fullmatch(issuer):
        fail()
    if jwks != f"{issuer}/.well-known/jwks.json":
        fail()
    if not re.fullmatch(r"[a-z0-9]{26}", client_id):
        fail()
    return issuer, jwks, client_id


def base_environment() -> dict[str, str]:
    return {
        "HOME": "/nonexistent",
        "LANG": "C.UTF-8",
        "PATH": "/opt/venv/bin:/usr/local/bin:/usr/bin:/bin",
        "PYTHONPATH": "/app/src",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1",
    }


def database_url(role: str, password: str) -> str:
    encoded = urllib.parse.quote(password, safe="")
    return (
        f"postgresql+psycopg://{role}:{encoded}@postgres:5432/identity"
        "?sslmode=verify-full&sslrootcert=/run/tls/postgres/ca.crt"
    )


def api_environment() -> dict[str, str]:
    issuer, jwks, client_id = fixed_cognito_inputs()
    password = read_secret(
        pathlib.Path("/run/secrets/database/runtime_password"), API_UID
    )
    environment = base_environment()
    environment.update(
        {
            "ALLOWED_HOSTS": '["identity.rahuly.in"]',
            "APP_ENV": "production",
            "COGNITO_ALLOWED_CLIENT_IDS": f'["{client_id}"]',
            "COGNITO_ISSUER": issuer,
            "COGNITO_JWKS_URL": jwks,
            "COGNITO_USERINFO_URL": f"https://{AUTH_DOMAIN}/oauth2/userInfo",
            "DATABASE_URL": database_url("identity_service_app", password),
            "ENABLE_INTERACTIVE_DOCS": "false",
            "IDENTITY_ORIGIN": IDENTITY_ORIGIN,
            "LOG_FORMAT": "json",
            "OAUTH_PROFILE_READ_SCOPE": "identity-service://api/profile.read",
            "OAUTH_PROFILE_WRITE_SCOPE": "identity-service://api/profile.write",
            "OAUTH_RESOURCE": RESOURCE,
            "PORT": "8080",
            "TRUSTED_PROXY_CIDRS": "[]",
        }
    )
    return environment


def migrator_environment() -> dict[str, str]:
    password = read_secret(
        pathlib.Path("/run/secrets/database/migrator_password"), API_UID
    )
    environment = base_environment()
    environment["DATABASE_URL"] = database_url("identity_service_migrator", password)
    return environment


def bff_environment() -> dict[str, str]:
    issuer, jwks, client_id = fixed_cognito_inputs()
    client_secret = read_secret(
        pathlib.Path("/run/secrets/client/client_secret"), BFF_UID
    )
    redis_password = read_secret(
        pathlib.Path("/run/secrets/redis/bff_password"), BFF_UID
    )
    ca_path = pathlib.Path("/run/tls/redis/ca.crt")
    try:
        ca = validate_ca_file(ca_path, BFF_UID)
        system_ca_path = ssl.get_default_verify_paths().cafile
        if not system_ca_path:
            fail()
        system_ca = pathlib.Path(system_ca_path).read_bytes()
        bundle_directory = pathlib.Path("/tmp/identity-launcher")
        bundle_directory.mkdir(mode=0o700)
        bundle = bundle_directory / "ca-bundle.crt"
        descriptor = os.open(bundle, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(system_ca)
            if not system_ca.endswith(b"\n"):
                stream.write(b"\n")
            stream.write(ca)
    except OSError:
        fail()
    encoded = urllib.parse.quote(redis_password, safe="")
    environment = base_environment()
    environment.update(
        {
            "ALLOWED_HOSTS": '["rahuly.in"]',
            "APP_ENV": "production",
            "AUTHORIZATION_ENDPOINT": f"https://{AUTH_DOMAIN}/oauth2/authorize",
            "BFF_CLIENT_ID": client_id,
            "BFF_CLIENT_SECRET": client_secret,
            "BFF_ORIGIN": BFF_ORIGIN,
            "COGNITO_ISSUER": issuer,
            "COGNITO_JWKS_URL": jwks,
            "ENABLE_INTERACTIVE_DOCS": "false",
            "IDENTITY_API_ORIGIN": IDENTITY_ORIGIN,
            "LOG_FORMAT": "json",
            "OAUTH_RESOURCE": RESOURCE,
            "PORT": "8081",
            "REDIS_URL": f"rediss://portfolio_bff:{encoded}@redis:6379/0",
            "REDIS_KEY_NAMESPACE": REDIS_NAMESPACE,
            "REQUESTED_SCOPES": '["' + '\",\"'.join(SCOPES) + '"]',
            "SSL_CERT_FILE": str(bundle),
            "TOKEN_ENDPOINT": f"https://{AUTH_DOMAIN}/oauth2/token",
            "TRUSTED_PROXY_NETWORKS": "[]",
        }
    )
    return environment


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in EXPECTED_SECRET_FILES:
        fail()
    service = sys.argv[1]
    expected_uid = API_UID if service in {"api", "migrator"} else BFF_UID
    if os.getuid() != expected_uid or os.getgid() != expected_uid:
        fail()
    for directory, names in EXPECTED_SECRET_FILES[service].items():
        exact_directory(directory, names)
    if service in {"api", "migrator"}:
        validate_ca_file(pathlib.Path("/run/tls/postgres/ca.crt"), API_UID)

    if service == "api":
        environment = api_environment()
        command = [sys.executable, "-m", "identity_service.server"]
    elif service == "migrator":
        environment = migrator_environment()
        command = [sys.executable, "scripts/migrate_local.py"]
    else:
        environment = bff_environment()
        command = [sys.executable, "-m", "reference_bff.server"]
    os.execve(sys.executable, command, environment)


if __name__ == "__main__":
    main()
