# Pinned by digest for reproducible builds (tag 2026.7.1). The previous
# ":latest" tracked the upstream main branch, so every rebuild could pull a
# different OpenClaw build and silently change the config schema the entrypoint
# writes. Bump this digest to upgrade.
FROM ghcr.io/openclaw/openclaw:2026.7.1@sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c

USER root

COPY entrypoint.sh /openhost-entrypoint.sh
RUN chmod +x /openhost-entrypoint.sh \
    && rm -rf /home/node/.openclaw

EXPOSE 18789

ENTRYPOINT ["/openhost-entrypoint.sh"]
CMD ["docker-entrypoint.sh", "node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
