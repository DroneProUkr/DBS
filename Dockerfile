# Parameterised by `dbs`:
#   SUITE            debian suite to target   (bookworm | trixie)
#   SYSROOT_PLATFORM emulated platform of the target sysroot (linux/arm64 | linux/arm/v7)
#   CROSS_PKG        cross toolchain meta-package (crossbuild-essential-arm64 | -armhf)
ARG SUITE=trixie
ARG SYSROOT_PLATFORM=linux/arm64

FROM --platform=${SYSROOT_PLATFORM} debian:${SUITE} AS sysroot
ARG SUITE
ENV DEBIAN_FRONTEND=noninteractive

RUN echo "deb [trusted=yes] http://archive.raspberrypi.com/debian/ ${SUITE} main" > /etc/apt/sources.list.d/raspi.list
RUN apt-get update && \
    apt-get install -y --no-install-recommends raspberrypi-archive-keyring && \
 rm -rf /var/lib/apt/lists/*
RUN echo "deb http://archive.raspberrypi.com/debian/ ${SUITE} main" > /etc/apt/sources.list.d/raspi.list

RUN apt-get update && apt-get install -y --no-install-recommends \
    devscripts \
    equivs \
    curl \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://zarcsis.github.io/dronerepo/repo.key | tee /etc/apt/trusted.gpg.d/dronerepo.asc
RUN echo "deb https://zarcsis.github.io/dronerepo/ ${SUITE} main" > /etc/apt/sources.list.d/dronerepo.list

WORKDIR /workspace
COPY debian/control debian/control
RUN apt-get update && mk-build-deps -i -r -t 'apt-get -y --no-install-recommends' debian/control

FROM debian:${SUITE} AS cross
ARG SUITE
ARG CROSS_PKG=crossbuild-essential-arm64

ARG HOST_DEPS=
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ${CROSS_PKG} \
    cmake \
    debhelper \
    devscripts \
    dpkg-dev \
    equivs \
    ninja-build \
    pkgconf \
    symlinks \
 && rm -rf /var/lib/apt/lists/*

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
RUN apt-get update && \
    host_deps="$(dbs-host-deps /tmp/control)" && \
    echo "dbs: auto host tooling : ${host_deps:-<none>}" && \
    echo "dbs: extra host tooling: ${HOST_DEPS:-<none>}" && \
    # Reject a user --host-deps that is not an exact package name. apt-get
    # otherwise treats a name containing '.' as a POSIX regex when no literal
    # package matches, so a typo like 'protobuf.' silently substring-installs
    # dozens of unrelated packages instead of failing. dbs validated the token
    # shape; this validates existence in the archive the deps install from.
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
    rm -rf /var/lib/apt/lists/* /tmp/control

WORKDIR /workspace
ENTRYPOINT ["/usr/bin/crossbuild"]

# --------------------------------------------------------------------------
# Native build target  (dbs --native)
# --------------------------------------------------------------------------
FROM sysroot AS native
ARG HOST_DEPS=
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    debhelper \
    dpkg-dev \
    ninja-build \
    pkgconf \
 && rm -rf /var/lib/apt/lists/*

RUN if [ -n "$HOST_DEPS" ]; then \
        apt-get update && \
        names="$(apt-cache pkgnames)" && \
        for p in $HOST_DEPS; do \
            printf '%s\n' "$names" | grep -Fxq "$p" || \
                { echo "dbs: host-dep '$p' is not a package in the target archives (Debian/Pi/dronerepo)" >&2; exit 1; }; \
        done && \
        apt-get install -y --no-install-recommends $HOST_DEPS && \
        rm -rf /var/lib/apt/lists/*; \
    fi

COPY crossbuild /usr/bin/crossbuild
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/crossbuild"]
