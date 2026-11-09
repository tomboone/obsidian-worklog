#!/usr/bin/env bash
# The in-image checks. image-check passes the image tag as $1. Everything runs inside the image, so CI
# tests the Node the Dockerfile's FROM ships, and the Node version is written nowhere else (NEU-2016).
set -euo pipefail
image=$1

docker run --rm "$image" node --version

# No package.json and no dependencies (spec Decision 5), so syntax checks stand in for a linter.
# Stops at the first file that fails; `find -exec … \;` would exit 0 whatever node --check returns.
docker run --rm "$image" sh -c '
  set -e
  for f in $(find src -name "*.mjs"); do node --check "$f"; done
  sh -n scripts/loop.sh
'

# Quoted so Node expands the glob, not the runner's shell.
docker run --rm "$image" node --test 'src/**/*.test.mjs'

# obsidian-headless has to start on this Node, or Vault sync dies on kumadrome.
docker run --rm "$image" ob --version

echo "smoke ok"
