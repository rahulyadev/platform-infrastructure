# Certificate issuance and TLS enablement

Certificate issuance is a later explicit operation. Before invoking the fixed
TLS document, verify authoritative GoDaddy DNS for the apex and `www` resolves
exclusively to the reviewed Elastic IP and that TCP 80 serves the ACME webroot.
Never provide credential or ACME values in source or logs.

The document validates authoritative DNS, proves the HTTP challenge path, runs
a Let's Encrypt staging issuance first, and then requests one production
certificate covering apex and `www` in Certbot webroot mode. Only after success
does it install the reviewed TLS Nginx configuration, run `nginx -t`, reload,
and perform a renewal dry-run. Any later failure restores the prior HTTP config.

TLS permits versions 1.2 and 1.3. Initial HSTS is `max-age=300` without
`includeSubDomains`; v1 CSP is report-only. Confirm apex HTTPS is canonical,
`www` redirects with 308, HTTP redirects only after TLS is active, renewal works,
and certificate names/chain/expiry are correct. The document never changes DNS.
