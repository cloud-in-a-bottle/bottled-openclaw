FROM ghcr.io/openclaw/openclaw:latest

USER root
RUN rm -rf /home/node/.openclaw \
    && ln -s /data/app_data/openclaw /home/node/.openclaw
USER node

EXPOSE 18789
