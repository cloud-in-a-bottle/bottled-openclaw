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

exec runuser -u node -- "$@"
