#!/usr/bin/env bash
# install.sh — set up claude-code-status-line
#
# What this does:
#   1. Copies status-line.sh to ~/.local/share/claude-status-line/
#   2. Creates a default config at ~/.config/claude-status-line/config.env
#   3. Patches ~/.claude/settings.json to register the StatusLine hook

set -euo pipefail

# ── Configurable install location ──────────────────────────────────────────────
INSTALL_DIR="${INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-status-line}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-status-line"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$INSTALL_DIR/status-line.sh"

# ── Helpers ────────────────────────────────────────────────────────────────────
info()    { printf '\e[34m[info]\e[0m  %s\n' "$*"; }
ok()      { printf '\e[32m[ ok ]\e[0m  %s\n' "$*"; }
warn()    { printf '\e[33m[warn]\e[0m  %s\n' "$*"; }
die()     { printf '\e[31m[err ]\e[0m  %s\n' "$*" >&2; exit 1; }

require_python3() {
    command -v python3 &>/dev/null || die "python3 is required but not found."
}

# ── Step 1: install script ─────────────────────────────────────────────────────
install_script() {
    info "Installing hook script to $HOOK_SCRIPT"
    mkdir -p "$INSTALL_DIR"
    cp "$SCRIPT_DIR/status-line.sh" "$HOOK_SCRIPT"
    chmod +x "$HOOK_SCRIPT"
    ok "Hook script installed"
}

# ── Step 2: create default config ─────────────────────────────────────────────
install_config() {
    mkdir -p "$CONFIG_DIR"
    local cfg="$CONFIG_DIR/config.env"
    if [[ -f "$cfg" ]]; then
        warn "Config already exists at $cfg — skipping (delete to reset)"
        return
    fi
    info "Creating default config at $cfg"
    cp "$SCRIPT_DIR/config.env.example" "$cfg"
    ok "Config created"
}

# ── Step 3: patch ~/.claude/settings.json ─────────────────────────────────────
patch_settings() {
    info "Patching $CLAUDE_SETTINGS"
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

    python3 - "$CLAUDE_SETTINGS" "$HOOK_SCRIPT" <<'PYEOF'
import json, sys, os, shutil, tempfile

settings_path = sys.argv[1]
hook_script   = sys.argv[2]

# Load existing settings (or start fresh)
if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError:
            print(f"[warn]  {settings_path} is not valid JSON — backing up and starting fresh",
                  file=sys.stderr)
            shutil.copy(settings_path, settings_path + ".bak")
            settings = {}
else:
    settings = {}

# Build / replace the top-level statusLine entry
existing = settings.get("statusLine", {})

# Preserve any existing options the user set (padding, refreshInterval)
entry = {
    "type": "command",
    "command": hook_script,
}
if isinstance(existing, dict):
    entry = {**existing, **entry}   # our values win on type/command

settings["statusLine"] = entry

# Remove stale hooks.statusLine from a previous install of this script
if "hooks" in settings and isinstance(settings["hooks"], dict):
    settings["hooks"].pop("statusLine", None)
    if not settings["hooks"]:          # drop empty hooks object
        del settings["hooks"]

# Write atomically
tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_path)

print(f"[ok ]   StatusLine hook registered in {settings_path}")
PYEOF

    ok "settings.json patched"
}

# ── Step 4: print shell-integration hint ──────────────────────────────────────
print_shell_hint() {
    echo ""
    info "Optional: add to ~/.bashrc or ~/.zshrc for status outside Claude Code:"
    echo "    source \"$SCRIPT_DIR/prompt.sh\""
    echo "    # then use \$(claude_status) in your PS1"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    echo "Claude Code Status Line — installer"
    echo "────────────────────────────────────"
    require_python3
    install_script
    install_config
    patch_settings
    print_shell_hint
    echo "────────────────────────────────────"
    ok "Done. Restart Claude Code to activate the status bar."
}

main "$@"
