#!/usr/bin/env bash
# Claude Code StatusLine hook — outputs one line of status text each turn.
#
# JSON received on stdin (Claude Code ≥ 1.x):
#   session_id           string
#   cwd                  string
#   model.id             string   e.g. "claude-sonnet-4-6"
#   model.display_name   string   e.g. "Claude Sonnet 4.6"
#   context_window.{total_input_tokens, total_output_tokens,
#                   context_window_size, used_percentage}
#   rate_limits.seven_day.{used_percentage, resets_at}   (Pro/Max only)
#
# Stdout → replaces the default Claude Code status bar.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-status-line"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-status-line/config.env"
STATE_FILE="$DATA_DIR/state.json"

mkdir -p "$DATA_DIR"

# ── Config (overridable via config.env) ────────────────────────────────────────
WEEKLY_TOKEN_LIMIT=1000000   # fallback if rate_limits absent (free/Team plans)
PROGRESS_BAR_WIDTH=10        # number of block chars in each bar
MAX_CWD_LEN=30               # truncate cwd paths longer than this

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ── JSON parse ─────────────────────────────────────────────────────────────────
# Reads stdin once; sets global variables.
parse_stdin() {
    local raw
    raw=$(cat)
    [[ -z "$raw" ]] && raw='{}'

    if command -v jq &>/dev/null; then
        SESSION_ID=$(   jq -r '.session_id                              // "unknown"' <<< "$raw")
        MODEL=$(        jq -r '.model.display_name // .model.id         // "unknown"' <<< "$raw")
        CWD=$(          jq -r '.cwd                                     // "."'       <<< "$raw")
        CTX_IN=$(       jq -r '.context_window.total_input_tokens       // 0'         <<< "$raw")
        CTX_OUT=$(      jq -r '.context_window.total_output_tokens      // 0'         <<< "$raw")
        CTX_SIZE=$(     jq -r '.context_window.context_window_size      // 200000'    <<< "$raw")
        CTX_PCT=$(      jq -r '.context_window.used_percentage          // 0'         <<< "$raw")
        # rate_limits present on Pro/Max; empty string when absent
        RATE_5H_PCT=$(  jq -r '.rate_limits.five_hour.used_percentage   // ""'        <<< "$raw")
        RATE_5H_RESET=$(jq -r '.rate_limits.five_hour.resets_at         // ""'        <<< "$raw")
        RATE_WEEK_PCT=$(jq -r '.rate_limits.seven_day.used_percentage   // ""'        <<< "$raw")
        RATE_WEEK_RESET=$(jq -r '.rate_limits.seven_day.resets_at       // ""'        <<< "$raw")
    else
        # Python3 fallback — pipe raw JSON on stdin, never pass as CLI arg
        eval "$(printf '%s' "$raw" | python3 <<'PYEOF'
import json, sys
d    = json.load(sys.stdin)
cw   = d.get('context_window', {})
rl5  = d.get('rate_limits', {}).get('five_hour', {})
rl7  = d.get('rate_limits', {}).get('seven_day', {})
mdl  = d.get('model', {})
def q(v): return str(v).replace("'", r"'\''")
name = mdl.get('display_name') or mdl.get('id', 'unknown')
print(f"SESSION_ID='{q(d.get('session_id','unknown'))}'")
print(f"MODEL='{q(name)}'")
print(f"CWD='{q(d.get('cwd','.'))}'")
print(f"CTX_IN={cw.get('total_input_tokens',0)}")
print(f"CTX_OUT={cw.get('total_output_tokens',0)}")
print(f"CTX_SIZE={cw.get('context_window_size',200000)}")
print(f"CTX_PCT={cw.get('used_percentage') or 0}")
print(f"RATE_5H_PCT='{rl5.get('used_percentage','')}'")
print(f"RATE_5H_RESET='{rl5.get('resets_at','')}'")
print(f"RATE_WEEK_PCT='{rl7.get('used_percentage','')}'")
print(f"RATE_WEEK_RESET='{rl7.get('resets_at','')}'")
PYEOF
)"
    fi
}

# ── Progress bar ───────────────────────────────────────────────────────────────
# progress_bar <0-100> [width]
progress_bar() {
    local pct=$1 width=${2:-$PROGRESS_BAR_WIDTH}
    (( pct < 0   )) && pct=0
    (( pct > 100 )) && pct=100
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    printf '%s' "$bar"
}

# ── Shorten model name ─────────────────────────────────────────────────────────
# "Claude Sonnet 4.6" → "Sonnet 4.6"  |  "claude-sonnet-4-6" → "sonnet-4-6"
short_model() {
    local m="$1"
    m="${m#Claude }"     # strip leading "Claude " (display_name form)
    m="${m#claude-}"     # strip leading "claude-" (id form)
    printf '%s' "$m"
}

# ── Shorten path ───────────────────────────────────────────────────────────────
short_path() {
    local p="${1/#$HOME/\~}"
    if (( ${#p} > MAX_CWD_LEN )); then
        p="…/$(printf '%s' "$p" | rev | cut -d/ -f1-2 | rev)"
    fi
    printf '%s' "$p"
}

# ── Weekly token tracking (fallback when rate_limits absent) ───────────────────
# Returns weekly token total after updating state.
update_weekly_manual() {
    local session_id=$1
    local total_session_tokens=$2

    local week_start
    week_start=$(python3 -c "
import datetime, calendar
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
monday = now - datetime.timedelta(
    days=now.weekday(), hours=now.hour, minutes=now.minute,
    seconds=now.second, microseconds=now.microsecond)
print(int(calendar.timegm(monday.timetuple())))
")

    local weekly_tokens=0 last_session_tokens=0

    if [[ -f "$STATE_FILE" ]]; then
        if command -v jq &>/dev/null; then
            local stored
            stored=$(jq -r '.week_start // 0' "$STATE_FILE")
            if [[ "$stored" == "$week_start" ]]; then
                weekly_tokens=$(jq -r '.weekly_tokens // 0' "$STATE_FILE")
                last_session_tokens=$(jq -r \
                    --arg sid "$session_id" \
                    '.sessions[$sid].last_total // 0' "$STATE_FILE")
            fi
        else
            eval "$(printf '%s\n%s\n%s' "$STATE_FILE" "$session_id" "$week_start" \
                | python3 <<'PYEOF'
import json, sys
lines = sys.stdin.read().splitlines()
path, sid, wk = lines[0], lines[1], int(lines[2])
try:
    with open(path) as f:
        data = json.load(f)
    if data.get('week_start', 0) == wk:
        print(f"weekly_tokens={data.get('weekly_tokens', 0)}")
        last = data.get('sessions', {}).get(sid, {}).get('last_total', 0)
        print(f"last_session_tokens={last}")
    else:
        print("weekly_tokens=0"); print("last_session_tokens=0")
except Exception:
    print("weekly_tokens=0"); print("last_session_tokens=0")
PYEOF
)"
        fi
    fi

    local delta=$(( total_session_tokens - last_session_tokens ))
    (( delta < 0 )) && delta=0
    weekly_tokens=$(( weekly_tokens + delta ))

    # Persist — stdout suppressed because this runs inside $()
    python3 - "$STATE_FILE" "$session_id" \
              "$week_start" "$weekly_tokens" "$total_session_tokens" <<'PYEOF'
import json, sys, os
path, sid, week_start, weekly_tokens, last_total = sys.argv[1:]
week_start = int(week_start); weekly_tokens = int(weekly_tokens); last_total = int(last_total)
try:
    with open(path) as f: data = json.load(f)
    if data.get('week_start', 0) != week_start: data = {}
except Exception: data = {}
data['week_start'] = week_start
data['weekly_tokens'] = weekly_tokens
data.setdefault('sessions', {})[sid] = {'last_total': last_total}
tmp = path + '.tmp'
with open(tmp, 'w') as f: json.dump(data, f)
os.replace(tmp, path)
PYEOF

    printf '%d' "$weekly_tokens"
}

# ── Time until reset ───────────────────────────────────────────────────────────
# time_until_reset [unix_timestamp]
# Without arg → next Monday 00:00 UTC.  With arg → time until that timestamp.
time_until_reset() {
    python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
resets_at = '${1:-}'
if resets_at:
    target = datetime.datetime.fromtimestamp(int(resets_at), datetime.timezone.utc).replace(tzinfo=None)
else:
    days = (7 - now.weekday()) % 7 or 7
    target = (now + datetime.timedelta(days=days)).replace(
        hour=0, minute=0, second=0, microsecond=0)
secs = max(0, int((target - now).total_seconds()))
d, r = divmod(secs, 86400); h, r = divmod(r, 3600); m = r // 60
if d:   print(f'{d}d {h}h {m}m')
elif h: print(f'{h}h {m}m')
else:   print(f'{m}m')
"
}

# ── Render ─────────────────────────────────────────────────────────────────────
render() {
    local total_session=$(( CTX_IN + CTX_OUT ))

    # ── 5-hour rate limit % ────────────────────────────────────────────────────
    local h5pct h5_reset_arg=""
    if [[ -n "$RATE_5H_PCT" ]]; then
        h5pct=$(python3 -c "print(round(${RATE_5H_PCT}))" 2>/dev/null || echo 0)
        [[ -n "$RATE_5H_RESET" ]] && h5_reset_arg="$RATE_5H_RESET"
    else
        # Fallback: use context window % when rate_limits absent
        h5pct=$(python3 -c "print(round(${CTX_PCT:-0}))" 2>/dev/null || echo 0)
    fi
    (( h5pct > 100 )) && h5pct=100

    # ── Weekly % ──────────────────────────────────────────────────────────────
    local wpct week_reset_arg=""
    if [[ -n "$RATE_WEEK_PCT" ]]; then
        wpct=$(python3 -c "print(round(${RATE_WEEK_PCT}))" 2>/dev/null || echo 0)
        [[ -n "$RATE_WEEK_RESET" ]] && week_reset_arg="$RATE_WEEK_RESET"
        weekly_label="week"
    else
        local weekly
        weekly=$(update_weekly_manual "$SESSION_ID" "$total_session")
        wpct=$(( WEEKLY_TOKEN_LIMIT > 0 ? weekly * 100 / WEEKLY_TOKEN_LIMIT : 0 ))
        (( wpct > 100 )) && wpct=100
        weekly_label="week(~$(numfmt --to=si "$WEEKLY_TOKEN_LIMIT" 2>/dev/null \
                              || echo "${WEEKLY_TOKEN_LIMIT}"))"
    fi

    # Reset countdown: prefer 5h timer; fall back to weekly; then Monday midnight
    local reset_arg="${h5_reset_arg:-${week_reset_arg:-}}"

    # ── Components ─────────────────────────────────────────────────────────────
    local model_s; model_s=$(short_model "$MODEL")
    local cwd_s;   cwd_s=$(short_path "$CWD")
    local h5bar;   h5bar=$(progress_bar "$h5pct")
    local wbar;    wbar=$(progress_bar "$wpct")
    local reset_s; reset_s=$(time_until_reset "$reset_arg")

    # Line 1: model + cwd
    printf '%s  %s\n' "$model_s" "$cwd_s"
    # Line 2: 5h rate limit | weekly | reset countdown
    printf '5h:[%s] %d%%  %s:[%s] %d%%  reset:%s\n' \
        "$h5bar" "$h5pct" \
        "$weekly_label" "$wbar" "$wpct" \
        "$reset_s"
}

# ── Main ───────────────────────────────────────────────────────────────────────
parse_stdin
render
