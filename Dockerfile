# The only place the Node version is written: CI runs its checks inside this image, in .github/ci/smoke.sh (NEU-2016).
FROM node:26-bookworm-slim

# Pinned: obsidian-headless is pre-1.0 and its CLI may change between releases.
RUN npm install -g obsidian-headless@0.0.14 && npm cache clean --force

WORKDIR /app
COPY src ./src
COPY scripts ./scripts

# The base image's `node` user is UID/GID 1000, the same as kumadrome's `tom`, which deploy/docker-compose.yml
# already runs both services as (PUID/PGID). Nothing is written under /app; Runs write only to the volumes.
USER node
