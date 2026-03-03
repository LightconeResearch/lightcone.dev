#!/usr/bin/env bash
set -euo pipefail

# Lightcone Research installer
# Usage: bash <(curl -fsSL https://lightconeresearch.github.io/lightcone.dev/install.sh)
#   or:  bash install.sh [--ssh]

DEFAULT_DIR="$HOME/.lightcone"
GITHUB_ORG="https://github.com/LightconeResearch"
GITHUB_SSH="git@github.com:LightconeResearch"
REPOS=(ASTRA Prism-UI Prism)

# ---------------------------------------------------------------------------
# Colors & symbols
# ---------------------------------------------------------------------------

BOLD='\033[1m'
DIM='\033[2m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

STEP=0
TOTAL_STEPS=4  # prerequisites, repos, venv, packages (vscode is optional/bonus)

step() {
    STEP=$((STEP + 1))
    printf '\n%b[%d/%d]%b %b%s%b\n' "$DIM" "$STEP" "$TOTAL_STEPS" "$RESET" "$BOLD" "$*" "$RESET"
}

ok()   { printf '%b  ✓%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b  !%b %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '%b  ✗%b %s\n' "$RED" "$RESET" "$*" >&2; }
die()  { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Spinner — braille dots, runs in background
# ---------------------------------------------------------------------------

SPINNER_PID=""
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

spin_start() {
    local msg="$1"
    (
        i=0
        while true; do
            printf '\r%b  %s%b  %s' "$BLUE" "${SPINNER_FRAMES[$i]}" "$RESET" "$msg"
            i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
            sleep 0.08
        done
    ) &
    SPINNER_PID=$!
    disown 2>/dev/null || true
}

spin_stop() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf '\r\033[K'  # clear the spinner line
    fi
}

# Clean up spinner on exit
cleanup() { spin_stop; }
trap cleanup EXIT

# Run a command with a spinner, show ✓ on success or ✗ on failure
# Usage: run_with_spinner "message" command arg1 arg2 ...
run_with_spinner() {
    local msg="$1"; shift
    spin_start "$msg"
    local output
    if output=$("$@" 2>&1); then
        spin_stop
        ok "$msg"
        return 0
    else
        local exit_code=$?
        spin_stop
        err "$msg"
        # Show the captured output indented so the user can debug
        if [ -n "$output" ]; then
            printf '%b' "$output" | while IFS= read -r line; do
                printf '%b    %s%b\n' "$DIM" "$line" "$RESET"
            done
        fi
        return $exit_code
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

printf '%b' "$BOLD"
cat << 'BANNER'

  ╦  ╦╔═╗╦ ╦╔╦╗╔═╗╔═╗╔╗╔╔═╗
  ║  ║║ ╦╠═╣ ║ ║  ║ ║║║║║╣
  ╩═╝╩╚═╝╩ ╩ ╩ ╚═╝╚═╝╝╚╝╚═╝

BANNER
printf '%b' "$RESET"

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
# Step 1: Preflight checks
# ---------------------------------------------------------------------------

step "Checking prerequisites"

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

if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
        ok "GitHub CLI authenticated"
    else
        warn "GitHub CLI found but not authenticated — run 'gh auth login' to enable /prism-feedback"
    fi
else
    warn "GitHub CLI (gh) not found — /prism-feedback won't work without it"
    warn "Install: https://cli.github.com"
fi

# ---------------------------------------------------------------------------
# Choose install directory
# ---------------------------------------------------------------------------

if [ -t 0 ]; then
    printf '\n  Directory [%b%s%b]: ' "$DIM" "$DEFAULT_DIR" "$RESET"
    read -r user_dir
    LIGHTCONE_DIR="${user_dir:-$DEFAULT_DIR}"
else
    LIGHTCONE_DIR="$DEFAULT_DIR"
fi

# Expand ~ if present
LIGHTCONE_DIR="${LIGHTCONE_DIR/#\~/$HOME}"
CONFIG_FILE="$LIGHTCONE_DIR/.config"

# ---------------------------------------------------------------------------
# Step 2: Clone or update repos
# ---------------------------------------------------------------------------

step "Setting up repositories"

mkdir -p "$LIGHTCONE_DIR"

for repo in "${REPOS[@]}"; do
    repo_dir="$LIGHTCONE_DIR/$repo"
    if [ -d "$repo_dir/.git" ]; then
        run_with_spinner "Updating $repo" git -C "$repo_dir" pull --ff-only --quiet \
            || warn "Could not fast-forward $repo (you may have local changes)"
    else
        if $USE_SSH; then
            url="$GITHUB_SSH/$repo.git"
        else
            url="$GITHUB_ORG/$repo.git"
        fi
        if [ -d "$repo_dir" ]; then
            die "Directory $repo_dir exists but is not a git repository. Remove it and re-run the installer."
        fi
        run_with_spinner "Cloning $repo" git clone --quiet "$url" "$repo_dir" \
            || die "Failed to clone $repo. Do you have access to the LightconeResearch GitHub org?"
    fi
done

# Prism extern/ASTRA symlink
prism_extern="$LIGHTCONE_DIR/Prism/extern"
mkdir -p "$prism_extern"
if [ ! -L "$prism_extern/ASTRA" ]; then
    ln -sf "$LIGHTCONE_DIR/ASTRA" "$prism_extern/ASTRA"
    ok "Linked Prism/extern/ASTRA"
fi

# ---------------------------------------------------------------------------
# Step 3: Virtual environment
# ---------------------------------------------------------------------------

step "Configuring Python environment"

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
    ok "Using existing venv: $VENV_PATH"
else
    if [ -t 0 ]; then
        echo ""
        echo "  1) Create a new venv at $LIGHTCONE_DIR/.venv (default)"
        echo "  2) Install into an existing virtual environment"
        printf '  Choice [1]: '
        read -r choice
        choice="${choice:-1}"
    else
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
            VENV_PATH="${VENV_PATH/#\~/$HOME}"
            [ -f "$VENV_PATH/bin/python" ] || [ -f "$VENV_PATH/Scripts/python.exe" ] || die "No valid venv found at $VENV_PATH"
            ;;
        *)
            die "Invalid choice: $choice"
            ;;
    esac

    save_config
fi

if [ "$VENV_MODE" = "new" ] && [ ! -d "$VENV_PATH" ]; then
    run_with_spinner "Creating virtual environment" "$PYTHON" -m venv "$VENV_PATH"
fi

# Determine pip path
if [ -f "$VENV_PATH/bin/pip" ]; then
    PIP="$VENV_PATH/bin/pip"
elif [ -f "$VENV_PATH/Scripts/pip.exe" ]; then
    PIP="$VENV_PATH/Scripts/pip.exe"
else
    die "Cannot find pip in $VENV_PATH"
fi

ok "Virtual environment ready"

# ---------------------------------------------------------------------------
# Step 4: Install packages
# ---------------------------------------------------------------------------

step "Installing packages"

run_with_spinner "Installing astra"        "$PIP" install --quiet --disable-pip-version-check -e "$LIGHTCONE_DIR/ASTRA"          || die "Failed to install astra"
run_with_spinner "Installing prism-ui"     "$PIP" install --quiet --disable-pip-version-check -e "$LIGHTCONE_DIR/Prism-UI"     || die "Failed to install prism-ui"
run_with_spinner "Installing prism"      "$PIP" install --quiet --disable-pip-version-check -e "$LIGHTCONE_DIR/Prism" || die "Failed to install prism"

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
        return
    fi

    printf '\n%s\nexport PATH="%s:$PATH"\n' "$marker" "$bin_dir" >> "$rc_file"
    ok "Added to PATH in $(basename "$rc_file")"
}

if [ "$VENV_MODE" = "new" ]; then
    BIN_DIR="$VENV_PATH/bin"
    case "${SHELL:-/bin/bash}" in
        */zsh)  add_to_path "$BIN_DIR" "$HOME/.zshrc" ;;
        */bash)
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
                ok "Added to PATH in config.fish"
            fi
            ;;
        *)      warn "Could not detect shell. Add $BIN_DIR to your PATH manually." ;;
    esac
fi

# ---------------------------------------------------------------------------
# VS Code extension (optional)
# ---------------------------------------------------------------------------

VSIX_PATH="$LIGHTCONE_DIR/Prism-UI/dist/vsix/prism-ui-latest.vsix"

if command -v code >/dev/null 2>&1 && [ -f "$VSIX_PATH" ]; then
    if [ -t 0 ]; then
        echo ""
        printf '  VS Code detected. Install the Prism-UI extension? [Y/n]: '
        read -r vscode_choice
        vscode_choice="${vscode_choice:-y}"
        case "$vscode_choice" in
            [Yy]*) run_with_spinner "Installing VS Code extension" code --install-extension "$VSIX_PATH" --force \
                       || warn "VS Code extension install failed. You can retry: code --install-extension $VSIX_PATH" ;;
        esac
    else
        # Non-interactive with VS Code available — install automatically
        run_with_spinner "Installing VS Code extension" code --install-extension "$VSIX_PATH" --force \
            || warn "VS Code extension install failed."
    fi
elif command -v code >/dev/null 2>&1; then
    warn "VS Code extension not found at $VSIX_PATH (run the installer again after the next release)"
fi

# ---------------------------------------------------------------------------
# Done!
# ---------------------------------------------------------------------------

echo ""
printf '%b' "$GREEN$BOLD"
cat << 'DONE'
  ┌────────────────────────────────────────┐
  │  Lightcone installed successfully! 🔭  │
  └────────────────────────────────────────┘
DONE
printf '%b' "$RESET"
echo ""

if [ "$VENV_MODE" = "new" ]; then
    BIN_DIR="$VENV_PATH/bin"
    echo "  Restart your shell, or run:"
    printf '  %b$ export PATH="%s:$PATH"%b\n' "$DIM" "$BIN_DIR" "$RESET"
    echo ""
fi

echo "  Then try:"
printf '  %b$ prism --help%b        # See all commands\n' "$DIM" "$RESET"
printf '  %b$ prism init my-proj%b  # Create a new project\n' "$DIM" "$RESET"
printf '  %b$ prism ui%b             # Open the visual canvas\n' "$DIM" "$RESET"
echo ""
