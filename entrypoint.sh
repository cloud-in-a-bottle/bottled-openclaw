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

runuser -u node -- python3 - <<PY
import json, os
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
gw.setdefault("controlUi", {})["allowedOrigins"] = ["${APP_ORIGIN}"]

cfg_path.write_text(json.dumps(cfg, indent=2))
PY

exec runuser -u node -- "$@"
