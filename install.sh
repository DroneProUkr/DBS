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

# 0. Dependencies — auto-install any that are missing (apt hosts), then
#    bail out only if some are still absent afterwards.
#
# check_deps recomputes the missing set into $missing (space-separated apt
# package names, no leading space) and $docker_missing (yes/no), so it can be
# called again after an install attempt to confirm the result.
check_deps() {
	missing=""
	docker_missing=no
	have git    || missing="$missing git"
	have docker || { missing="$missing docker.io"; docker_missing=yes; }
	if ! have python3; then
		missing="$missing python3 python3-git"
	elif ! python3 -c 'import git' >/dev/null 2>&1; then
		missing="$missing python3-git"   # GitPython
	fi
	missing="$(printf '%s' "$missing" | sed 's/^ *//; s/ *$//; s/  */ /g')"
}

manual_hint() {
	echo "error: missing dependencies — install them and re-run the installer:" >&2
	echo "         sudo apt install $missing" >&2
	if [ "$docker_missing" = yes ]; then
		echo >&2
		echo "  Docker also needs multi-platform QEMU/binfmt emulation; after" >&2
		echo "  installing it, register the emulators once with:" >&2
		echo "    docker run --privileged --rm tonistiigi/binfmt --install all" >&2
	fi
}

echo "==> Checking dependencies"
check_deps

if [ -n "$missing" ]; then
	echo "==> Missing dependencies: $missing"

	# Elevate with sudo when not already root; run apt directly when we are.
	sudo=""
	if [ "$(id -u)" -ne 0 ] && have sudo; then
		sudo="sudo"
	fi

	if have apt-get && { [ "$(id -u)" -eq 0 ] || [ -n "$sudo" ]; }; then
		echo "==> Installing missing dependencies with apt: $missing"
		$sudo apt-get update || \
			echo "warning: 'apt-get update' failed — attempting install anyway" >&2
		if $sudo apt-get install -y $missing; then
			check_deps   # re-evaluate — some may still be unresolved
		else
			echo "warning: automatic dependency install failed" >&2
		fi
	else
		echo "warning: cannot auto-install (need apt-get and root or sudo)" >&2
	fi
fi

# Anything still missing after the install attempt is fatal.
if [ -n "$missing" ]; then
	manual_hint
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
