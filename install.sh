#!/bin/sh
# dbs installer — clone DBS into ~/bin, symlink the CLI onto PATH, and make sure
# ~/bin is on PATH. Auto-installs missing dependencies where it can — apt on
# Debian/Ubuntu, Homebrew on macOS — otherwise prints what to install.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DroneProUkr/DBS/main/install.sh | sh
set -eu

REPO_URL="https://github.com/DroneProUkr/DBS.git"
BIN_DIR="${DBS_BIN_DIR:-$HOME/bin}"
OS="$(uname -s)"
# macOS volumes are case-insensitive by default: there "DBS" and the "dbs" link are one
# name, and the link would land inside the clone in place of its own script.
case "$OS" in
	Darwin) CLONE_NAME="DBS-src" ;;
	*)      CLONE_NAME="DBS" ;;
esac
CLONE_DIR="$BIN_DIR/$CLONE_NAME"

have() { command -v "$1" >/dev/null 2>&1; }

# bash >= 4 present on PATH? macOS ships 3.2; dbs --publish needs >= 4.
bash4_ok() {
	have bash || return 1
	[ "$(bash -c 'echo "${BASH_VERSINFO[0]:-0}"' 2>/dev/null || echo 0)" -ge 4 ] 2>/dev/null
}

# Recompute the dependency sets:
#   $missing      — essential (dbs cannot build without these)
#   $missing_opt  — macOS-only publish extras (dbs -p): bash >= 4 and dpkg
#   $docker_missing — yes/no (needs a manual/GUI install, not a package)
check_deps() {
	missing=""; missing_opt=""; docker_missing=no
	have git    || missing="$missing git"
	have docker || { missing="$missing docker"; docker_missing=yes; }
	if ! have python3; then
		missing="$missing python3 gitpython"
	elif ! python3 -c 'import git' >/dev/null 2>&1; then
		missing="$missing gitpython"           # GitPython
	fi
	if [ "$OS" = Darwin ]; then
		bash4_ok || missing_opt="$missing_opt bash"
		have dpkg || missing_opt="$missing_opt dpkg"
	fi
	missing="$(printf '%s' "$missing" | sed 's/^ *//; s/ *$//; s/  */ /g')"
	missing_opt="$(printf '%s' "$missing_opt" | sed 's/^ *//; s/ *$//; s/  */ /g')"
}

# ---- Debian/Ubuntu (apt) ----
install_apt() {
	pkgs=""
	for t in $missing $missing_opt; do
		case "$t" in
			gitpython) pkgs="$pkgs python3-git" ;;
			docker)    pkgs="$pkgs docker.io" ;;
			*)         pkgs="$pkgs $t" ;;
		esac
	done
	sudo=""
	[ "$(id -u)" -ne 0 ] && have sudo && sudo="sudo"
	if have apt-get && { [ "$(id -u)" -eq 0 ] || [ -n "$sudo" ]; }; then
		echo "==> Installing with apt:$pkgs"
		$sudo apt-get update || echo "warning: 'apt-get update' failed — continuing" >&2
		$sudo apt-get install -y $pkgs || echo "warning: apt install failed" >&2
	else
		echo "warning: cannot auto-install (need apt-get and root or sudo)" >&2
	fi
}

# ---- macOS (Homebrew + pip) ----
install_macos() {
	if ! have brew; then
		echo "warning: Homebrew not found — install it from https://brew.sh, then re-run" >&2
		return 0
	fi
	formulae=""
	for t in $missing $missing_opt; do
		case "$t" in
			git|bash|dpkg|python3) formulae="$formulae $t" ;;
			docker|gitpython)      ;;   # docker = cask/GUI, gitpython = pip (below)
		esac
	done
	if [ -n "$(printf '%s' "$formulae" | tr -d ' ')" ]; then
		echo "==> brew install$formulae"
		brew install $formulae || echo "warning: some brew installs failed" >&2
	fi
	case " $missing " in
		*" gitpython "*)
			echo "==> Installing GitPython (pip)"
			python3 -m pip install --user GitPython >/dev/null 2>&1 \
			  || python3 -m pip install --break-system-packages GitPython >/dev/null 2>&1 \
			  || echo "warning: could not install GitPython — run: python3 -m pip install --user GitPython" >&2
			;;
	esac
	case " $missing " in
		*" docker "*)
			echo "==> Docker not found. Install Docker Desktop, then launch it once:" >&2
			echo "      brew install --cask docker   (or download from docker.com)" >&2
			;;
	esac
}

echo "==> Checking dependencies"
check_deps

if [ -n "$missing$missing_opt" ]; then
	[ -n "$missing" ]     && echo "==> Missing (required): $missing"
	[ -n "$missing_opt" ] && echo "==> Missing (recommended for 'dbs --publish'): $missing_opt"
	case "$OS" in
		Darwin) install_macos ;;
		*)      install_apt ;;
	esac
	check_deps
fi

# Recommended-but-absent (macOS publish extras) only warn — plain builds work.
if [ -n "$missing_opt" ]; then
	echo "warning: '$missing_opt' still missing — 'dbs' builds fine, but 'dbs --publish' needs them" >&2
	echo "         macOS: brew install $missing_opt" >&2
fi

# Anything essential still missing is fatal.
if [ -n "$missing" ]; then
	echo "error: missing required dependencies: $missing" >&2
	if [ "$OS" = Darwin ]; then
		echo "  macOS: brew install git python3 ; python3 -m pip install --user GitPython" >&2
		[ "$docker_missing" = yes ] && echo "         brew install --cask docker  (then launch Docker Desktop once)" >&2
	else
		echo "         sudo apt install git docker.io python3 python3-git" >&2
		[ "$docker_missing" = yes ] && {
			echo >&2
			echo "  Docker also needs multi-platform QEMU/binfmt emulation; register once with:" >&2
			echo "    docker run --privileged --rm tonistiigi/binfmt --install all" >&2
		}
	fi
	exit 1
fi
echo "==> All required dependencies present"

echo "==> Installing dbs into $BIN_DIR"

# 1. ~/bin
mkdir -p "$BIN_DIR"
# The dbs link goes to $BIN_DIR/dbs; a real directory there (on macOS: the ~/bin/DBS
# of an earlier install) would take the link inside it.
if [ -d "$BIN_DIR/dbs" ] && [ ! -L "$BIN_DIR/dbs" ]; then
	echo "error: $BIN_DIR/dbs is a directory, so the dbs link cannot go there" >&2
	[ "$OS" = Darwin ] && echo "       (on macOS that is $BIN_DIR/DBS from an earlier install: remove it, then re-run)" >&2
	exit 1
fi

# 2. Clone (or update an existing checkout).
if [ -d "$CLONE_DIR/.git" ]; then
	echo "==> $CLONE_DIR already exists — updating"
	git -C "$CLONE_DIR" pull --ff-only
else
	git clone "$REPO_URL" "$CLONE_DIR"
fi

# 3. Relative symlink: $BIN_DIR/dbs -> $CLONE_NAME/dbs (clone and link move together).
ln -sfn "$CLONE_NAME/dbs" "$BIN_DIR/dbs"
echo "==> Linked $BIN_DIR/dbs -> $CLONE_NAME/dbs"

# 4. Ensure $BIN_DIR is on PATH. Append to the login shell's rc if it isn't already.
case ":$PATH:" in
	*":$BIN_DIR:"*) on_path=yes ;;
	*)             on_path=no ;;
esac

# macOS defaults to zsh; Linux to bash. Pick the rc file for the current shell.
case "${SHELL:-}" in
	*/zsh)  RC_FILE="$HOME/.zshrc" ;;
	*/bash) [ "$OS" = Darwin ] && RC_FILE="$HOME/.bash_profile" || RC_FILE="$HOME/.bashrc" ;;
	*)      [ "$OS" = Darwin ] && RC_FILE="$HOME/.zshrc" || RC_FILE="$HOME/.bashrc" ;;
esac
PATH_LINE='export PATH="$HOME/bin:$PATH"'

if [ "$on_path" = no ]; then
	if [ -f "$RC_FILE" ] && grep -qF "$PATH_LINE" "$RC_FILE"; then
		echo "==> $RC_FILE already adds ~/bin to PATH — open a new shell to pick it up"
	else
		printf '\n# Added by dbs installer\n%s\n' "$PATH_LINE" >> "$RC_FILE"
		echo "==> Added ~/bin to PATH in $RC_FILE — run 'source $RC_FILE' or open a new shell"
	fi
else
	echo "==> ~/bin is already on PATH"
fi

echo
echo "==> Done. Run 'dbs --help' to get started."
