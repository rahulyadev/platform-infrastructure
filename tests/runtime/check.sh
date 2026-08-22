#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"

[[ "$(grep -R -E '^[[:space:]]*allowed_account_ids[[:space:]]*=[[:space:]]*\[var[.]expected_account_id\]' infra/live/production/runtime/providers.tf | wc -l)" == "1" ]]
[[ "$(grep -F 'key    = "production/runtime/tofu.tfstate"' infra/live/production/runtime/backend.hcl.example | wc -l)" == "1" ]]
[[ "$(grep -R -E 'resource[[:space:]]+"aws_cloudwatch_metric_alarm"' infra/modules/monitoring | wc -l)" == "8" ]]
grep -Fq '"measurement": ["used_percent", "inodes_used", "inodes_total"]' config/cloudwatch/agent-config.json.tftpl
[[ "$(grep -Fc '"drop_original_metrics"' config/cloudwatch/agent-config.json.tftpl)" == "3" ]]
grep -Fq 'expression  = "100 * inode_used / inode_total"' infra/modules/monitoring/alarms.tf
! grep -R -F 'disk_inodes_used_percent' config/cloudwatch infra/modules/monitoring
[[ "$(grep -R -E 'resource[[:space:]]+"aws_ssm_association"' infra/modules/monitoring infra/modules/deployment | wc -l)" == "3" ]]
[[ "$(grep -F 'cron_expression' infra/modules/snapshot_policy/main.tf | wc -l)" == "2" ]]
[[ "$(grep -F 'resource "aws_iam_openid_connect_provider" "github"' infra/modules/deployment/github_oidc.tf | wc -l)" == "1" ]]
! grep -R -E 'thumbprint_list|github_subject.*[*]' infra/modules/deployment

jq -e '
  .packages.nginx == "nginx-1:1.30.4-1.amzn2023.0.1.aarch64" and
  .packages.awsCli == "awscli-2-2.33.15-1.amzn2023.0.1.noarch" and
  .packages.python == "python3.12-3.12.13-2.amzn2023.0.5.aarch64" and
  .packages.amazonCloudWatchAgent == "1.300071.0b1720" and
  .packages.certbot == "5.7.0" and
  .packages.certbotRequiresPython == ">=3.10"
' config/runtime/packages.json >/dev/null

printf '%s\n' 'runtime contract checks passed'
