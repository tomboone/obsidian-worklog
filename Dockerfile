# The only place the Node version is written: ci.yml runs its checks inside this image (NEU-2016).
FROM node:26-bookworm-slim

# Pinned: obsidian-headless is pre-1.0 and its CLI may change between releases.
RUN npm install -g obsidian-headless@0.0.14 && npm cache clean --force

WORKDIR /app
COPY src ./src
COPY scripts ./scripts
