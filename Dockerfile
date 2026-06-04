# syntax=docker/dockerfile:1
# Parameterised by `dbs`:
#   SUITE            debian suite to target   (bookworm | trixie)
#   SYSROOT_PLATFORM emulated platform of the target sysroot (linux/arm64 | linux/arm/v7)
#   CROSS_PKG        cross toolchain meta-package (crossbuild-essential-arm64 | -armhf)
ARG SUITE=trixie
ARG SYSROOT_PLATFORM=linux/arm64

FROM --platform=${SYSROOT_PLATFORM} debian:${SUITE} AS sysroot
ARG SUITE
ARG DEB_ARCH=arm64
ENV DEBIAN_FRONTEND=noninteractive

RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
        > /etc/apt/apt.conf.d/keep-cache

RUN echo "deb [trusted=yes] http://archive.raspberrypi.com/debian/ ${SUITE} main" > /etc/apt/sources.list.d/raspi.list
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${SUITE}-${DEB_ARCH},sharing=locked \
    --mount=type=cache,target=/var/lib/apt,id=apt-lib-${SUITE}-${DEB_ARCH},sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends raspberrypi-archive-keyring
RUN echo "deb http://archive.raspberrypi.com/debian/ ${SUITE} main" > /etc/apt/sources.list.d/raspi.list

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${SUITE}-${DEB_ARCH},sharing=locked \
    --mount=type=cache,target=/var/lib/apt,id=apt-lib-${SUITE}-${DEB_ARCH},sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    devscripts \
    equivs \
    curl

RUN curl -fsSL https://droneproukr.github.io/droneprorepo/repo.key -o /etc/apt/trusted.gpg.d/droneprorepo.asc
RUN echo "deb https://droneproukr.github.io/droneprorepo/ ${SUITE} main" > /etc/apt/sources.list.d/droneprorepo.list

WORKDIR /workspace
COPY debian/control debian/control

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${SUITE}-${DEB_ARCH},sharing=locked \
    --mount=type=cache,target=/var/lib/apt,id=apt-lib-${SUITE}-${DEB_ARCH},sharing=locked \
    --mount=type=bind,source=localrepo,target=/localrepo,rw \
    set -e; \
    if ls /localrepo/*.deb >/dev/null 2>&1; then \
        echo "dbs: local repo: $(ls /localrepo/*.deb | wc -l) prebuilt package(s)"; \
        ( cd /localrepo && dpkg-scanpackages --multiversion . > Packages 2>/dev/null ); \
        sz=$(stat -c%s /localrepo/Packages); \
        { echo "Date: $(date -uR)"; \
          echo "MD5Sum:"; \
          echo " $(md5sum /localrepo/Packages | cut -d' ' -f1) $sz Packages"; \
          echo "SHA256:"; \
          echo " $(sha256sum /localrepo/Packages | cut -d' ' -f1) $sz Packages"; \
        } > /localrepo/Release; \
        echo "deb [trusted=yes] file:/localrepo ./" > /etc/apt/sources.list.d/dbs-localrepo.list; \
    fi; \
    apt-get update && \
    mk-build-deps -i -r -t 'apt-get -y --no-install-recommends' debian/control; \
    rm -f /etc/apt/sources.list.d/dbs-localrepo.list

FROM debian:${SUITE} AS cross
ARG SUITE
ARG CROSS_PKG=crossbuild-essential-arm64

ARG HOST_DEPS=
ENV DEBIAN_FRONTEND=noninteractive

RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
        > /etc/apt/apt.conf.d/keep-cache

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${SUITE}-buildhost,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,id=apt-lib-${SUITE}-buildhost,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ${CROSS_PKG} \
    cmake \
    debhelper \
    devscripts \
    dpkg-dev \
    equivs \
    ninja-build \
    pkgconf \
    symlinks

COPY aarch64-linux-gnu-pkg-config /usr/bin/aarch64-linux-gnu-pkg-config
COPY arm-linux-gnueabihf-pkg-config /usr/bin/arm-linux-gnueabihf-pkg-config

COPY --from=sysroot / /sysroot
RUN symlinks -cr /sysroot >/dev/null 2>&1 || true; \
    find /sysroot -type l | while read -r l; do \
        t="$(readlink "$l")"; \
        case "$t" in \
            /sysroot/*) : ;; \
            /*) ln -sfn "/sysroot$t" "$l" ;; \
        esac; \
    done

COPY rpi-arm64.toolchain.cmake /opt/rpi-arm64.toolchain.cmake
COPY rpi-armhf.toolchain.cmake /opt/rpi-armhf.toolchain.cmake
COPY crossbuild /usr/bin/crossbuild

COPY dbs-host-deps /usr/local/bin/dbs-host-deps
COPY debian/control /tmp/control
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${SUITE}-buildhost,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,id=apt-lib-${SUITE}-buildhost,sharing=locked \
    apt-get update && \
    host_deps="$(dbs-host-deps /tmp/control)" && \
    echo "dbs: auto host tooling : ${host_deps:-<none>}" && \
    echo "dbs: extra host tooling: ${HOST_DEPS:-<none>}" && \
    if [ -n "$HOST_DEPS" ]; then \
        names="$(apt-cache pkgnames)" && \
        for p in $HOST_DEPS; do \
            printf '%s\n' "$names" | grep -Fxq "$p" || \
                { echo "dbs: host-dep '$p' is not a package in the build-host archive (Debian main)" >&2; exit 1; }; \
        done; \
    fi && \
    if [ -n "$host_deps$HOST_DEPS" ]; then \
        apt-get install -y --no-install-recommends $host_deps $HOST_DEPS; \
    fi && \
    rm -f /tmp/control

WORKDIR /workspace
ENTRYPOINT ["/usr/bin/crossbuild"]

# --------------------------------------------------------------------------
# Native build target  (dbs --native)
# --------------------------------------------------------------------------
FROM sysroot AS native

ARG SUITE
ARG DEB_ARCH=arm64
ARG HOST_DEPS=
ENV DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${SUITE}-${DEB_ARCH},sharing=locked \
    --mount=type=cache,target=/var/lib/apt,id=apt-lib-${SUITE}-${DEB_ARCH},sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    debhelper \
    dpkg-dev \
    ninja-build \
    pkgconf

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-${SUITE}-${DEB_ARCH},sharing=locked \
    --mount=type=cache,target=/var/lib/apt,id=apt-lib-${SUITE}-${DEB_ARCH},sharing=locked \
    if [ -n "$HOST_DEPS" ]; then \
        apt-get update && \
        names="$(apt-cache pkgnames)" && \
        for p in $HOST_DEPS; do \
            printf '%s\n' "$names" | grep -Fxq "$p" || \
                { echo "dbs: host-dep '$p' is not a package in the target archives (Debian/Pi/droneprorepo)" >&2; exit 1; }; \
        done && \
        apt-get install -y --no-install-recommends $HOST_DEPS; \
    fi

COPY crossbuild /usr/bin/crossbuild
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/crossbuild"]
