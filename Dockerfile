# syntax=docker/dockerfile:1.7
#
# Phoenix release image for Guild. Multi-stage: a build stage compiles
# the Elixir release against Erlang/OTP 28 + Elixir 1.19, and a runtime
# stage copies the release artifacts onto a slim Debian base.
#
# Wedge-B compromises that should be revisited before G3:
#   - SECRET_KEY_BASE is auto-generated at container start if not
#     provided. Acceptable while there are no real sessions; replace
#     with a Secret-backed env var when session continuity matters.
#   - Single-replica deploy (k8s/deployment.yaml). Auto-generated
#     SECRET_KEY_BASE would break multi-replica session cookies.

FROM hexpm/elixir:1.19.5-erlang-28.0.1-debian-bookworm-20250630-slim AS build

ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
 && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod \
 && mix deps.compile

COPY config ./config
COPY lib ./lib
COPY priv ./priv

RUN mix compile \
 && mix release

# ---

FROM debian:bookworm-slim AS runtime

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    PHX_HOST=guild.inevitable.fyi

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/_build/prod/rel/guild ./

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--"]
# SECRET_KEY_BASE: generated via openssl rather than `bin/guild eval`
# because runtime.exs requires DATABASE_URL during boot — fine for the
# subsequent `eval Guild.Release.migrate()` (DATABASE_URL is in env via
# the k8s Deployment) but a chicken-and-egg for generating the secret
# itself.
CMD ["/bin/sh", "-c", "export SECRET_KEY_BASE=${SECRET_KEY_BASE:-$(openssl rand -base64 64 | tr -d '\\n')} && /app/bin/guild eval 'Guild.Release.migrate()' && exec /app/bin/guild start"]
