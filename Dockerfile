# Pinned by digest for reproducible builds (tag 2026.10.6); bump to upgrade.
FROM ghcr.io/openclaw/openclaw:2026.10.6@sha256:7dbff0fe5f5359b1badefe90a23efa9f203cd0d3c36bee095f4896c7a1d3864b

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
