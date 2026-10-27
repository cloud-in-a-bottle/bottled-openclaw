#!/bin/sh
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
APP_ORIGIN="https://${APP_NAME}.${ZONE_DOMAIN}"

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
from pathlib import Path

cfg_path = Path("$DATA_DIR/openclaw.json")
cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}

gw = cfg.setdefault("gateway", {})
gw["auth"] = {
    "mode": "trusted-proxy",
    "trustedProxy": {
        "userHeader": "X-OpenHost-Is-Owner",
        "requiredHeaders": ["X-OpenHost-Is-Owner"],
        "allowUsers": ["true"],
        "allowLoopback": True,
    },
}
gw["trustedProxies"] = ["0.0.0.0/0", "::/0"]
control_ui = gw.setdefault("controlUi", {})
control_ui["allowedOrigins"] = ["${APP_ORIGIN}"]
control_ui["dangerouslyDisableDeviceAuth"] = True

agents_defaults = cfg.setdefault("agents", {}).setdefault("defaults", {})
agents_defaults["model"] = {"primary": "anthropic/claude-sonnet-4-6"}

cfg_path.write_text(json.dumps(cfg, indent=2))
PY

export ANTHROPIC_API_KEY
exec runuser -u node --whitelist-environment=ANTHROPIC_API_KEY -- "$@"
