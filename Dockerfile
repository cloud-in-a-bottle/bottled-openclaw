FROM ghcr.io/openclaw/openclaw:latest

USER root

COPY entrypoint.sh /openhost-entrypoint.sh
RUN chmod +x /openhost-entrypoint.sh \
    && rm -rf /home/node/.openclaw

EXPOSE 18789

ENTRYPOINT ["/openhost-entrypoint.sh"]
CMD ["docker-entrypoint.sh", "node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
