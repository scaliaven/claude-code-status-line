# Why
I recently started using Claude Code and have been fascinated by its capabilities. I’m curious about how much it actually “knows” about its own state. A simple idea I have is to build a function that’s closely tied to Claude Code itself—specifically its usage and runtime status.

As much as I’d like to build the project from one single prompt, I’ve found that some additional debugging and layout refinement prompts are necessary.

# claude-code-status-line

A persistent status bar for [Claude Code](https://claude.ai/code) that shows
model, working directory, session context usage, weekly token budget, and time
until the Monday midnight UTC reset — all in one line at the bottom of the TUI.

```
sonnet-4-6 │ ~/projects/myapp │ ctx:[████████░░] 80% │ week:[███░░░░░░░] 30% (of 1M) │ reset:4d 6h 12m │ cost:$0.042
```

---

## Requirements

- **Claude Code** ≥ 1.x (uses the `StatusLine` hook)
- **bash** or **zsh**
- **python3** (always available where Claude Code runs)
- **jq** *(optional but recommended for faster JSON parsing)*
- **THE PROMPT** *(omitted those about debugging + refinement on layout)*:
  ```txt
  Build a minimal GitHub repo: a shell script that plugs into Claude Code's statusLine hook (receives JSON on stdin each turn) and shows a persistent status bar with model, cwd, session token % with progress bar, weekly token % against a configurable limit, and time until Monday midnight UTC reset. Include an installer that patches ~/.claude/settings.json, a shell function to source in bash/zsh for use outside Claude Code, and a README with manual setup instructions.
  ```
- **comments**: welcome to share your prompts too!
---

## Quick install

```bash
git clone https://github.com/scaliaven/claude-code-status-line.git
cd claude-code-status-line
bash install.sh
```

Restart Claude Code. The status bar appears immediately.

### Custom install location

```bash
INSTALL_DIR=/opt/claude-status bash install.sh
```

---

## Manual setup

If you prefer not to use the installer, follow these steps.

### 1. Copy the hook script

```bash
mkdir -p ~/.local/share/claude-status-line
cp status-line.sh ~/.local/share/claude-status-line/status-line.sh
chmod +x ~/.local/share/claude-status-line/status-line.sh
```

### 2. Create your config (optional)

```bash
mkdir -p ~/.config/claude-status-line
cp config.env.example ~/.config/claude-status-line/config.env
# edit to taste
```

### 3. Patch ~/.claude/settings.json

Open (or create) `~/.claude/settings.json` and add `statusLine` as a
**top-level key** (not inside `hooks`):

```json
{
  "statusLine": {
    "type": "command",
    "command": "/home/YOUR_USERNAME/.local/share/claude-status-line/status-line.sh",
    "refreshInterval": 30
  }
}
```

> **Tip:** `refreshInterval` (seconds) keeps the reset countdown ticking even
> between turns. Omit it to only update on each model reply.

If `~/.claude/settings.json` already has other settings, merge carefully — it
must remain valid JSON. The installer handles this automatically.

### 4. Restart Claude Code

The status bar replaces the default one immediately after restart.

---

## Configuration

Edit `~/.config/claude-status-line/config.env`:

| Variable | Default | Description |
|---|---|---|
| `WEEKLY_TOKEN_LIMIT` | `1000000` | Your plan's weekly token budget |
| `PROGRESS_BAR_WIDTH` | `10` | Block-character width of each bar |
| `SHOW_COST` | `true` | Show session cost in USD |
| `MAX_CWD_LEN` | `30` | Truncate cwd paths longer than this |

Common `WEEKLY_TOKEN_LIMIT` values:

| Plan | Limit |
|---|---|
| Claude Pro | ~1 000 000 |
| Claude Max (5×) | ~5 000 000 |
| Claude Max (20×) | ~20 000 000 |

Weekly usage resets every **Monday at 00:00 UTC**.

---

## Shell integration (outside Claude Code)

`prompt.sh` exposes a `claude_status` function that reads the hook's persisted
state file. This lets you embed weekly usage in your normal shell prompt.

### Bash

```bash
# ~/.bashrc
source /path/to/claude-code-status-line/prompt.sh
PS1='[\u@\h \W]$(claude_status)\$ '
```

### Zsh

```zsh
# ~/.zshrc
source /path/to/claude-code-status-line/prompt.sh
PROMPT='%n@%m %~$(claude_status)%# '
```

### Standalone

```bash
bash /path/to/claude-code-status-line/prompt.sh
# →  [claude week:[███░░░░░░░] 30% | reset:4d 6h]
```

The function prints nothing (silently) when no Claude Code session data exists
yet, so it is safe to add unconditionally.

---

## How token tracking works

The hook receives **cumulative** token counts for the current session on each
call. The script stores per-session deltas in
`~/.local/share/claude-status-line/state.json` and sums them into a weekly
total. Counts reset automatically when the stored week-start timestamp no
longer matches the current Monday.

This means:
- Tokens accumulate correctly across multiple sessions in one week.
- Restarting a session doesn't double-count.
- The state file is plain JSON and safe to inspect or delete.

---

## File layout

```
claude-code-status-line/
├── status-line.sh       # StatusLine hook — run by Claude Code each turn
├── install.sh           # Automated installer
├── prompt.sh            # Shell function for use outside Claude Code
├── config.env.example   # Documented configuration template
└── README.md
```

Runtime files (created automatically):

```
~/.local/share/claude-status-line/
├── status-line.sh       # installed copy of the hook
└── state.json           # weekly token accumulator

~/.config/claude-status-line/
└── config.env           # your personal configuration
```

---

## Uninstall

```bash
# Remove hook from settings.json (edit manually or use jq)
jq 'del(.hooks.statusLine)' ~/.claude/settings.json | sponge ~/.claude/settings.json

# Remove runtime data
rm -rf ~/.local/share/claude-status-line
rm -rf ~/.config/claude-status-line
```

---

## Resources

- [claude-code-tips](https://github.com/ykdojo/claude-code-tips): where I initially have the idea of building a statusline
- [claude-hud](https://github.com/jarrodwatts/claude-hud)
