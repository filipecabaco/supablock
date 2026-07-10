# Containerized supablock: a slim Alpine image that mounts your Supabase
# account inside the container and drops you into a shell at the mountpoint.
#
#   docker run -it --rm \
#     --device /dev/fuse --cap-add SYS_ADMIN \
#     --security-opt apparmor=unconfined \
#     -v supablock-config:/root/.config/supablock \
#     filipecabaco/supablock
#
# The first run starts the login flow (dashboard session flow: open a URL on
# the host, type the verification code); the credential lands in the mounted
# volume, so every later run goes straight to the mounted shell.
#
# CI builds and pushes this image to Docker Hub (filipecabaco/supablock) —
# see .github/workflows/docker.yml.

# --- Build stage -----------------------------------------------------------
# Matches the mise.toml toolchain pins (Erlang 27.3.x, Elixir 1.18.4).
FROM hexpm/elixir:1.18.4-erlang-27.3.4.14-alpine-3.22.5 AS build

# git: every dep is a pinned git tag (no hex.pm; see mix.exs).
# fuse3-dev + pkgconf: the efuse FUSE port is a small C program.
RUN apk add --no-cache build-base pkgconf git fuse3-dev

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Deps first, so source edits don't invalidate the fetched-deps layer.
# vendor/ holds the path deps (userfs, efuse, castore) mix.exs points at.
COPY mix.exs mix.lock ./
COPY vendor vendor
RUN mix deps.get

COPY config config
COPY rel rel
COPY lib lib

# Link libfuse3 dynamically: static linking exists so the *host* binary needs
# no FUSE package, which is pointless inside an image that controls its own
# runtime — the runtime stage installs fuse3.
RUN SUPABLOCK_STATIC_FUSE=0 mix release supablock

# Trim what a containerized, non-distributed node never uses — epmd (Erlang
# distribution) and heart (restart-on-hang watchdog; container runtimes own
# liveness) — and strip the native binaries. strip_beams already covers the
# BEAM files.
RUN cd /app/_build/prod/rel/supablock \
    && rm -f erts-*/bin/epmd erts-*/bin/heart \
    && (strip erts-*/bin/beam.smp erts-*/bin/erlexec erts-*/bin/erl_child_setup \
          erts-*/bin/inet_gethost lib/efuse-*/priv/efuse 2>/dev/null || true)

# --- Runtime stage ---------------------------------------------------------
# Same Alpine major as the builder so the musl/ssl libs match the release.
FROM alpine:3.22

# libfuse3 + fusermount3 for the port; libstdc++/libgcc (the JIT is C++),
# ncurses for the tty driver and libcrypto3 for the crypto NIF — the only
# piece of OpenSSL the BEAM links (Erlang's ssl app is Erlang code on top of
# it, so no libssl and no openssl CLI). ca-certificates for TLS trust.
# Busybox already provides the browsing toolkit (ls, cat, grep, find, diff).
RUN apk add --no-cache fuse3 libstdc++ libgcc ncurses-libs libcrypto3 ca-certificates

COPY --from=build /app/_build/prod/rel/supablock /opt/supablock
# The repo's thin launcher works unchanged: it resolves the release root from
# SUPABLOCK_RELEASE_ROOT and exports SUPABLOCK_BIN (used by `mount`'s
# background daemon to re-exec itself).
COPY bin/supablock /usr/local/bin/supablock
COPY docker/entrypoint.sh /usr/local/bin/supablock-entrypoint
RUN chmod +x /usr/local/bin/supablock /usr/local/bin/supablock-entrypoint

ENV SUPABLOCK_RELEASE_ROOT=/opt/supablock \
    SUPABLOCK_MOUNTPOINT=/supabase

# Credentials + config live here; mount a volume to persist them on the host:
#   -v supablock-config:/root/.config/supablock
# (No VOLUME directive on purpose: an implicit anonymous volume per run would
# hide the fact that nothing persists without the -v flag.)

ENTRYPOINT ["/usr/local/bin/supablock-entrypoint"]
