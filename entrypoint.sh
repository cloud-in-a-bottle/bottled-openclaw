#!/bin/bash
set -e

DATA_DIR=/data/app_data/openclaw
TARGET=/home/node/.openclaw

mkdir -p "$DATA_DIR"
chown -R node:node "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [ ! -L "$TARGET" ] || [ "$(readlink "$TARGET")" != "$DATA_DIR" ]; then
    rm -rf "$TARGET"
    ln -s "$DATA_DIR" "$TARGET"
    chown -h node:node "$TARGET"
fi

ZONE_DOMAIN="${OPENHOST_ZONE_DOMAIN:-localhost}"
APP_NAME="${OPENHOST_APP_NAME:-openclaw}"
# The control UI's browser origin. Real zones are https; a dev router (or the test harness) serves plain http, and
# OPENHOST_ROUTER_PUBLIC_URL says which.
case "${OPENHOST_ROUTER_PUBLIC_URL:-}" in
    http://*) APP_SCHEME=http ;;
    *) APP_SCHEME=https ;;
esac
APP_HOST="${APP_NAME}.${ZONE_DOMAIN}"
APP_ORIGIN="${APP_SCHEME}://${APP_HOST}"
APP_PORT=18789
GATEWAY_PORT=18790

ANTHROPIC_API_KEY=""
if [ -n "$OPENHOST_ROUTER_URL" ] && [ -n "$OPENHOST_APP_TOKEN" ]; then
    secrets_response=$(curl -sS -X POST \
        -H "Authorization: Bearer $OPENHOST_APP_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"keys": ["ANTHROPIC_API_KEY"]}' \
        "$OPENHOST_ROUTER_URL/api/services/v2/call/secrets/get" 2>/dev/null || true)
    parsed=$(printf '%s' "$secrets_response" | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
    key = (d.get("secrets") or {}).get("ANTHROPIC_API_KEY", "")
    grant_url = d.get("grant_url") or (d.get("required_grant") or {}).get("grant_url", "")
    print(f"{key}\t{grant_url}")
except Exception: print("\t")' 2>/dev/null || printf '\t')
    ANTHROPIC_API_KEY=$(printf '%s' "$parsed" | cut -f1)
    GRANT_URL=$(printf '%s' "$parsed" | cut -f2)
fi

if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "[entrypoint] ANTHROPIC_API_KEY loaded from secrets service"
elif [ -n "$GRANT_URL" ]; then
    echo "[entrypoint] ANTHROPIC_API_KEY permission needed — approve at: $GRANT_URL"
    echo "[entrypoint] After approving, run: oh app reload openclaw"
else
    echo "[entrypoint] ANTHROPIC_API_KEY not available; configure ANTHROPIC_API_KEY in the secrets app and reload"
fi

runuser -u node -- python3 - <<PY
import json
import secrets
from pathlib import Path

cfg_path = Path("$DATA_DIR/openclaw.json")
cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}

gw = cfg.setdefault("gateway", {})
# The gateway listens on loopback only; owner-proxy.mjs on the app port is its sole proxy and the only address it trusts.
gw["bind"] = "loopback"
gw["port"] = ${GATEWAY_PORT}
gw["trustedProxies"] = ["127.0.0.1"]
# The gateway's own local clients (eg the CLI, or agent tools that can't dispatch in-process) connect to it over
# loopback without the router's owner header, so they need a local password; keep it stable across boots.
local_password = (gw.get("auth") or {}).get("password") or secrets.token_urlsafe(32)
owner_scopes = [
    "operator.admin",
    "operator.read",
    "operator.write",
    "operator.approvals",
    "operator.pairing",
    "operator.questions",
]
gw["auth"] = {
    "mode": "trusted-proxy",
    "password": local_password,
    # The router sets X-OpenHost-Is-Owner: true only for the owner, so that is the one identity, with full scopes.
    "identityScopes": {"true": owner_scopes},
    "trustedProxy": {
        "userHeader": "X-OpenHost-Is-Owner",
        "requiredHeaders": ["X-OpenHost-Is-Owner"],
        "allowUsers": ["true"],
        "allowLoopback": True,
        # The owner's browser pairs its device without an approval step on the gateway host.
        "deviceAutoApprove": {"enabled": True},
    },
}
control_ui = gw.setdefault("controlUi", {})
control_ui["allowedOrigins"] = ["${APP_ORIGIN}"]
# Retired upstream in 2026.8.1 (browsers now pair, auto-approved above); left in place, doctor would re-import a
# pending pairing migration on every boot.
control_ui.pop("dangerouslyDisableDeviceAuth", None)

agents_defaults = cfg.setdefault("agents", {}).setdefault("defaults", {})
agents_defaults["model"] = {"primary": "anthropic/claude-sonnet-4-6"}

cfg_path.write_text(json.dumps(cfg, indent=2))
PY

runuser -u node -- env \
    OWNER_PROXY_LISTEN_PORT="$APP_PORT" \
    OWNER_PROXY_GATEWAY_PORT="$GATEWAY_PORT" \
    OWNER_PROXY_FORWARDED_PROTO="$APP_SCHEME" \
    OWNER_PROXY_FORWARDED_HOST="$APP_HOST" \
    node /openhost-owner-proxy.mjs &

export ANTHROPIC_API_KEY
runuser -u node --whitelist-environment=ANTHROPIC_API_KEY -- "$@" &

# tini (PID 1, -g) delivers stop signals to both. If either exits, stop the other and exit with its status.
set +e
wait -n
status=$?
kill $(jobs -p) 2>/dev/null
wait
exit "$status"
