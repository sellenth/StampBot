#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Use DATABASE_URL or the local PostgreSQL default in config/dev.exs.

# Run migrations
mix ecto.migrate

# Start Phoenix server
exec mix phx.server
