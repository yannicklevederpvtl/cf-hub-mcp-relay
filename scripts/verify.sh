#!/usr/bin/env bash
set -euo pipefail

ORG="${ORG:-financial-services}"
SPACE="${SPACE:-payment-operations}"
APP="${APP:-hub-mcp-agent-demo}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-hub-mcp-demo-gateway}"
RELAY_APP="${RELAY_APP:-hub-mcp-relay}"

cf target -o "$ORG" -s "$SPACE" >/dev/null

cf app "$APP"
cf app "$RELAY_APP"
cf services | rg 'hub-mcp-|tanzu-hub-mcp'

gateway_guid="$(cf service "$GATEWAY_SERVICE" --guid)"
gateway_url="$(
  cf curl "/v3/service_instances/$gateway_guid" |
    jq -er '.dashboard_url | select(type == "string" and length > 0)'
)"
gateway_mcp_url="${gateway_url%/}/${RELAY_APP}/mcp"

status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$gateway_mcp_url")"
echo "Unauthenticated Gateway MCP status: $status (expected 401)"
[[ "$status" == "401" ]]

cf logs "$APP" --recent |
  rg 'Resolved model|Discovered MCP|MCP toolset|Credential Store|credential store|connected|auth_required' || true

cat <<EOF

Browser verification:
1. Open https://$APP.apps.tas03.ylhomelab.com and sign in.
2. Do not open the Tools panel.
3. Ask: "Show the Tanzu Platform foundations I can access."
4. Confirm the Hub MCP tool runs without Connect or Reconnect.
5. Restart the app, sign in again, and repeat to prove the grant persisted.
EOF
