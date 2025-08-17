#!/bin/bash

# Start database proxy in background
fly mpg proxy --cluster n83v7rg59zg05gxk &
PROXY_PID=$!

# Wait for proxy to start
sleep 3

# Run migrations
mix ecto.migrate

# Start Phoenix server
mix phx.server

# Cleanup: kill proxy when server stops
trap "kill $PROXY_PID 2>/dev/null" EXIT