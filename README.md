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
   ├─ parse --dist/--arch/--local      │  debian:<suite> + raspberrypi   │
   ├─ synthesise debian/changelog ─────│  + droneprorepo apt repos       │
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
   [droneprorepo](https://droneproukr.github.io/droneprorepo/) apt repositories added —
   plus a [local repo](#local-package-repo) of packages you have already built
   — into which your project's `Build-Depends` are installed with
   `mk-build-deps`. This becomes the target `/sysroot`.
2. **Build stage** — a native amd64 image holding the cross-compilers
   (`crossbuild-essential-arm64` / `-armhf`), CMake, debhelper and the sysroot
   copied from stage 1. Cross-aware `pkg-config` wrappers and CMake toolchain
   files point every lookup at `/sysroot`. The build-time *tooling* from your
   `Build-Depends` is also installed here natively (`dbs-host-deps`): dh add-on
   sequences (`dh-sequence-*`, e.g. `javahelper`/`python3`) and any
   `Architecture: all` helper run on this host during the build, so they must
   live here rather than only in the (wrong-arch) sysroot.
3. **crossbuild** (the container entrypoint) copies your bind-mounted
   workspace into `/build/src`, runs `dpkg-buildpackage -b --host-arch <arch>`,
   and drops the resulting `.deb`s into `out/<dist>/<arch>/` — or, with
   `--local`, the raw installed build tree into `build/<dist>/<arch>/`.

### Native mode (`--native`)

Some packages don't cross-compile — typically those that build language
bindings (e.g. opencv's Python bindings run the host's `python`, which is the
wrong architecture) or pull in cmake package configs that bake in absolute
`/usr` paths. For these, `--native` skips the cross stage entirely: it adds a
native toolchain to the **sysroot** stage (which already has your
`Build-Depends`) and runs `dpkg-buildpackage -b` *inside* the emulated
target-arch container under QEMU. Everything — compilers, `python`, the JDK — is
already the target architecture, so there are no cross-compilation quirks. The
trade-off is speed: the whole compile runs under emulation. The `sysroot` stage
is shared with cross builds, so switching modes doesn't rebuild it.

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
| `-d`, `--dist` | `bookworm` \| `trixie` | `trixie` | Target Debian suite |
| `-a`, `--arch` | `32` \| `64` | `64` | ARM word size — `32` → **armhf**, `64` → **arm64** |
| `-l`, `--local` | | off | Emit the raw build tree into `build/<dist>/<arch>/` instead of `.deb`s into `out/<dist>/<arch>/` |
| `-n`, `--native` | | off | Build **natively** inside the emulated target-arch container (QEMU) instead of cross-compiling. Slower, but builds packages that don't cross-compile. |
| `-p`, `--publish` | | off | After a successful build, copy the `.deb`s into the [local package repo](#local-package-repo) so other projects can resolve them as `Build-Depends`. Without it, packages stay in `out/` only. |
| `--host-deps` | `"PKG..."` | none | Extra build packages to install for the build (repeatable; also via `debian/dbs-host-deps`). Cross: on the amd64 host (Debian main only). Native: in the target container (Debian/Pi/droneprorepo). |
| `-h`, `--help` | | | Show usage |

Anything after `--` is forwarded verbatim to `docker build` (e.g.
`-- --no-cache`).

Short flags may be **bundled**: `-np` is the same as `-n -p`, and a
value-taking flag may end a bundle, so `-npa 32` means `-n -p -a 32`. (A
`PROJECT_DIR` whose name begins with `-` must be written as `./name` or given
after `--`, so it isn't mistaken for a flag bundle.)

#### Examples

```sh
# arm64 / trixie (the defaults), building the current directory
dbs

# 32-bit (armhf) for bookworm (short flags)
dbs -a 32 -d bookworm

# build a project elsewhere
dbs ~/source/DroneProUkr/libdatachannel

# grab the raw build tree (compiled binaries/libs/headers), no .deb
dbs --local

# build and publish to the local repo so other projects can Build-Depend on it
dbs --publish
dbs -np                 # natively, then publish (bundled short flags)

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

#### Local artifacts (`--local`)

With `-l` / `--local`, no `.deb` is written. Instead the raw installed build
tree — the files that *would* go into the package (`usr/bin`, `usr/lib`,
headers, …) — is handed back under:

```
PROJECT_DIR/build/<dist>/<arch>/
```

For a single-binary package the tree lands directly in that directory; when a
project produces several binary packages, each is kept in its own
`build/<dist>/<arch>/<pkg>/` subdirectory. The target `build/<dist>/<arch>/` is
wiped and regenerated on each run. Handy for quickly inspecting or testing the
compiled output without unpacking a `.deb`.

---

## Local package repo

`dbs` keeps a clone of the project package repo
([`droneprorepo`](https://github.com/DroneProUkr/droneprorepo) —
the source of <https://droneproukr.github.io/droneprorepo/>) under your home
directory and adds its package pool as a source in the **sysroot** stage of
*every* build. This lets packages depend on each other: build a library,
publish it, and a later build of something that `Build-Depends` on it resolves
it straight from your own previous output — no need to push to droneprorepo
first.

On first use `dbs` runs `git clone git@github.com:DroneProUkr/droneprorepo.git`
into `~/dbs/droneprorepo`. Published packages are dropped into that clone's
`pool/<suite>/main/` directories — the same layout the real repo commits — but
`dbs` **never** runs `git add` or `git commit`. Publishing just stages files on
disk; you review and commit them yourself, then push to share them.

Reading from the repo is automatic; **writing** to it is opt-in. Pass
`-p` / `--publish` to copy a build's `.deb`s into the pool. Without it the
packages stay in `out/<dist>/<arch>/` and nothing is shared with other
projects.

```
~/dbs/droneprorepo/pool/<suite>/main/*.deb
```

The pool mixes architectures (`arm64`, `armhf`, `all`) in one directory per
suite, exactly like the published repo; apt filters by architecture when
resolving build-deps. Staging into a build only pulls the packages that build
needs — the target arch plus the `_all` (arch-independent) ones.

**One version per package.** When you publish, `dbs` keeps a single newest copy
of each package+arch in the pool:

- A **newer or equal** build replaces the copy already there — older `.deb`
  files for that package+arch are deleted, so the pool never accumulates stale
  versions.
- An **older** build is refused: `dbs` prints a warning and leaves the existing
  newer package in place. Bump the version (it derives from git) and rebuild to
  publish.

How it works, per build:

1. Before building, `dbs` ensures the clone exists, then stages the relevant
   `.deb`s out of `~/dbs/droneprorepo/pool/<suite>/main/` into the docker
   context. The sysroot stage bind-mounts them, runs `dpkg-scanpackages` to
   build a flat-repo index, and adds `deb [trusted=yes] file:/localrepo ./` as
   an apt source for that one `mk-build-deps` invocation. The mount is
   ephemeral — the `.deb` files and the index never enter an image layer, so
   nothing is duplicated into the cross stage's `/sysroot`.
2. After a successful build, **only when `-p` / `--publish` is given**, `dbs`
   first runs **`git pull`** on the clone so the pool reflects whatever has been
   pushed to droneprorepo since (see below), then publishes the produced `.deb`s
   (from `out/<dist>/<arch>/`) into the pool per the one-version rule above.
   Plain builds leave the repo untouched.

**Pull before publish.** Because the pool is a real git clone that other people
also push to, `-p` syncs it before adding your packages, and reconciles any
divergence by the same rule as everything else — **higher version wins, and on
an equal version the local copy wins**:

- The pull is a `git fetch` + `git merge` (a merge commit only if your branch
  has un-pushed commits). Genuine same-path merge conflicts resolve toward your
  local copy; differing versions are just different files and both arrive, after
  which the older one is pruned.
- After the pull, your freshly built package is compared against the *synced*
  pool: if upstream already has a higher version, the build is refused with a
  warning (you can't downgrade the repo); otherwise it replaces the older copy.
- If the fetch fails (offline, detached HEAD, no upstream branch), `dbs` warns
  and publishes against the local pool only — a network hiccup never blocks a
  build. As always, `dbs` only moves `.deb` files around; it never `git add`s or
  commits your published packages.

When two sources offer the same package, apt picks the **highest version** as
usual — a locally built package (whose version `dbs` derives from git) wins
only when it actually out-versions the archive copy.

Notes:

- The repo root defaults to `~/dbs`; set **`DBS_HOME`** to relocate it, or
  **`DBS_REPO_DIR`** to point `dbs` at an existing droneprorepo checkout.
- The clone is created once and reused; `-p` pulls it fresh before each
  publish. To publish a dependency for another build, build order still matters
  — build and publish the dependency *before* the package that needs it.
- `--local` builds emit a raw build tree rather than `.deb`s, so there is
  nothing to publish even with `-p`.
- The pool is just `.deb` files in a git working tree: `git status` in
  `~/dbs/droneprorepo` shows what publishing added, and you commit/push to
  share it (or `git checkout`/`git clean` to discard).

---

## How a project should look

A buildable project provides a standard Debian `debian/` directory. The key
fields `dbs` cares about:

- **`debian/control`** — `Source:` (package name), `Maintainer:` (used as the
  changelog author when no git author is available) and `Build-Depends:`.
  Architecture-dependent `-dev` libraries are installed into the sysroot for the
  target arch; architecture-independent build *tooling* (dh add-on sequences,
  `Architecture: all` helpers) is installed natively on the build host so `dh`
  can run it. These dependencies are resolved from the Debian, Raspberry Pi and
  droneprorepo archives.
- **`debian/rules`** — a debhelper rules file. If the upstream source lives in
  a subdirectory (commonly a git **submodule**), point debhelper at it with
  `--sourcedirectory`; `dbs` reads the same option to know which git tree to
  derive the changelog from:

  ```make
  #!/usr/bin/make -f
  %:
  	dh $@ --buildsystem=cmake --sourcedirectory=libdatachannel
  ```

- **`debian/dbs-host-deps`** *(optional)* — extra build utilities that the
  host-tooling auto-detection can't classify, because they are arch-dependent
  tools rather than `Architecture: all` helpers (e.g. `protobuf-compiler`,
  `astyle`). One package per line; `#` starts a comment. The same list can be
  passed ad-hoc with `--host-deps "PKG..."` (handy when you must keep a
  project's `debian/` pristine). In **cross** builds these install on the amd64
  build host, which carries only the Debian archive — so they must be packages
  available in Debian **main** (the raspi/droneprorepo repos exist only in the
  sysroot stage). In **native** builds (`-n`) they install inside the
  target-arch container instead, which also has the Raspberry Pi and droneprorepo
  archives. Each entry must be an **exact** package name; an unknown name (e.g.
  a typo) fails the build with a clear error rather than being silently
  substring-expanded by `apt-get`.

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
| `dbs-host-deps` | Selects the build-host tooling (`dh-sequence-*` + `Architecture: all` build-deps) to install natively in the build stage. |
| `dh-stub` | Fake `dh` used by `dbs-changelog` to extract `--sourcedirectory`. |
| `Dockerfile` | Multi-stage image (`sysroot` + `cross` + `native` targets), parameterised by suite/arch. |
| `crossbuild` | Container entrypoint: runs `dpkg-buildpackage`, sorts `out/` (or `build/` with `--local`). |
| `aarch64-linux-gnu-pkg-config`, `arm-linux-gnueabihf-pkg-config` | `pkg-config` wrappers pointing at `/sysroot`. |
| `rpi-arm64.toolchain.cmake`, `rpi-armhf.toolchain.cmake` | CMake cross-compile toolchains. |

---

## Notes & caveats

- The sysroot stage emulates ARM through QEMU; the first build of each
  `suite`/`arch` combination is slow but subsequent builds reuse Docker's layer
  cache. Add `-- --no-cache` to force a clean rebuild.
- Builds run with `DEB_BUILD_OPTIONS="noautodbgsym nocheck"` — debug symbol
  packages and test suites are skipped.
- The build image is tagged `dbs-builder:<dist>-<arch>` (or
  `dbs-builder:<dist>-<arch>-native` with `-n`) and reused across runs.
- `out/` from a previous run is stripped inside the container before building,
  so a stale output tree is never packaged.
