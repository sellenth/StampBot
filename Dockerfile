# syntax=docker/dockerfile:1
#
# Multi-stage Dockerfile for building and running the drag‑n‑stamp
# Phoenix application on Fly.io.  The build stage compiles Elixir
# sources, installs Node dependencies, builds static assets, and
# generates an OTP release.  The final stage contains just the
# compiled release and minimal runtime dependencies, keeping
# container images small and secure.

## ------------------------------------------------------
## Build stage
## ------------------------------------------------------
# Use an official Elixir image with Alpine Linux.  The ARGs allow
# overriding versions at build time but default to sensible
# versions.  See https://hub.docker.com/r/hexpm/elixir/tags for
# available tags.
ARG ELIXIR_VERSION=1.17.0
ARG OTP_VERSION=27.0
ARG ALPINE_VERSION=3.19.1
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION} AS build

# Install build dependencies.  Node/npm are required for Tailwind
# and JS bundling, git allows mix to fetch dependencies, and
# build-base provides compilers for native dependencies.
RUN apk add --no-cache build-base git npm curl python3

# Set working directory inside the container
WORKDIR /app

# Install Hex and Rebar so Elixir can fetch dependencies.
RUN mix local.hex --force && \
    mix local.rebar --force

# Set the environment to production.  This ensures Mix pulls
# production dependencies and builds the release for prod.
ENV MIX_ENV=prod

# Copy dependency manifests and fetch dependencies.  Separating
# dependency installation from source code copy allows Docker to
# cache expensive compilation steps when only application code
# changes.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && \
    mix deps.compile

# Copy the application source needed for Tailwind to scan for classes
COPY lib lib
COPY priv priv

# Build static assets.  Phoenix 1.7+ uses esbuild and tailwind
# instead of npm.  Tailwind needs lib directory to scan for classes.
COPY assets assets
RUN mix assets.deploy
RUN mix release --overwrite

## ------------------------------------------------------
## Runtime stage
## ------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS app

# Install runtime dependencies.  openssl is required by certain
# Elixir/Erlang libraries (for example, :crypto), libstdc++ is
# required for some NIFs, and ncurses-libs ensures :observer and
# other tools can run if needed.
RUN apk add --no-cache libstdc++ openssl ncurses-libs

# Set working directory
WORKDIR /app

# Enable IPv6 inside Ecto so the app can connect to Fly Postgres via
# the internal IPv6 flycast address.  See config/runtime.exs for
# details.
ENV ECTO_IPV6=true

# Copy the release built in the previous stage.  The `_build` path
# always contains a `prod/rel/<app>` directory when building
# releases.
COPY --from=build /app/_build/prod/rel/drag_n_stamp ./

# The Phoenix release expects PHX_SERVER to be set in order to
# start the web server automatically.  Without this environment
# variable the app will compile but not start accepting requests.
ENV PHX_SERVER=true

# Expose port 4000 (Fly will map this automatically to 80/443)
EXPOSE 4000

# Start the release.  `start` runs the app in the foreground so
# Docker can capture logs.
ENTRYPOINT ["/app/bin/drag_n_stamp"]
CMD ["start"]