# prompt.sh — shell function for showing Claude status outside Claude Code
#
# Source this file in ~/.bashrc or ~/.zshrc:
#   source /path/to/claude-code-status-line/prompt.sh
#
# Then add $(claude_status) to your PS1, e.g.:
#   PS1='[\u@\h \W]$(claude_status)\$ '
#
# Or run it as a standalone command to print the last known status.

_CLAUDE_STATUS_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/claude-status-line/state.json"
_CLAUDE_STATUS_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-status-line/config.env"

claude_status() {
    # Load config
    local WEEKLY_TOKEN_LIMIT=1000000
    local PROGRESS_BAR_WIDTH=10
    [[ -f "$_CLAUDE_STATUS_CONFIG" ]] && source "$_CLAUDE_STATUS_CONFIG"

    # Read state file written by the hook script
    if [[ ! -f "$_CLAUDE_STATUS_DATA" ]]; then
        return 0
    fi

    local weekly_tokens=0
    if command -v jq &>/dev/null; then
        weekly_tokens=$(jq -r '.weekly_tokens // 0' "$_CLAUDE_STATUS_DATA" 2>/dev/null || echo 0)
    else
        weekly_tokens=$(python3 -c "
import json, sys
try:
    with open('$_CLAUDE_STATUS_DATA') as f:
        d = json.load(f)
    print(d.get('weekly_tokens', 0))
except:
    print(0)
" 2>/dev/null || echo 0)
    fi

    # Progress bar (pure bash)
    local wpct=$(( WEEKLY_TOKEN_LIMIT > 0 ? weekly_tokens * 100 / WEEKLY_TOKEN_LIMIT : 0 ))
    (( wpct > 100 )) && wpct=100
    local filled=$(( wpct * PROGRESS_BAR_WIDTH / 100 ))
    local empty=$(( PROGRESS_BAR_WIDTH - filled ))
    local wbar="" i
    for (( i=0; i<filled; i++ )); do wbar+="█"; done
    for (( i=0; i<empty;  i++ )); do wbar+="░"; done

    # Time until reset
    local reset_str
    reset_str=$(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
days = (7 - now.weekday()) % 7
if days == 0: days = 7
next_mon = (now + datetime.timedelta(days=days)).replace(hour=0,minute=0,second=0,microsecond=0)
secs = int((next_mon - now).total_seconds())
d, secs = divmod(secs, 86400)
h, m = divmod(secs, 3600)
m //= 60
if d:   print(f'{d}d {h}h')
elif h: print(f'{h}h {m}m')
else:   print(f'{m}m')
" 2>/dev/null || echo "?")

    # Output (no trailing newline so it can embed cleanly in PS1)
    printf ' [claude week:[%s] %d%% | reset:%s]' "$wbar" "$wpct" "$reset_str"
}

# ── Standalone usage ──────────────────────────────────────────────────────────
# When this file is executed directly (not sourced), print status and exit.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    claude_status
    echo
fi
