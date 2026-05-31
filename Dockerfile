ARG SYSROOT_PLATFORM=linux/arm64
FROM --platform=${SYSROOT_PLATFORM} debian:trixie AS sysroot
ENV DEBIAN_FRONTEND=noninteractive

RUN echo "deb [trusted=yes] http://archive.raspberrypi.com/debian/ trixie main" > /etc/apt/sources.list.d/raspi.list
RUN apt-get update && \
    apt-get install -y --no-install-recommends raspberrypi-archive-keyring && \
 rm -rf /var/lib/apt/lists/*
RUN echo "deb http://archive.raspberrypi.com/debian/ trixie main" > /etc/apt/sources.list.d/raspi.list

RUN apt-get update && apt-get install -y --no-install-recommends \
    devscripts \
    equivs \
    curl \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://zarcsis.github.io/dronerepo/repo.key | tee /etc/apt/trusted.gpg.d/dronerepo.asc
RUN echo "deb https://zarcsis.github.io/dronerepo/ trixie main" > /etc/apt/sources.list.d/dronerepo.list

WORKDIR /workspace
COPY debian/control debian/control
RUN apt-get update && mk-build-deps -i -r -t 'apt-get -y --no-install-recommends' debian/control

FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    crossbuild-essential-arm64 \
    cmake \
    debhelper \
    devscripts \
    dpkg-dev \
    pkgconf \
    symlinks \
 && rm -rf /var/lib/apt/lists/*

COPY aarch64-linux-gnu-pkg-config /usr/bin/aarch64-linux-gnu-pkg-config

COPY --from=sysroot / /sysroot
RUN symlinks -cr /sysroot >/dev/null 2>&1 || true

COPY rpi-arm64.toolchain.cmake /opt/rpi-arm64.toolchain.cmake
COPY crossbuild /usr/bin/crossbuild

WORKDIR /workspace
ENTRYPOINT ["/usr/bin/crossbuild"]
