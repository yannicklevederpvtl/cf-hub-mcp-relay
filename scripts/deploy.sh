#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ORG="${ORG:-financial-services}"
SPACE="${SPACE:-payment-operations}"
APP="${APP:-hub-mcp-agent-demo}"
MODEL_SERVICE="${MODEL_SERVICE:-hub-mcp-agent-model}"
MODEL_PLAN="${MODEL_PLAN:-glm-5.3-flash}"
SSO_SERVICE="${SSO_SERVICE:-hub-mcp-agent-sso}"
SSO_PLAN="${SSO_PLAN:-uaa}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-hub-mcp-demo-gateway}"
MCP_BINDING="${MCP_BINDING:-tanzu-hub-mcp}"
CREDENTIAL_STORE="${CREDENTIAL_STORE:-hub-mcp-agent-credentials}"
RELAY_APP="${RELAY_APP:-hub-mcp-relay}"
HUB_MCP_URL="${HUB_MCP_URL:-https://hub.tas.homelab.com/hub/mcp}"
HUB_OAUTH_SERVICE="${HUB_OAUTH_SERVICE:-hub-mcp-oauth-provider}"

need() {
  command -v "$1" >/dev/null || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

need cf
need curl
need jq

ensure_service() {
  local offering="$1" plan="$2" name="$3"
  if ! cf service "$name" >/dev/null 2>&1; then
    cf create-service "$offering" "$plan" "$name" --wait
  fi
}

ensure_cups() {
  local name="$1" credentials="$2" tags="$3"
  if cf service "$name" >/dev/null 2>&1; then
    cf update-user-provided-service "$name" -p "$credentials" -t "$tags"
  else
    cf create-user-provided-service "$name" -p "$credentials" -t "$tags"
  fi
}

ensure_hub_oauth_provider() {
  local callback_url="$1"
  local auth_base="${HUB_MCP_URL%/mcp}"
  local registration response credentials

  if cf service "$HUB_OAUTH_SERVICE" >/dev/null 2>&1; then
    return
  fi

  registration="$(
    jq -cn \
      --arg callback "$callback_url" \
      '{
        client_name: "TAS Hub MCP Gateway",
        redirect_uris: [$callback],
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        token_endpoint_auth_method: "client_secret_post"
      }'
  )"
  response="$(
    curl -fsS \
      -H 'Content-Type: application/json' \
      -d "$registration" \
      "$auth_base/register"
  )"

  if ! jq -e '
    (.client_id | type == "string" and length > 0) and
    (.client_secret | type == "string" and length > 0)
  ' <<<"$response" >/dev/null; then
    echo "Hub dynamic client registration did not return a client ID and secret." >&2
    exit 1
  fi

  credentials="$(
    jq -cn \
      --arg authorization_endpoint "$auth_base/authorize" \
      --arg token_endpoint "$auth_base/token" \
      --arg client_id "$(jq -er .client_id <<<"$response")" \
      --arg client_secret "$(jq -er .client_secret <<<"$response")" \
      '{
        authorization_endpoint: $authorization_endpoint,
        token_endpoint: $token_endpoint,
        client_id: $client_id,
        client_secret: $client_secret,
        token_endpoint_auth_method: "client_secret_post"
      }'
  )"
  cf create-user-provided-service "$HUB_OAUTH_SERVICE" -p "$credentials"
}

is_bound() {
  local app="$1" service="$2"
  local app_guid service_guid
  app_guid="$(cf app "$app" --guid)"
  service_guid="$(cf service "$service" --guid)"
  cf curl "/v3/service_credential_bindings?app_guids=$app_guid&service_instance_guids=$service_guid" |
    jq -e '.pagination.total_results > 0' >/dev/null
}

ensure_app_binding() {
  local app="$1" service="$2" parameters="${3:-}"
  if is_bound "$app" "$service"; then
    return
  fi
  if [[ -n "$parameters" ]]; then
    cf bind-service "$app" "$service" -c "$parameters" --wait
  else
    cf bind-service "$app" "$service" --wait
  fi
}

cf target -o "$ORG" -s "$SPACE"

hub_status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$HUB_MCP_URL")"
if [[ "$hub_status" != "401" ]]; then
  echo "Expected Hub MCP OAuth challenge (401), received HTTP $hub_status from $HUB_MCP_URL" >&2
  exit 1
fi

ensure_service ai-models "$MODEL_PLAN" "$MODEL_SERVICE"
ensure_service p-identity "$SSO_PLAN" "$SSO_SERVICE"
ensure_service credential-store shared "$CREDENTIAL_STORE"

gateway_params="$(jq -c . "$ROOT_DIR/gateway-params.json")"

if cf service "$GATEWAY_SERVICE" >/dev/null 2>&1; then
  cf update-service "$GATEWAY_SERVICE" -c "$gateway_params" --wait
else
  cf create-service mcp-gateway gateway "$GATEWAY_SERVICE" -c "$gateway_params" --wait
fi

cf push -f "$ROOT_DIR/relay/manifest.yml"
cf set-env "$RELAY_APP" HUB_MCP_URL "$HUB_MCP_URL" >/dev/null

gateway_guid="$(cf service "$GATEWAY_SERVICE" --guid)"
gateway_url="$(
  cf curl "/v3/service_instances/$gateway_guid" |
    jq -er '.dashboard_url | select(type == "string" and length > 0)'
)"
gateway_mcp_url="${gateway_url%/}/${RELAY_APP}/mcp"
gateway_oauth_callback="${gateway_url%/}/${RELAY_APP}/auth/callback"

ensure_hub_oauth_provider "$gateway_oauth_callback"

# Rebind so changes to the OAuth provider are applied to the managed Gateway.
if is_bound "$RELAY_APP" "$GATEWAY_SERVICE"; then
  cf unbind-service "$RELAY_APP" "$GATEWAY_SERVICE" --wait
fi
cf bind-service "$RELAY_APP" "$GATEWAY_SERVICE" \
  -c "$ROOT_DIR/relay-gateway-binding.json" --wait

ensure_cups "$MCP_BINDING" \
  "$(jq -cn --arg url "$gateway_mcp_url" '{url: $url}')" \
  mcp-server

cf push -f "$ROOT_DIR/agent/manifest.yml"

# Bind Credential Store only after the app already has SSO and MCP discovery
# bindings, so the store can register the agent issuer and eligible MCP resource.
if is_bound "$APP" "$CREDENTIAL_STORE"; then
  cf unbind-service "$APP" "$CREDENTIAL_STORE" --wait
fi
cf bind-service "$APP" "$CREDENTIAL_STORE" --wait
cf restage "$APP"

echo
echo "Hub MCP agent demo deployed."
echo "Agent:   https://$APP.apps.tas.<yourdomain>"
echo "Gateway: $gateway_mcp_url"
echo
echo "One-time setup: add a user-scoped or store-scoped OAuth credential for"
echo "'$MCP_BINDING' in '$CREDENTIAL_STORE' through Tanzu Hub."
echo "After that grant exists, a new agent login should connect automatically."
