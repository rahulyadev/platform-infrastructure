#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

[[ "$EUID" == 0 ]]
readonly identity_domain="${SSM_identityDomain:?identityDomain parameter required}"
readonly expected_elastic_ip="${SSM_expectedElasticIp:?expectedElasticIp parameter required}"
readonly acme_email="${SSM_acmeEmail:?acmeEmail parameter required}"
readonly certbot=/opt/platform/certbot-5.7.0/bin/certbot
readonly acme_root=/var/lib/platform/acme
readonly probe_name="identity-$RANDOM-$RANDOM"
readonly probe_path="$acme_root/.well-known/acme-challenge/$probe_name"

[[ "$identity_domain" == identity.rahuly.in ]]
[[ "$acme_email" =~ ^[A-Za-z0-9.!#$%\&*+/=?^_\`\{\|\}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
[[ -x "$certbot" ]]

python3 - "$identity_domain" "$expected_elastic_ip" <<'PY'
import ipaddress
import socket
import sys

hostname = sys.argv[1]
expected = str(ipaddress.IPv4Address(sys.argv[2]))
observed_v4 = set()
observed_v6 = set()
for family, _kind, _protocol, _canonical, address in socket.getaddrinfo(
    hostname, 443, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM
):
    if family == socket.AF_INET:
        observed_v4.add(str(ipaddress.IPv4Address(address[0])))
    elif family == socket.AF_INET6:
        observed_v6.add(str(ipaddress.IPv6Address(address[0])))
if observed_v4 != {expected} or observed_v6:
    raise SystemExit("Identity DNS has not converged to the exact reviewed IPv4-only endpoint")
PY

install -d -o root -g nginx -m 0750 "$(dirname -- "$probe_path")"
printf '%s\n' "$probe_name" >"$probe_path"
chown root:nginx "$probe_path"
chmod 0440 "$probe_path"
cleanup() {
  rm -f -- "$probe_path"
}
trap cleanup EXIT
[[ "$(curl --fail --silent --show-error --max-time 15 --resolve "$identity_domain:80:127.0.0.1" "http://$identity_domain/.well-known/acme-challenge/$probe_name")" == "$probe_name" ]]

"$certbot" certonly --staging --non-interactive --agree-tos --no-eff-email \
  --email "$acme_email" --webroot --webroot-path "$acme_root" --domains "$identity_domain" \
  --config-dir /etc/letsencrypt-staging --work-dir /var/lib/letsencrypt-staging \
  --logs-dir /var/log/letsencrypt-staging
"$certbot" certonly --non-interactive --agree-tos --no-eff-email \
  --email "$acme_email" --webroot --webroot-path "$acme_root" --domains "$identity_domain"
test -s "/etc/letsencrypt/live/$identity_domain/fullchain.pem"
test -s "/etc/letsencrypt/live/$identity_domain/privkey.pem"
printf 'Identity TLS certificate issuance completed after exact DNS validation.\n'
