#!/usr/bin/env bash
set -euo pipefail

# Lightcone Research installer
# Usage: curl -fsSL https://lightconeresearch.github.io/lightcone.dev/install.sh | bash
#   or:  bash install.sh [--ssh]

LIGHTCONE_DIR="$HOME/.lightcone"
CONFIG_FILE="$LIGHTCONE_DIR/.config"
GITHUB_ORG="https://github.com/LightconeResearch"
GITHUB_SSH="git@github.com:LightconeResearch"
REPOS=(ASP Canvas Prism)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[0;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m  !\033[0m %s\n' "$*"; }
err()   { printf '\033[0;31m  ✗\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------

USE_SSH=false
for arg in "$@"; do
    case "$arg" in
        --ssh) USE_SSH=true ;;
        *)     die "Unknown argument: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

info "Checking prerequisites..."

command -v git >/dev/null 2>&1 || die "git is required but not found. Please install git first."
ok "git found"

PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        ver=$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)
        major=$(echo "$ver" | cut -d. -f1)
        minor=$(echo "$ver" | cut -d. -f2)
        if [ "${major:-0}" -ge 3 ] && [ "${minor:-0}" -ge 11 ]; then
            PYTHON="$candidate"
            break
        fi
    fi
done
[ -n "$PYTHON" ] || die "Python >= 3.11 is required but not found."
ok "Python $ver ($PYTHON)"

# ---------------------------------------------------------------------------
# Clone or update repos
# ---------------------------------------------------------------------------

mkdir -p "$LIGHTCONE_DIR"

info "Setting up repositories in $LIGHTCONE_DIR..."

for repo in "${REPOS[@]}"; do
    repo_dir="$LIGHTCONE_DIR/$repo"
    if [ -d "$repo_dir/.git" ]; then
        info "Updating $repo..."
        git -C "$repo_dir" pull --ff-only --quiet 2>/dev/null && ok "Updated $repo" || warn "Could not fast-forward $repo (you may have local changes)"
    else
        if $USE_SSH; then
            url="$GITHUB_SSH/$repo.git"
        else
            url="$GITHUB_ORG/$repo.git"
        fi
        info "Cloning $repo..."
        git clone --quiet "$url" "$repo_dir" || die "Failed to clone $repo. Do you have access to the LightconeResearch GitHub org?"
        ok "Cloned $repo"
    fi
done

# ---------------------------------------------------------------------------
# Set up Prism extern/ASP symlink
# ---------------------------------------------------------------------------

prism_extern="$LIGHTCONE_DIR/Prism/extern"
mkdir -p "$prism_extern"
if [ ! -L "$prism_extern/ASP" ]; then
    ln -sf "$LIGHTCONE_DIR/ASP" "$prism_extern/ASP"
    ok "Linked Prism/extern/ASP"
fi

# ---------------------------------------------------------------------------
# Virtual environment selection
# ---------------------------------------------------------------------------

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<CONF
# Lightcone install config (auto-generated)
VENV_MODE="$VENV_MODE"
VENV_PATH="$VENV_PATH"
CONF
}

VENV_MODE=""
VENV_PATH=""
load_config

if [ -n "$VENV_MODE" ] && [ -n "$VENV_PATH" ]; then
    info "Using previously configured venv: $VENV_PATH"
else
    # Interactive prompt (only when stdin is a terminal)
    if [ -t 0 ]; then
        echo ""
        info "Where should Lightcone packages be installed?"
        echo "  1) Create a new venv at ~/.lightcone/.venv (default)"
        echo "  2) Install into an existing virtual environment"
        printf "  Choice [1]: "
        read -r choice
        choice="${choice:-1}"
    else
        # Non-interactive (piped) — use default
        choice="1"
    fi

    case "$choice" in
        1)
            VENV_MODE="new"
            VENV_PATH="$LIGHTCONE_DIR/.venv"
            ;;
        2)
            if [ -n "${VIRTUAL_ENV:-}" ]; then
                printf "  Detected active venv: %s\n  Use it? [Y/n]: " "$VIRTUAL_ENV"
                if [ -t 0 ]; then
                    read -r yn
                else
                    yn="y"
                fi
                yn="${yn:-y}"
                case "$yn" in
                    [Yy]*) VENV_PATH="$VIRTUAL_ENV" ;;
                    *)
                        printf "  Path to venv: "
                        read -r VENV_PATH
                        ;;
                esac
            else
                printf "  Path to venv: "
                read -r VENV_PATH
            fi
            VENV_MODE="existing"
            # Expand ~ if present
            VENV_PATH="${VENV_PATH/#\~/$HOME}"
            [ -f "$VENV_PATH/bin/python" ] || [ -f "$VENV_PATH/Scripts/python.exe" ] || die "No valid venv found at $VENV_PATH"
            ;;
        *)
            die "Invalid choice: $choice"
            ;;
    esac

    save_config
fi

# ---------------------------------------------------------------------------
# Create venv if needed
# ---------------------------------------------------------------------------

if [ "$VENV_MODE" = "new" ] && [ ! -d "$VENV_PATH" ]; then
    info "Creating virtual environment at $VENV_PATH..."
    "$PYTHON" -m venv "$VENV_PATH"
    ok "Created venv"
fi

# Determine pip/python paths
if [ -f "$VENV_PATH/bin/pip" ]; then
    PIP="$VENV_PATH/bin/pip"
elif [ -f "$VENV_PATH/Scripts/pip.exe" ]; then
    PIP="$VENV_PATH/Scripts/pip.exe"
else
    die "Cannot find pip in $VENV_PATH"
fi

# ---------------------------------------------------------------------------
# Install packages in dependency order
# ---------------------------------------------------------------------------

info "Installing packages (this may take a minute)..."

export SETUPTOOLS_SCM_PRETEND_VERSION=0.1.0

"$PIP" install --quiet -e "$LIGHTCONE_DIR/ASP"          && ok "Installed asp"          || die "Failed to install asp"
"$PIP" install --quiet -e "$LIGHTCONE_DIR/Canvas"        && ok "Installed asp-canvas"   || die "Failed to install asp-canvas"
"$PIP" install --quiet -e "$LIGHTCONE_DIR/Prism[canvas]" && ok "Installed prism"        || die "Failed to install prism"

# ---------------------------------------------------------------------------
# PATH setup (only for new venv)
# ---------------------------------------------------------------------------

add_to_path() {
    local bin_dir="$1"
    local rc_file="$2"

    if [ ! -f "$rc_file" ]; then
        return
    fi

    local marker='# Added by Lightcone installer'
    if grep -qF "$marker" "$rc_file" 2>/dev/null; then
        return  # Already added
    fi

    printf '\n%s\nexport PATH="%s:$PATH"\n' "$marker" "$bin_dir" >> "$rc_file"
    ok "Added $bin_dir to PATH in $(basename "$rc_file")"
}

if [ "$VENV_MODE" = "new" ]; then
    BIN_DIR="$VENV_PATH/bin"
    # Detect shell rc file
    case "${SHELL:-/bin/bash}" in
        */zsh)  add_to_path "$BIN_DIR" "$HOME/.zshrc" ;;
        */bash)
            # macOS uses .bash_profile, Linux uses .bashrc
            if [ -f "$HOME/.bash_profile" ]; then
                add_to_path "$BIN_DIR" "$HOME/.bash_profile"
            else
                add_to_path "$BIN_DIR" "$HOME/.bashrc"
            fi
            ;;
        */fish)
            fish_conf="$HOME/.config/fish/config.fish"
            if [ -f "$fish_conf" ] && ! grep -qF "lightcone" "$fish_conf" 2>/dev/null; then
                printf '\n# Added by Lightcone installer\nfish_add_path %s\n' "$BIN_DIR" >> "$fish_conf"
                ok "Added $BIN_DIR to PATH in config.fish"
            fi
            ;;
        *)      warn "Could not detect shell. Add $BIN_DIR to your PATH manually." ;;
    esac
fi

# ---------------------------------------------------------------------------
# Done!
# ---------------------------------------------------------------------------

echo ""
printf '\033[0;32m%s\033[0m\n' "Lightcone tools installed successfully!"
echo ""

if [ "$VENV_MODE" = "new" ]; then
    BIN_DIR="$VENV_PATH/bin"
    echo "To get started, either restart your shell or run:"
    echo ""
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    echo ""
fi

echo "Then try:"
echo ""
echo "  prism --help        # See all commands"
echo "  prism init my-proj  # Create a new project"
echo "  prism canvas        # Open the visual canvas"
echo ""
