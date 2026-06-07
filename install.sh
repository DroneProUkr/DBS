#!/bin/sh
# dbs installer — clone DBS into ~/bin, symlink the CLI onto PATH,
# and make sure ~/bin is on PATH (via ~/.bashrc).
#
# Installs only when all dependencies are present.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DroneProUkr/DBS/main/install.sh | sh
set -eu

REPO_URL="https://github.com/DroneProUkr/DBS.git"
BIN_DIR="${DBS_BIN_DIR:-$HOME/bin}"
CLONE_DIR="$BIN_DIR/DBS"

have() { command -v "$1" >/dev/null 2>&1; }

# 0. Dependencies — bail out (installing nothing) unless they are all present.
echo "==> Checking dependencies"
missing=""
docker_missing=no
add_missing() { missing="$missing $1"; }

have git    || add_missing git
have docker || { add_missing docker.io; docker_missing=yes; }
if ! have python3; then
	add_missing "python3 python3-git"
elif ! python3 -c 'import git' >/dev/null 2>&1; then
	add_missing python3-git   # GitPython
fi

if [ -n "$missing" ]; then
	echo "error: missing dependencies — install them and re-run the installer:" >&2
	echo "         sudo apt install$missing" >&2
	if [ "$docker_missing" = yes ]; then
		echo >&2
		echo "  Docker also needs multi-platform QEMU/binfmt emulation; after" >&2
		echo "  installing it, register the emulators once with:" >&2
		echo "    docker run --privileged --rm tonistiigi/binfmt --install all" >&2
	fi
	exit 1
fi
echo "==> All dependencies present"

echo "==> Installing dbs into $BIN_DIR"

# 1. ~/bin
mkdir -p "$BIN_DIR"

# 2. Clone (or update an existing checkout).
if [ -d "$CLONE_DIR/.git" ]; then
	echo "==> $CLONE_DIR already exists — updating"
	git -C "$CLONE_DIR" pull --ff-only
else
	git clone "$REPO_URL" "$CLONE_DIR"
fi

# 3. Relative symlink: $BIN_DIR/dbs -> DBS/dbs (clone and link move together).
ln -sfn DBS/dbs "$BIN_DIR/dbs"
echo "==> Linked $BIN_DIR/dbs -> DBS/dbs"

# 4. Ensure $BIN_DIR is on PATH. Append to ~/.bashrc if it isn't already.
case ":$PATH:" in
	*":$BIN_DIR:"*) on_path=yes ;;
	*)             on_path=no ;;
esac

BASHRC="$HOME/.bashrc"
PATH_LINE='export PATH="$HOME/bin:$PATH"'

if [ "$on_path" = no ]; then
	if [ -f "$BASHRC" ] && grep -qF "$PATH_LINE" "$BASHRC"; then
		echo "==> $BASHRC already adds ~/bin to PATH — open a new shell to pick it up"
	else
		printf '\n# Added by dbs installer\n%s\n' "$PATH_LINE" >> "$BASHRC"
		echo "==> Added ~/bin to PATH in $BASHRC — run 'source $BASHRC' or open a new shell"
	fi
else
	echo "==> ~/bin is already on PATH"
fi

echo
echo "==> Done. Run 'dbs --help' to get started."
