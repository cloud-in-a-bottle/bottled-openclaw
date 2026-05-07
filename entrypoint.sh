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
    secrets_response=$(curl -fsS -X POST \
        -H "Authorization: Bearer $OPENHOST_APP_TOKEN" \
        -H "Content-Type: application/json" \
        -H "X-OpenHost-Service-URL: github.com/imbue-openhost/openhost/services/secrets" \
        -H "X-OpenHost-Service-Version: >=0.1.0" \
        -H "X-OpenHost-Service-Endpoint: get" \
        -d '{"keys": ["ANTHROPIC_API_KEY"]}' \
        "$OPENHOST_ROUTER_URL/_services_v2/service_request" 2>/dev/null) || secrets_response=""
    if [ -n "$secrets_response" ]; then
        ANTHROPIC_API_KEY=$(printf '%s' "$secrets_response" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("secrets",{}).get("ANTHROPIC_API_KEY",""))
except Exception: print("")' 2>/dev/null || echo "")
    fi
fi

if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "[entrypoint] ANTHROPIC_API_KEY loaded from secrets service"
else
    echo "[entrypoint] ANTHROPIC_API_KEY not available (grant the permission and reload)"
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
