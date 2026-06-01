# dbs — Drone Build System

Cross-build Debian packages (`.deb`) for Raspberry Pi ARM targets from an
amd64 host, using Docker. Point it at a project that ships a `debian/`
directory and it produces installable packages for **arm64** and **armhf**
against **bookworm** or **trixie** — no native ARM hardware required.

The project tree on disk is never modified: the changelog and source format
are synthesised into a private build tree inside the container, and the only
thing written back is the `out/` directory of finished packages.

---

## What it does

```
  host (amd64)                         docker
  ──────────────────────────────────────────────────────────────────────
  dbs                                  ┌─ sysroot stage (emulated ARM) ──┐
   ├─ parse --dist / --arch            │  debian:<suite> + raspberrypi   │
   ├─ synthesise debian/changelog ─────│  + dronerepo apt repos          │
   │   from git (dbs-changelog)        │  mk-build-deps from control     │
   ├─ assemble docker context          └─────────────┬───────────────────┘
   ├─ docker build  ──────────────────┐              │ COPY / → /sysroot
   │                                  ▼              ▼
   └─ docker run    ──────────  build stage (amd64 + cross toolchain)
        -v PROJECT:/workspace          crossbuild (ENTRYPOINT):
                                         dpkg-buildpackage --host-arch …
                                         → out/<dist>/<arch>/*.deb
```

1. **Sysroot stage** — an *emulated* ARM `debian:<suite>` image (via QEMU)
   with the [Raspberry Pi](http://archive.raspberrypi.com/debian/) and
   [dronerepo](https://zarcsis.github.io/dronerepo/) apt repositories added,
   into which your project's `Build-Depends` are installed with
   `mk-build-deps`. This becomes the target `/sysroot`.
2. **Build stage** — a native amd64 image holding the cross-compilers
   (`crossbuild-essential-arm64` / `-armhf`), CMake, debhelper and the sysroot
   copied from stage 1. Cross-aware `pkg-config` wrappers and CMake toolchain
   files point every lookup at `/sysroot`.
3. **crossbuild** (the container entrypoint) copies your bind-mounted
   workspace into `/build/src`, runs `dpkg-buildpackage -b --host-arch <arch>`,
   and drops the resulting `.deb`s into `out/<dist>/<arch>/`.

---

## Requirements

On the **host** (tested on WSL2 / amd64):

- **Docker** with multi-platform (QEMU/binfmt) emulation enabled — the sysroot
  stage runs ARM images on an amd64 host.
- **Python 3** with **GitPython** — used to synthesise the changelog from git:
  ```sh
  sudo apt install python3-git
  ```
  > GitPython is intentionally an apt (distro) package. The host's Python is
  > PEP-668 externally-managed, so avoid `pip --break-system-packages`; a
  > user-site pip copy in `~/.local/...` would shadow the apt package and must
  > be removed if present.
- **git** binary (for tag/commit metadata).

The cross toolchain, CMake, debhelper, etc. live *inside* the Docker image —
you do **not** need them on the host.

## Installation

One-liner — clones DBS into `~/bin`, symlinks the CLI, adds `~/bin` to your
`PATH` (via `~/.bashrc`) if it isn't there already, and reports any missing
runtime dependencies:

```sh
curl -fsSL https://raw.githubusercontent.com/zarcsis/DBS/main/install.sh | sh
```

It's safe to re-run: an existing checkout is updated with `git pull` instead
of re-cloned. To install somewhere other than `~/bin`, set `DBS_BIN_DIR`.

`dbs` finds its helper files relative to itself, so the symlink is all it
needs. The manual equivalent:

```sh
mkdir -p ~/bin                       # assuming ~/bin is on PATH
cd ~/bin
git clone https://github.com/zarcsis/DBS.git
ln -s DBS/dbs .                      # ~/bin/dbs -> DBS/dbs
```

---

## Usage

### Scaffold a new project

```sh
dbs init [DIR]
```

Creates a minimal, buildable `debian/` in `DIR` (default: the current
directory):

- `debian/control` — source/binary stanza; the package name is the directory's
  basename, sanitised to a valid Debian name (lowercase `[a-z0-9][a-z0-9+.-]+`).
  **Edit this** to describe the package and list its `Build-Depends`.
- `debian/rules` — a one-line `dh $@` rules file.

No `debian/changelog` and no `debian/source/format` are written — `dbs`
synthesises both at build time, keeping the project tree minimal.

### Build

```sh
dbs [PROJECT_DIR] [options] [-- docker-build-args]
```

Cross-builds `PROJECT_DIR` (default: current directory). It must contain a
`debian/control`; if not, run `dbs init` there first.

| Option | Values | Default | Meaning |
|---|---|---|---|
| `--dist` | `bookworm` \| `trixie` | `trixie` | Target Debian suite |
| `--arch` | `32` \| `64` | `64` | ARM word size — `32` → **armhf**, `64` → **arm64** |
| `-h`, `--help` | | | Show usage |

Anything after `--` is forwarded verbatim to `docker build` (e.g.
`-- --no-cache`).

#### Examples

```sh
# arm64 / trixie (the defaults), building the current directory
dbs

# 32-bit (armhf) for bookworm
dbs --arch 32 --dist bookworm

# build a project elsewhere
dbs ~/source/DroneProUkr/libdatachannel

# force a clean docker build
dbs --arch 64 -- --no-cache
```

To produce the full matrix, just run it four times:

```sh
for d in bookworm trixie; do
  for a in 32 64; do
    dbs --dist "$d" --arch "$a"
  done
done
```

### Output

Packages land under the project directory:

```
PROJECT_DIR/out/<dist>/<arch>/*.deb
```

For example:

```
out/trixie/arm64/libdatachannel_0.24.3_arm64.deb
out/trixie/arm64/libdatachannel-dev_0.24.3_arm64.deb
out/bookworm/armhf/libdatachannel_0.24.3_armhf.deb
```

`out/` is regenerated per build and is never carried into the package itself.

---

## How a project should look

A buildable project provides a standard Debian `debian/` directory. The key
fields `dbs` cares about:

- **`debian/control`** — `Source:` (package name), `Maintainer:` (used as the
  changelog author when no git author is available) and `Build-Depends:`
  (installed into the sysroot). These dependencies are resolved from the
  Debian, Raspberry Pi and dronerepo archives.
- **`debian/rules`** — a debhelper rules file. If the upstream source lives in
  a subdirectory (commonly a git **submodule**), point debhelper at it with
  `--sourcedirectory`; `dbs` reads the same option to know which git tree to
  derive the changelog from:

  ```make
  #!/usr/bin/make -f
  %:
  	dh $@ --buildsystem=cmake --sourcedirectory=libdatachannel
  ```

`debian/changelog` and `debian/source/format` are **optional** — see below.

---

## Changelog generation

When a project ships **no** `debian/changelog`, `dbs` synthesises one on the
host from the source tree's git history (`dbs-changelog`, a standalone Python
tool) and bind-mounts it into the build. Highlights:

- The source tree is the `--sourcedirectory` from `debian/rules` (resolved by
  letting `make` expand it, with a regex fallback), or the project itself.
- One changelog stanza per release **tag** (newest first), plus a leading
  snapshot stanza when `HEAD` is ahead of the newest tag.
- Versions are extracted from any tag shape (`v0.24.3`, `0.24.3`,
  `release-1.2.3`); `tag+N` denotes *N* commits on top of a tag.
- Falls back to `0.0.1+<commits>` when no tag yields a version, or a single
  `0.0.1` "Initial version" entry when the tree isn't a git repo.
- Distribution is `stable` only when sitting exactly on a release tag (no
  `+N`) **and** major version ≥ 1; otherwise `unstable`.

Why a custom generator instead of `gbp dch`: here `debian/` lives in an outer
wrapper repo while the upstream source is a git *submodule* in the
`--sourcedirectory` subdir, and every version is derived *from upstream tags*
rather than incremented from the previous changelog entry — the inverse of what
git-buildpackage assumes.

If a project does ship its own `debian/changelog`, it is used as-is and nothing
is generated. Likewise, a missing `debian/source/format` defaults to
`3.0 (native)` inside the build tree only.

---

## Repository layout

| File | Role |
|---|---|
| `dbs` | Host CLI: `init` scaffolding and the build driver. |
| `dbs-changelog` | Synthesises `debian/changelog` from git history (GitPython). |
| `dh-stub` | Fake `dh` used by `dbs-changelog` to extract `--sourcedirectory`. |
| `Dockerfile` | Two-stage sysroot + cross-build image, parameterised by suite/arch. |
| `crossbuild` | Container entrypoint: runs `dpkg-buildpackage`, sorts `out/`. |
| `aarch64-linux-gnu-pkg-config`, `arm-linux-gnueabihf-pkg-config` | `pkg-config` wrappers pointing at `/sysroot`. |
| `rpi-arm64.toolchain.cmake`, `rpi-armhf.toolchain.cmake` | CMake cross-compile toolchains. |

---

## Notes & caveats

- The sysroot stage emulates ARM through QEMU; the first build of each
  `suite`/`arch` combination is slow but subsequent builds reuse Docker's layer
  cache. Add `-- --no-cache` to force a clean rebuild.
- Builds run with `DEB_BUILD_OPTIONS="noautodbgsym nocheck"` — debug symbol
  packages and test suites are skipped.
- The build image is tagged `dbs-builder:<dist>-<arch>` and reused across runs.
- `out/` from a previous run is stripped inside the container before building,
  so a stale output tree is never packaged.
