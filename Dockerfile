# Pinned by digest for reproducible builds (tag 2026.11.1); bump to upgrade.
FROM ghcr.io/openclaw/openclaw:2026.11.1@sha256:db0e0809fbd0df375445e9eea8daf2a278ac7ac3a263fa6bfce8fb344ad3ad77

USER root

# State lives in app data. ~/.openclaw stays a symlink to it for paths older installs recorded, but OpenClaw is
# pointed at the real directory: it skips bundled skills whose path goes through a symlinked state dir.
ENV OPENCLAW_STATE_DIR=/data/app_data/openclaw

COPY entrypoint.sh /openhost-entrypoint.sh
COPY owner-proxy.mjs /openhost-owner-proxy.mjs
RUN chmod +x /openhost-entrypoint.sh \
    && rm -rf /home/node/.openclaw

EXPOSE 18789

# tini as PID 1, signalling the whole group: the entrypoint runs owner-proxy.mjs alongside the gateway. The command is
# upstream's image activation (Doctor's state repair and migrations, then the gateway), as upstream's ENTRYPOINT runs it.
ENTRYPOINT ["tini", "-s", "-g", "--", "/openhost-entrypoint.sh"]
CMD ["node", "/app/docker-entrypoint.mjs", "node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
