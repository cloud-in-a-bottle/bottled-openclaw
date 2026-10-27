# Pinned by digest for reproducible builds (tag 2026.10.5); bump to upgrade.
FROM ghcr.io/openclaw/openclaw:2026.10.5@sha256:f40d1e66fd14d8c5b49c832f4100f83b53fdc01f5108f7db11de38fd0ee6dbe5

USER root

COPY entrypoint.sh /openhost-entrypoint.sh
RUN chmod +x /openhost-entrypoint.sh \
    && rm -rf /home/node/.openclaw

EXPOSE 18789

ENTRYPOINT ["/openhost-entrypoint.sh"]
CMD ["docker-entrypoint.sh", "node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
