# syntax=docker/dockerfile:1.7
#
# Corporate webMethods Microservices Runtime (MSR) base image.
#
# Two variants are produced from this single multi-stage Dockerfile:
#   --target prod  -> wm-msr-base       (lean; ships to production)
#   --target test  -> wm-msr-base-test  (prod + UTF + Ant + JDK; used by CI)
#
# Build (prod):
#   docker build --target prod \
#     --build-arg MSR_BASE_IMAGE=ibmwebmethods.azurecr.io/webmethods-microservicesruntime \
#     --build-arg MSR_VERSION=12.1 \
#     --build-arg WM_MCP_SERVER_URL=https://corporate-mirror/.../wm-mcp \
#     -t wm-msr-base:12.1 docker/base
#
# Build (test):
#   docker build --target test \
#     --build-arg MSR_BASE_IMAGE=ibmwebmethods.azurecr.io/webmethods-microservicesruntime \
#     --build-arg MSR_VERSION=12.1 \
#     --build-arg WM_MCP_SERVER_URL=https://corporate-mirror/.../wm-mcp \
#     --build-arg WM_TEST_SUITE_INSTALLER_URL=https://corporate-mirror/.../wm-test-suite.zip \
#     -t wm-msr-base-test:12.1 docker/base
#
# Build args MSR_BASE_IMAGE / MSR_VERSION / etc. default to the values
# pinned in ../../versions.env. CI sources that file and forwards them
# via --build-arg so this Dockerfile and the rest of the pipeline agree.
#
# Prereq: the IBM MSR image is hosted at ibmwebmethods.azurecr.io.
# Mint a registry token at https://containers.webmethods.io (sign in
# with IBMid; w3id SSO for IBM employees), then:
#   docker login -u <token-name> -p <token-password> ibmwebmethods.azurecr.io
# The build's first FROM line will 401 without a valid login. Tag
# convention: :12.1 floats to the latest core fix; pin to :12.1.0.X
# for reproducible production builds.

ARG MSR_BASE_IMAGE=ibmwebmethods.azurecr.io/webmethods-microservicesruntime
ARG MSR_VERSION=12.1
ARG WM_MCP_SERVER_VERSION=v1.0.0

# ---------------------------------------------------------------------
# Stage: wm-mcp-fetch
# Pull the wm-mcp-server CLI from the corporate mirror (or upstream
# releases) into a tiny scratch-like layer, so the final image stays
# self-contained but only the binary -- not curl/ca-certificates --
# ends up in the runtime layers.
# ---------------------------------------------------------------------
FROM alpine:3.19 AS wm-mcp-fetch
ARG WM_MCP_SERVER_VERSION
# v2+ asset naming: wm-mcp-server-linux-{x86_64,aarch64}.
# Override WM_MCP_SERVER_URL for arm64 builds.
ARG WM_MCP_SERVER_URL=https://github.com/cpoder/wm-mcp-server/releases/download/${WM_MCP_SERVER_VERSION}/wm-mcp-server-linux-x86_64
# Ephemeral fetch layer; nothing here ends up in the final image, so
# pinning apk package versions would create churn for no benefit.
# hadolint ignore=DL3018
RUN apk add --no-cache curl ca-certificates && \
    mkdir -p /out && \
    curl -fsSL --retry 3 "${WM_MCP_SERVER_URL}" -o /out/wm-mcp && \
    chmod 0755 /out/wm-mcp

# ---------------------------------------------------------------------
# Stage: prod  ->  wm-msr-base
# Lean MSR image: OS patches + shared JDBC drivers + wm-mcp helper.
# No UTF, no Ant, no JDK -- this is what flows to production.
# ---------------------------------------------------------------------
FROM ${MSR_BASE_IMAGE}:${MSR_VERSION} AS prod

# ARGs reset across stages, so re-declare what we use in LABELs/ENV.
ARG MSR_BASE_IMAGE
ARG MSR_VERSION
ARG IMAGE_REVISION=unknown

LABEL org.opencontainers.image.title="wm-msr-base" \
      org.opencontainers.image.description="Corporate webMethods MSR base image (lean, no UTF)" \
      org.opencontainers.image.source="https://github.com/cpoder/wmcicd" \
      org.opencontainers.image.version="${MSR_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.vendor="Corporate Integration Team" \
      org.opencontainers.image.licenses="Proprietary" \
      org.opencontainers.image.base.name="${MSR_BASE_IMAGE}:${MSR_VERSION}"

ENV SAG_HOME=/opt/softwareag \
    IS_INSTANCE_DIR=/opt/softwareag/IntegrationServer/instances/default

USER root

# OS-level updates. IBM MSR is built on Red Hat UBI, so microdnf is the
# package manager (NOT apt). Keep installed extras minimal -- every
# byte adds CVE surface.
RUN microdnf update -y && \
    microdnf clean all && \
    rm -rf /var/cache/yum /var/cache/dnf /tmp/*

# Shared JDBC drivers (Oracle, Postgres, MSSQL, ...). The jars/
# directory is empty in source control (see jars/.gitkeep) and is
# populated by CI from the corporate artifact repository before
# `docker build`. Drivers land where WmJDBCAdapter expects them on
# first start of the IS instance.
RUN install -d -o sagadmin -g sagadmin \
        ${IS_INSTANCE_DIR}/packages/WmJDBCAdapter/code/jars
COPY --chown=sagadmin:sagadmin jars/ \
        ${IS_INSTANCE_DIR}/packages/WmJDBCAdapter/code/jars/

# wm-mcp-server CLI -- lets the running container self-administer
# (list/install packages, run admin operations) without external
# tooling. Brought in from the wm-mcp-fetch stage to avoid leaking
# curl/ca-certs into the runtime layers.
COPY --from=wm-mcp-fetch /out/wm-mcp /usr/local/bin/wm-mcp

# Drop privileges. The upstream MSR image already provides the
# `sagadmin` non-root user; we just switch to it.
USER sagadmin

EXPOSE 5555 9999

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fs http://localhost:5555/invoke/wm.server:ping || exit 1

# CMD/ENTRYPOINT are inherited from the upstream MSR image on purpose:
# IBM's startup contract (license check, instance bootstrap, signal
# handling) must continue to apply unchanged. Don't override here.

# ---------------------------------------------------------------------
# Stage: test  ->  wm-msr-base-test
# prod + IBM webMethods Integration Test Suite (UTF) + Apache Ant + JDK.
# This is what CI uses to run unit tests against exactly the same
# package set that ships to prod -- only the surrounding image
# differs, never the package code.
# ---------------------------------------------------------------------
FROM prod AS test

ARG MSR_VERSION
ARG IMAGE_REVISION=unknown
ARG JAVA_VERSION=17
ARG ANT_VERSION=1.10.14
ARG WM_TEST_SUITE_VERSION=12.1
# Required at build time for the test variant. No default: a missing
# value should fail the build loudly (a wrong/stale URL silently
# producing a broken test image is worse than a hard error).
ARG WM_TEST_SUITE_INSTALLER_URL

LABEL org.opencontainers.image.title="wm-msr-base-test" \
      org.opencontainers.image.description="MSR base image with UTF + Ant + JDK for CI testing" \
      org.opencontainers.image.version="${MSR_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}"

USER root

# JDK (for compiling/running test step definitions) + unzip/tar (for
# the UTF installer) + procps-ng (for ant fork JVMs). Versions track
# whatever the UBI repo currently ships -- pinning here would freeze
# us on out-of-date packages and defeat the OS-update step in `prod`.
# hadolint ignore=DL3041
RUN microdnf install -y --nodocs \
        "java-${JAVA_VERSION}-openjdk-devel" \
        unzip tar gzip procps-ng && \
    microdnf clean all && \
    rm -rf /var/cache/yum /var/cache/dnf /tmp/*

# Apache Ant -- pinned, fetched from the official archive. The UTF
# Composite Runner is invoked via Ant.
RUN curl -fsSL --retry 3 \
        "https://archive.apache.org/dist/ant/binaries/apache-ant-${ANT_VERSION}-bin.tar.gz" \
        -o /tmp/ant.tar.gz && \
    tar -xzf /tmp/ant.tar.gz -C /opt && \
    ln -s "/opt/apache-ant-${ANT_VERSION}" /opt/ant && \
    ln -s /opt/ant/bin/ant /usr/local/bin/ant && \
    rm /tmp/ant.tar.gz
ENV ANT_HOME=/opt/ant \
    PATH=/opt/ant/bin:${PATH}

# IBM webMethods Integration Test Suite (UTF). The installer URL must
# point at the corporate mirror or a verified IBM Passport download.
# Drops the WmTestSuite package into the IS instance and the Ant
# runner JARs into /opt/softwareag/common/lib/ext/.
RUN test -n "${WM_TEST_SUITE_INSTALLER_URL}" || \
        ( echo "ERROR: --build-arg WM_TEST_SUITE_INSTALLER_URL is required for the test variant" >&2 && exit 1 ) && \
    mkdir -p /tmp/utf && \
    curl -fsSL --retry 3 "${WM_TEST_SUITE_INSTALLER_URL}" -o /tmp/utf/installer.zip && \
    unzip -q /tmp/utf/installer.zip -d /tmp/utf && \
    install -d -o sagadmin -g sagadmin "${SAG_HOME}/common/lib/ext" && \
    cp -r /tmp/utf/packages/WmTestSuite "${IS_INSTANCE_DIR}/packages/" && \
    cp /tmp/utf/lib/ext/*.jar "${SAG_HOME}/common/lib/ext/" && \
    chown -R sagadmin:sagadmin \
        "${IS_INSTANCE_DIR}/packages/WmTestSuite" \
        "${SAG_HOME}/common/lib/ext" && \
    rm -rf /tmp/utf

USER sagadmin
