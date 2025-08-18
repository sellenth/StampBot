#!/usr/bin/env bash

# Simple deployment script for drag‑n‑stamp.  This script wraps
# `fly deploy` and selects the appropriate configuration file based
# on the environment argument.  Usage:
#
#   ./scripts/deploy.sh dev      # deploy to drag-n-stamp-dev
#   ./scripts/deploy.sh prod     # deploy to drag-n-stamp-prod

set -euo pipefail

ENV="${1:-}"
if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <dev|prod>" >&2
  exit 1
fi

case "$ENV" in
  dev)
    CONFIG="fly.dev.toml"
    ;;
  prod)
    CONFIG="fly.prod.toml"
    ;;
  *)
    echo "Unknown environment: $ENV" >&2
    exit 1
    ;;
esac

echo "Deploying to $ENV using $CONFIG..."

# Get the current Git commit hash for image labeling
COMMIT_HASH=$(git rev-parse --short HEAD)
echo "Using commit hash: $COMMIT_HASH"

# Build and deploy using the chosen configuration.  If you need to
# set secrets or environment variables, run `fly secrets set` before
# invoking this script.  The `--remote-only` flag ensures the Docker
# build occurs on Fly's builders rather than locally.  Remove it if
# you prefer local builds.
fly deploy -c "$CONFIG" --image-label "commit-$COMMIT_HASH"
