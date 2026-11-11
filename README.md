# Tanzu Hub MCP agent demo

An isolated Tanzu Agent Buildpack demonstration of:

```text
User login
  → Tanzu Agent SSO token
  → MCP Gateway
  → Credential Store
  → Gateway-managed Hub OAuth token
  → fixed-destination internal relay
  → Tanzu Hub MCP (/hub/mcp)
```

After a Hub OAuth credential has been authorized once and saved in Credential
Store, later agent logins connect to Hub automatically. The user does not need
to open the Tools panel or click **Connect** or **Reconnect**.

## Deployed resources

- App: `hub-mcp-agent-demo`
- Model: `hub-mcp-agent-model`
- SSO: `hub-mcp-agent-sso`
- MCP Gateway: `hub-mcp-demo-gateway`
- Hub OAuth provider: `hub-mcp-oauth-provider`
- Internal relay: `hub-mcp-relay`
- Agent MCP discovery binding: `tanzu-hub-mcp`
- Credential Store: `hub-mcp-agent-credentials`
- Upstream MCP endpoint: `https://hub.tas06.<yourdomain>/hub/mcp`

The demo is deployed by default to `financial-services / payment-operations` on
TAS03. It does not modify the existing Payment Investigator resources.

The relay is a fixed-destination, `apps.internal` Python application. It exists
because this Gateway release cannot attach route authentication to an
off-platform `mcp-servers` entry. Binding the relay as an on-platform MCP app
lets Gateway apply its generic OAuth proxy to Hub and participate in Credential
Store resolution. The relay does not store or transform credentials.

## Deploy

```bash
bash scripts/deploy.sh
```

The script:

1. Verifies that the Hub MCP endpoint advertises an OAuth challenge.
2. Provisions the model, SSO, Credential Store, and dedicated MCP Gateway.
3. Pushes the fixed-destination relay with `python_buildpack` in uv mode.
4. Dynamically registers a confidential OAuth client with Hub and stores it in
   the `hub-mcp-oauth-provider` user-provided service.
5. Binds the relay to Gateway with generic OAuth route authentication.
6. Creates a user-provided service tagged `mcp-server` for agent discovery.
7. Pushes the agent with `agent_buildpack`.
8. Binds Credential Store last and restages the agent.

## One-time Hub authorization

In Tanzu Hub, open the `financial-services / payment-operations` space and its
Credentials page. Select `hub-mcp-agent-credentials`, add a credential for
`tanzu-hub-mcp`, and complete the Hub OAuth authorization.

Use a user-scoped credential to preserve the signed-in user's Hub permissions.
A store-scoped credential is useful for a shared demo but makes all agent users
act through the shared Hub account.

## Verify no reconnect

```bash
bash scripts/verify.sh
```

Then:

1. Open `https://hub-mcp-agent-demo.apps.<yourdomain>`.
2. Sign in but do not open the Tools panel.
3. Ask: `Show the Tanzu Platform foundations I can access.`
4. Confirm a Hub MCP tool runs without Connect or Reconnect.
5. Restart the agent and repeat to demonstrate that Credential Store, rather
   than the agent process, retains the Hub authorization.

The first OAuth authorization is expected. The behavior demonstrated here is
automatic connection on every later agent session.
