# syntax=docker/dockerfile:1.7
#
# Per-microservice image. Bakes the IS packages from packages/ into the
# corporate MSR base image so the runtime starts with every package
# already enabled -- no boot-time install, no admin REST call, no
# package_install on startup.
#
# Build (run from the repo root, since the build context must include
# scripts/, packages/, and versions.env):
#
#   docker build \
#     -f docker/service/Dockerfile \
#     --build-arg BASE_IMAGE=ghcr.io/<owner>/wm-msr-base:11.1.0-base-<sha7> \
#     --build-arg GIT_SHA=$(git rev-parse HEAD) \
#     --build-arg BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
#     -t wm-svc:dev .
#
# IMPORTANT: BASE_IMAGE must be a SHA-pinned tag emitted by the
# base-image workflow (e.g. wm-msr-base:11.1.0-base-abcdef0). Never
# pass a `*-latest` ref -- the whole point of the per-service image is
# reproducibility against a frozen base.

# ---------------------------------------------------------------------
# Stage 1: builder
# Run scripts/build-packages.sh to produce dist/<P>-<version>.zip for
# every package under packages/, then expand the zips into a staging
# tree the runtime stage can COPY directly. Unpacking here (rather
# than in the runtime image) keeps unzip / python3 / jq out of the
# final image and preserves the lean prod base.
#
# eclipse-temurin:17-jre keeps the builder on the same Java major
# version as the runtime, which matters for any Java helper a future
# build step might emit (descriptor compilation, annotation
# post-processing, etc.).
# ---------------------------------------------------------------------
FROM eclipse-temurin:17-jre AS builder

# build-packages.sh requires python3, jq, sha256sum (coreutils is
# already present in the debian-slim base, so only python3 + jq are
# missing). unzip is for the staging-tree expansion below.
# --no-install-recommends keeps this throwaway layer minimal even
# though it never reaches the final image.
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 jq unzip && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Only copy what build-packages.sh actually reads. Avoiding `COPY . .`
# keeps the builder cache stable across edits to docs/, helm/, config/,
# tests/, etc.
COPY scripts/ scripts/
COPY packages/ packages/

# Produce dist/<P>-<version>.zip + dist/manifest.json (Phase 2.1
# script). --clean is a no-op in a fresh stage but documents intent.
# Then expand each zip into /staging/packages/<PackageName>/...,
# matching the IS packages-dir layout. `find -exec` is used over a
# bash-only loop so this RUN is portable to /bin/sh.
RUN set -eux; \
    ./scripts/build-packages.sh --clean; \
    mkdir -p /staging/packages; \
    find /workspace/dist -maxdepth 1 -type f -name '*.zip' \
        -exec unzip -q -o {} -d /staging/packages \;


# ---------------------------------------------------------------------
# Stage 2: runtime
# Layer the unpacked packages on top of the corporate MSR base. The
# base ref MUST be a SHA-pinned tag (`${MSR_VERSION}-base-<sha7>`)
# from the base-image workflow so this image is reproducible against
# a frozen base. CI computes and forwards the pinned ref; humans paste
# it from the base-image job summary.
# ---------------------------------------------------------------------
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# ARGs reset across stages -- redeclare what we use in LABELs.
ARG BASE_IMAGE
ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown

LABEL org.opencontainers.image.title="wm-svc" \
      org.opencontainers.image.description="webMethods microservice image with IS packages baked in" \
      org.opencontainers.image.source="https://github.com/cpoder/wmcicd" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.vendor="Corporate Integration Team" \
      org.opencontainers.image.licenses="Proprietary" \
      org.opencontainers.image.base.name="${BASE_IMAGE}"

USER root

# Drop the unpacked packages into the IS packages directory. The base
# image (docker/base/Dockerfile) sets IS_INSTANCE_DIR to
# /opt/softwareag/IntegrationServer/instances/default and already
# manages WmJDBCAdapter under ${IS_INSTANCE_DIR}/packages/, so the
# task-spec path `/opt/softwareag/IntegrationServer/packages/` is
# resolved through that env var to keep all packages co-located in
# the multi-instance layout the upstream IBM MSR image uses. IS
# auto-loads every subdirectory at startup, so the runtime sees each
# package as ENABLED without any install step.
COPY --from=builder --chown=sagadmin:sagadmin \
        /staging/packages/ \
        ${IS_INSTANCE_DIR}/packages/

USER sagadmin

# CMD / ENTRYPOINT / EXPOSE / HEALTHCHECK are inherited from the base
# image on purpose. IBM's startup contract (license check, instance
# bootstrap, signal handling) and the base's healthcheck (curl
# /invoke/wm.server:ping) must continue to apply unchanged --
# duplicating any of that here only invites drift.
