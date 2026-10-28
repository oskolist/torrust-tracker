# syntax=docker/dockerfile:latest
#
# semantic-links:
#   skill-links:
#     - add-workspace-member
#   related-artifacts:
#     - Cargo.toml  # `[workspace] default-members` is the positive list of packages tested in the image
#     - .dockerignore  # allow-list of the build context; every workspace member must be admitted
#     - .hadolint.yaml  # hadolint global linting rules and ignore policies with rationale

# Torrust Tracker — multi-platform image, cross-compiled with cargo-zigbuild (no QEMU for compiling)
#
#   docker buildx build --platform linux/amd64,linux/arm64 --target release .
#
# Everything that compiles or packages runs on $BUILDPLATFORM. The only step that
# ever runs on $TARGETPLATFORM is the `test*` stages (they execute the cross-compiled
# test binaries). For a foreign architecture that needs binfmt/QEMU, so it can be
# switched off without touching the rest of the build:
#
#   --build-arg TEST_GATE_RELEASE=test_skipped --build-arg TEST_GATE_DEBUG=test_skipped

ARG TORRUST_CARGO_CHEF_VERSION=0.1.78
ARG CARGO_NEXTEST_VERSION=0.9.140
ARG CARGO_ZIGBUILD_VERSION=0.24.0
# Version of the `ziglang` PyPI package (ships the zig toolchain). Bump together with cargo-zigbuild.
ARG ZIG_VERSION=0.15.1

# Which stage must succeed before the release/debug artifacts are packaged.
# `test_*_passed` = run the tests (on $TARGETPLATFORM); `test_skipped` = don't.
ARG TEST_GATE_DEBUG=test_debug_passed
ARG TEST_GATE_RELEASE=test_release_passed

###############################################################################
## Builder toolchain (runs on the BUILD platform; shared by every target arch)
###############################################################################
FROM --platform=$BUILDPLATFORM docker.io/library/rust:slim-trixie AS chef
WORKDIR /tmp

# Slowest-changing layers first. Each tool has its own ARG + RUN, so bumping one
# version only invalidates that tool's layer and the ones after it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl pkg-config python3 python3-venv \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION
RUN python3 -m venv /opt/zig \
 && /opt/zig/bin/pip install --no-cache-dir "ziglang==${ZIG_VERSION}"
ENV PATH="/opt/zig/bin:${PATH}" \
    CARGO_ZIGBUILD_PYTHON_PATH=/opt/zig/bin/python \
    ZIG_GLOBAL_CACHE_DIR=/cache/zig

RUN curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash

# Note: We use the `torrust-cargo-chef` fork while upstream PR
# https://github.com/LukeMathWalker/cargo-chef/pull/360 is pending. Once merged,
# switch back to upstream `cargo-chef` and remove this comment.
ARG TORRUST_CARGO_CHEF_VERSION
RUN cargo binstall --no-confirm --locked "torrust-cargo-chef@${TORRUST_CARGO_CHEF_VERSION}"

ARG CARGO_NEXTEST_VERSION
RUN cargo binstall --no-confirm --locked "cargo-nextest@${CARGO_NEXTEST_VERSION}"

ARG CARGO_ZIGBUILD_VERSION
RUN cargo binstall --no-confirm --locked "cargo-zigbuild@${CARGO_ZIGBUILD_VERSION}"

# `cargo nextest archive` builds through `$CARGO test --no-run`. This shim sends that one
# call through `cargo-zigbuild` and forwards everything else (metadata, -vV, ...) to the
# real cargo. Use it ONLY as `CARGO=... cargo-nextest nextest ...` (never as a global ENV).
COPY --chmod=0755 <<"EOF" /usr/local/bin/cargo-nextest-zigbuild
#!/bin/sh
set -eu
REAL_CARGO=/usr/local/cargo/bin/cargo
if [ "${1:-}" = "test" ]; then
  export CARGO="$REAL_CARGO"   # avoid recursion: zigbuild must call the real cargo
  exec cargo-zigbuild "$@"
fi
exec "$REAL_CARGO" "$@"
EOF

###############################################################################
## Per-architecture toolchain selection (still BUILD platform, no emulation)
###############################################################################
FROM chef AS chef_amd64
ENV RUST_TARGET=x86_64-unknown-linux-gnu \
    ZIG_TARGET=x86_64-linux-gnu
RUN rustup target add "${RUST_TARGET}"

FROM chef AS chef_arm64
ENV RUST_TARGET=aarch64-unknown-linux-gnu \
    ZIG_TARGET=aarch64-linux-gnu
RUN rustup target add "${RUST_TARGET}"

# TARGETARCH is provided by buildx (amd64 | arm64)
FROM chef_${TARGETARCH} AS chef_target
WORKDIR /build/src

###############################################################################
## Chef Prepare (platform independent => shared by all target architectures)
###############################################################################
FROM chef AS recipe
WORKDIR /build/src
# Canonical cargo-chef planner stage: copy the whole (allow-listed, see .dockerignore)
# build context and let `cargo chef prepare` enumerate packages and targets itself.
# Cargo is the only source of truth for workspace packages; nothing is listed here.
#
# This layer is rebuilt on every source change, but `cargo chef prepare` costs well
# under a second and the downstream `COPY --from=recipe` steps are keyed on the
# content checksum of the recipe files, so identical recipes keep the cook layers
# cached (measured in issue #2298, scenarios M5 and M6).
COPY . /build/src
RUN cargo chef prepare --recipe-path /build/recipe.json
# Generate an external-only recipe for the third-party dependency layer.
# The `--external-only` flag strips all `path = "..."` dependency entries,
# producing a stable recipe that is immune to workspace-internal Cargo.toml
# changes (e.g., reorganising workspace members, renaming packages). The recipe
# still changes when external dependency metadata changes — for example, adding
# or removing a crate, updating a version, or toggling feature flags on external
# dependencies — regardless of whether Cargo.lock is modified.
# This is from the `torrust-cargo-chef` fork (see chef stage above).
RUN cargo chef prepare --external-only --recipe-path /build/recipe-thirdparty.json

###############################################################################
## Helpers (all BUILD platform)
###############################################################################

## nextest binary for the TARGET arch (downloaded, never executed here) – used by the test stages
FROM chef_target AS nextest_target
ARG CARGO_NEXTEST_VERSION
RUN cargo binstall --no-confirm --locked --disable-strategies compile \
      --targets "${RUST_TARGET}" --install-path /out/bin "cargo-nextest@${CARGO_NEXTEST_VERSION}"

## Su Exe Compile (cross-compiled with `zig cc`, replaces the former gcc stage)
FROM chef_target AS su_exec
COPY ./contrib/dev-tools/su-exec/ /usr/local/src/su-exec/
RUN --mount=type=cache,target=/cache/zig \
    python -m ziglang cc -target "${ZIG_TARGET}" -Wall -Werror -g \
      /usr/local/src/su-exec/su-exec.c -o /usr/local/bin/su-exec \
 && chmod +x /usr/local/bin/su-exec

## Database initialization: Tests at runtime require a pre-initialized SQLite3 database
# to test against a valid (not corrupted) schema. The VACUUM command optimizes the
# database file layout. The DB file is architecture independent, so it is created
# once on the build platform.
FROM --platform=$BUILDPLATFORM docker.io/library/debian:trixie-slim AS db_init
RUN apt-get update \
 && apt-get install -y --no-install-recommends sqlite3 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*
COPY ./share/ /app/share/torrust
RUN mkdir -p /app/share/torrust/default/database/ \
 && sqlite3 /app/share/torrust/default/database/tracker.sqlite3.db "VACUUM;"

## Runtime skeleton: replaces the `RUN cp -s` / `RUN mkdir` of the runtime stage so that
# no process ever has to execute inside the (foreign-arch) runtime image.
FROM --platform=$BUILDPLATFORM docker.io/library/debian:trixie-slim AS skeleton
RUN mkdir -p /skel/bin /skel/var/lib/torrust/tracker /skel/var/log/torrust/tracker /skel/etc/torrust/tracker \
 && for t in sh cat ls env; do ln -s "/busybox/$t" "/skel/bin/$t"; done

## Packager: assembles /app on the build platform (chown/chmod/readelf work on any arch)
FROM --platform=$BUILDPLATFORM docker.io/library/debian:trixie-slim AS packager
RUN apt-get update \
 && apt-get install -y --no-install-recommends binutils \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

###############################################################################
## Cook (debug)
###############################################################################
FROM chef_target AS dependencies_thirdparty_debug
WORKDIR /build/src
# Only third-party recipe: immune to workspace Cargo.toml changes.
COPY --from=recipe /build/recipe-thirdparty.json /build/recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cache/zig \
    cargo chef cook --zigbuild --target "${RUST_TARGET}" \
      --tests --workspace --all-features --recipe-path /build/recipe.json

FROM dependencies_thirdparty_debug AS dependencies_debug
WORKDIR /build/src
# Full recipe on top — reuses third-party artifacts from parent layer.
COPY --from=recipe /build/recipe.json /build/recipe.json
# `cargo chef cook` keeps `--workspace` so the skeleton covers every member the
# recipe enumerates. `cargo nextest archive` deliberately omits `--workspace`: it
# then builds only the root `[workspace] default-members` (the positive list of
# packages tested inside the image), so no per-package exclusions are needed here.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cache/zig \
    cargo chef cook --zigbuild --target "${RUST_TARGET}" \
      --tests --workspace --all-features --recipe-path /build/recipe.json
# Pre-link warm-up: Create and discard a nextest archive to warm up the linker
# before final compilation (see the shim in the chef stage for why CARGO is set).
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cache/zig \
    CARGO=/usr/local/bin/cargo-nextest-zigbuild cargo-nextest nextest archive \
      --target "${RUST_TARGET}" --tests --all-features \
      --archive-file /build/temp.tar.zst \
 && rm -f /build/temp.tar.zst

###############################################################################
## Cook (release)
###############################################################################
FROM chef_target AS dependencies_thirdparty
WORKDIR /build/src
# Only third-party recipe: immune to workspace Cargo.toml changes.
COPY --from=recipe /build/recipe-thirdparty.json /build/recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cache/zig \
    cargo chef cook --zigbuild --target "${RUST_TARGET}" \
      --tests --workspace --all-features --recipe-path /build/recipe.json --release

FROM dependencies_thirdparty AS dependencies
WORKDIR /build/src
# Full recipe on top — reuses third-party artifacts from parent layer.
COPY --from=recipe /build/recipe.json /build/recipe.json
# See Cook (debug) above for why cook uses `--workspace` and archive does not.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cache/zig \
    cargo chef cook --zigbuild --target "${RUST_TARGET}" \
      --tests --workspace --all-features --recipe-path /build/recipe.json --release
# Pre-link warm-up (see debug stage).
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cache/zig \
    CARGO=/usr/local/bin/cargo-nextest-zigbuild cargo-nextest nextest archive \
      --target "${RUST_TARGET}" --tests --all-features \
      --archive-file /build/temp.tar.zst --release \
 && rm -f /build/temp.tar.zst

###############################################################################
## Build Archive (debug) — cross-compiled on the BUILD platform
###############################################################################
FROM dependencies_debug AS build_debug
WORKDIR /build/src
COPY . /build/src
# 1) the nextest archive (consumed by the test stage, on the target platform)
# 2) the shippable binaries (same cargo profile/flags => reused from step 1, no recompile)
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cache/zig \
    CARGO=/usr/local/bin/cargo-nextest-zigbuild cargo-nextest nextest archive \
      --target "${RUST_TARGET}" --tests --all-features \
      --archive-file /build/torrust-tracker-debug.tar.zst \
 && cargo zigbuild --target "${RUST_TARGET}" --bins --all-features \
 && install -D -t /out/bin "target/${RUST_TARGET}/debug/torrust-tracker"

## Build Archive (release)
FROM dependencies AS build
WORKDIR /build/src
COPY . /build/src
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cache/zig \
    CARGO=/usr/local/bin/cargo-nextest-zigbuild cargo-nextest nextest archive \
      --target "${RUST_TARGET}" --tests --all-features \
      --archive-file /build/torrust-tracker.tar.zst --release \
 && cargo zigbuild --target "${RUST_TARGET}" --bins --all-features --release \
 && install -D -t /out/bin \
      "target/${RUST_TARGET}/release/torrust-tracker" \
      "target/${RUST_TARGET}/release/http_health_check"

###############################################################################
## Tester Image — the ONLY place that runs on $TARGETPLATFORM.
## No RUN here: nextest is a downloaded target-arch binary, the DB comes from db_init.
###############################################################################
FROM --platform=$TARGETPLATFORM docker.io/library/rust:slim-trixie AS tester
COPY --from=nextest_target /out/bin/cargo-nextest /usr/local/bin/cargo-nextest
COPY --from=db_init /app/share/ /app/share/

# Extract and Test (debug)
FROM tester AS test_debug
WORKDIR /test
COPY . /test/src/
COPY --from=build_debug \
  /build/torrust-tracker-debug.tar.zst \
  /test/torrust-tracker-debug.tar.zst
RUN cargo nextest run --workspace-remap /test/src/ --extract-to /test/src/ --no-run --archive-file /test/torrust-tracker-debug.tar.zst
# WORKDIR creates the directory without needing a RUN (replaces `mkdir -p`)
WORKDIR /test/src/storage/tracker/lib/database
WORKDIR /test
RUN cargo nextest run --workspace-remap /test/src/ --target-dir-remap /test/src/target/ --cargo-metadata /test/src/target/nextest/cargo-metadata.json --binaries-metadata /test/src/target/nextest/binaries-metadata.json

# Extract and Test (release)
FROM tester AS test
WORKDIR /test
COPY . /test/src
COPY --from=build \
  /build/torrust-tracker.tar.zst \
  /test/torrust-tracker.tar.zst
RUN cargo nextest run --workspace-remap /test/src/ --extract-to /test/src/ --no-run --archive-file /test/torrust-tracker.tar.zst
WORKDIR /test/src/storage/tracker/lib/database
WORKDIR /test
RUN cargo nextest run --workspace-remap /test/src/ --target-dir-remap /test/src/target/ --cargo-metadata /test/src/target/nextest/cargo-metadata.json --binaries-metadata /test/src/target/nextest/binaries-metadata.json

###############################################################################
## Test gates: packaging depends on one of these. Selected via TEST_GATE_* build args.
###############################################################################
FROM scratch AS test_debug_passed
COPY --from=test_debug /test/src/Cargo.toml /gate

FROM scratch AS test_release_passed
COPY --from=test /test/src/Cargo.toml /gate

FROM --platform=$BUILDPLATFORM docker.io/library/debian:trixie-slim AS test_skipped
RUN echo skipped > /gate

FROM ${TEST_GATE_DEBUG} AS debug_test_gate
FROM ${TEST_GATE_RELEASE} AS release_test_gate

###############################################################################
## Assemble /app (BUILD platform; tested == shipped binaries)
###############################################################################
FROM packager AS app_debug
COPY --from=debug_test_gate /gate /tmp/test-gate
COPY --from=db_init /app/share/ /app/share/
COPY --from=build_debug /out/bin/ /app/bin/
# Fail the build if the binary still wants a shared zlib (distroless has none).
RUN for b in /app/bin/*; do \
      readelf -d "$b" | grep NEEDED; \
      if readelf -d "$b" | grep -q 'libz\.so'; then echo "$b needs libz.so" >&2; exit 1; fi; \
    done \
 && chown -R root:root /app \
 && chmod -R u=rw,go=r,a+X /app \
 && chmod -R a+x /app/bin

FROM packager AS app_release
COPY --from=release_test_gate /gate /tmp/test-gate
COPY --from=db_init /app/share/ /app/share/
COPY --from=build /out/bin/ /app/bin/
RUN for b in /app/bin/*; do \
      readelf -d "$b" | grep NEEDED; \
      if readelf -d "$b" | grep -q 'libz\.so'; then echo "$b needs libz.so" >&2; exit 1; fi; \
    done \
 && chown -R root:root /app \
 && chmod -R u=rw,go=r,a+X /app \
 && chmod -R a+x /app/bin \
 && rm -rf /app/share/torrust/default/database

###############################################################################
## Runtime (TARGET platform image, but with ZERO `RUN` instructions => no emulation)
###############################################################################
FROM gcr.io/distroless/cc-debian13:debug AS runtime
# busybox symlinks in /bin and the torrust directories come from the build-platform skeleton
COPY --from=skeleton /skel/bin/ /bin/
COPY --from=skeleton /skel/var/ /var/
COPY --from=skeleton /skel/etc/ /etc/
COPY --from=su_exec --chmod=0555 /usr/local/bin/su-exec /bin/su-exec

ARG TORRUST_TRACKER_CONFIG_TOML_PATH="/etc/torrust/tracker/tracker.toml"
ARG USER_ID=1000
ARG UDP_PORT=6969
ARG HTTP_PORT=7070
ARG API_PORT=1212
ARG HEALTH_CHECK_API_PORT=1313

ENV TORRUST_TRACKER_CONFIG_TOML_PATH=${TORRUST_TRACKER_CONFIG_TOML_PATH}
ENV USER_ID=${USER_ID}
ENV UDP_PORT=${UDP_PORT}
ENV HTTP_PORT=${HTTP_PORT}
ENV API_PORT=${API_PORT}
ENV HEALTH_CHECK_API_PORT=${HEALTH_CHECK_API_PORT}
ENV TZ=Etc/UTC

EXPOSE ${UDP_PORT}/udp
EXPOSE ${HTTP_PORT}/tcp
EXPOSE ${API_PORT}/tcp
EXPOSE ${HEALTH_CHECK_API_PORT}/tcp

ENV ENV=/etc/profile
COPY --chmod=0555 ./share/container/entry_script_sh /usr/local/bin/entry.sh

VOLUME ["/var/lib/torrust/tracker","/var/log/torrust/tracker","/etc/torrust/tracker"]

ENV RUNTIME="runtime"
ENTRYPOINT ["/usr/local/bin/entry.sh"]


## Torrust-Tracker (debug)
FROM runtime AS debug
ENV RUNTIME="debug"
COPY --from=app_debug /app/ /usr/
CMD ["sh"]

## Torrust-Tracker (release) (default)
FROM runtime AS release
ENV RUNTIME="release"
COPY --from=app_release /app/ /usr/
HEALTHCHECK --interval=5s --timeout=5s --start-period=3s --retries=3 \
  CMD /usr/bin/http_health_check http://localhost:${HEALTH_CHECK_API_PORT}/health_check \
    || exit 1
CMD ["/usr/bin/torrust-tracker"]
