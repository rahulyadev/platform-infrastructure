# Optional shared local stack

This repository may later define an optional shared local stack for common
development dependencies. Application repositories must retain standalone
local-development paths and must not require multiple repositories to run one
application.

PostgreSQL, Redis, and RabbitMQ server daemons must not be installed directly on
the workstation. RabbitMQ remains opt-in and is not a production dependency.

No local Compose stack is defined in this repository. A separate reported test
stack was not running during the last verified Docker inspection; no files or
secret paths from that stack are copied or referenced here.
