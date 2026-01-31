FROM ghcr.io/openclaw/openclaw:latest

USER root

# Optional: install extra packages at build time so they persist across container recreation.
# Pass via docker compose build args (OPENCLAW_DOCKER_APT_PACKAGES) and/or set in .env.
ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      apt-get install -y $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/*; \
    fi

USER node
