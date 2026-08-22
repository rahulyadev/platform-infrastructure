# Certificate issuance and TLS enablement

Before invoking the fixed TLS document, verify the authoritative GoDaddy DNS
answers externally: the apex and `www` must resolve exclusively to the reviewed
Elastic IP, with no unsupported IPv6 record. Confirm that TCP 80 serves the
ACME webroot. Never provide credential or ACME values in source or logs.

The host retains the VPC resolver as its normal DNS path and does not require
public UDP or TCP port 53 egress. The document checks the VPC recursive view and
independently checks Google Public DNS and Cloudflare through RFC 8484 DNS over
HTTPS. All three recursive views must agree on the exact apex and `www` IPv4
answer and the absence of IPv6 before issuance can begin.

The document proves the ACME challenge route locally through Nginx, runs a
Let's Encrypt staging issuance as the external HTTP-01 validation gate, and
then requests one production certificate covering apex and `www` in Certbot
webroot mode. Only after success does it install the reviewed TLS Nginx
configuration, run `nginx -t`, reload, and perform a renewal dry-run. Any later
failure restores the prior HTTP config. DNS must continue pointing to the host
so subsequent webroot renewals can pass.

TLS permits versions 1.2 and 1.3. Initial HSTS is `max-age=300` without
`includeSubDomains`; v1 CSP is report-only. Confirm apex HTTPS is canonical,
`www` redirects with 308, HTTP redirects only after TLS is active, renewal works,
and certificate names/chain/expiry are correct. The document never changes DNS.
