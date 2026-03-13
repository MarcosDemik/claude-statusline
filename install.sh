#!/usr/bin/env bash
# ============================================================================
# Claude Code Status Line Installer
# Shows real session/weekly usage, context window, git info
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/MarcosDemik/claude-statusline/main/install.sh | bash
#   -or —
#   bash install-statusline.sh
#
# Requirements: jq, curl, git (optional), Claude Code CLI
# Supports: Linux, macOS
# ============================================================================

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SCRIPT_FILE="$CLAUDE_DIR/statusline-command.sh"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

# Colors for installer output
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
R='\033[0m'

info()  { printf "${CYAN}→${R} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${R} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${R} %s\n" "$1"; }
fail()  { printf "${RED}✗${R} %s\n" "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || fail "jq não encontrado. Instale: sudo apt install jq (Linux) ou brew install jq (macOS)"
command -v curl >/dev/null 2>&1 || fail "curl não encontrado."
[ -d "$CLAUDE_DIR" ] || fail "Diretório $CLAUDE_DIR não existe. Rode 'claude' pelo menos uma vez primeiro."

echo ""
printf "${BOLD}${CYAN}  Claude Code Status Line Installer${R}\n"
echo "  ─────────────────────────────────────"
echo ""

# ---------------------------------------------------------------------------
# Detect OS for stat command compatibility
# ---------------------------------------------------------------------------
if [[ "$(uname)" == "Darwin" ]]; then
  STAT_CMD='stat -f %m'
else
  STAT_CMD='stat -c %Y'
fi

# ---------------------------------------------------------------------------
# Write statusline script
# ---------------------------------------------------------------------------
info "Escrevendo $SCRIPT_FILE..."

cat > "$SCRIPT_FILE" << 'STATUSLINE_EOF'
#!/usr/bin/env bash
# Claude Code Status Line -Real usage data from Anthropic API
# github.com/MarcosDemik/claude-statusline

input=$(cat)

# ---------------------------------------------------------------------------
# Extract fields from JSON (context window data from Claude Code)
# ---------------------------------------------------------------------------
model_full=$(echo "$input" | jq -r '.model.display_name // "Claude"')
cwd=$(echo "$input"        | jq -r '.workspace.current_dir // .cwd // ""')
used_pct=$(echo "$input"   | jq -r '.context_window.used_percentage // 0')
ctx_size=$(echo "$input"   | jq -r '.context_window.context_window_size // 200000')

# ---------------------------------------------------------------------------
# Model + directory + git
# ---------------------------------------------------------------------------
model_short="${model_full#Claude }"
[ -z "$model_short" ] && model_short="$model_full"
dir=$(basename "$cwd")
user=$(whoami)

git_info=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  changed=$(git -C "$cwd" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  staged=$(git -C "$cwd" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  total_changed=$(( changed + staged ))
  [ -n "$branch" ] && git_info=" ($branch)"
  if [ "$total_changed" -gt 0 ]; then
    git_info="${git_info} ${total_changed} changed"
  fi
fi

# ---------------------------------------------------------------------------
# Fetch REAL usage from Anthropic OAuth API (cached 2 min to avoid 429)
# ---------------------------------------------------------------------------
CACHE_FILE="/tmp/.claude-usage-cache-$(id -u).json"
CACHE_MAX_AGE=120

fetch_usage() {
  local creds_file="$HOME/.claude/.credentials.json"

  # macOS: try Keychain first
  if [[ "$(uname)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
    local keychain_data
    keychain_data=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
    if [ -n "$keychain_data" ]; then
      local token
      token=$(echo "$keychain_data" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
      if [ -n "$token" ]; then
        local result
        result=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
          -H "Authorization: Bearer $token" \
          -H "anthropic-beta: oauth-2025-04-20" \
          -H "Accept: application/json" 2>/dev/null)
        if echo "$result" | jq -e '.five_hour' >/dev/null 2>&1; then
          echo "$result" > "$CACHE_FILE"
          return 0
        fi
      fi
    fi
  fi

  # Linux / fallback: credentials file
  [ ! -f "$creds_file" ] && return 1

  local token
  token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
  [ -z "$token" ] && return 1

  local result
  result=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Accept: application/json" 2>/dev/null)

  echo "$result" | jq -e '.five_hour' >/dev/null 2>&1 || return 1
  echo "$result" > "$CACHE_FILE"
}

# Check cache age (cross-platform)
need_fetch=1
if [ -f "$CACHE_FILE" ]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    cache_mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  else
    cache_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  fi
  cache_age=$(( $(date +%s) - cache_mtime ))
  [ "$cache_age" -lt "$CACHE_MAX_AGE" ] && need_fetch=0
fi

[ "$need_fetch" -eq 1 ] && fetch_usage

# Read usage data (from cache)
session_pct=0
session_reset=""
weekly_pct=0
weekly_reset=""
extra_info=""

if [ -f "$CACHE_FILE" ]; then
  session_pct=$(jq -r '.five_hour.utilization // 0' "$CACHE_FILE" 2>/dev/null | cut -d. -f1)
  weekly_pct=$(jq -r '.seven_day.utilization // 0' "$CACHE_FILE" 2>/dev/null | cut -d. -f1)

  # Session reset time
  session_reset_raw=$(jq -r '.five_hour.resets_at // empty' "$CACHE_FILE" 2>/dev/null)
  if [ -n "$session_reset_raw" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then
      reset_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "$(echo "$session_reset_raw" | cut -d. -f1)" +%s 2>/dev/null || echo 0)
    else
      reset_epoch=$(date -d "$session_reset_raw" +%s 2>/dev/null || echo 0)
    fi
    now_epoch=$(date +%s)
    if [ "$reset_epoch" -gt "$now_epoch" ] 2>/dev/null; then
      diff_sec=$(( reset_epoch - now_epoch ))
      diff_h=$(( diff_sec / 3600 ))
      diff_m=$(( (diff_sec % 3600) / 60 ))
      if [ "$diff_h" -gt 0 ]; then
        session_reset="resets ${diff_h}h ${diff_m}m"
      else
        session_reset="resets ${diff_m}m"
      fi
    fi
  fi

  # Weekly reset time
  weekly_reset_raw=$(jq -r '.seven_day.resets_at // empty' "$CACHE_FILE" 2>/dev/null)
  if [ -n "$weekly_reset_raw" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then
      reset_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "$(echo "$weekly_reset_raw" | cut -d. -f1)" +%s 2>/dev/null || echo 0)
    else
      reset_epoch=$(date -d "$weekly_reset_raw" +%s 2>/dev/null || echo 0)
    fi
    now_epoch=$(date +%s)
    if [ "$reset_epoch" -gt "$now_epoch" ] 2>/dev/null; then
      diff_sec=$(( reset_epoch - now_epoch ))
      diff_d=$(( diff_sec / 86400 ))
      diff_h=$(( (diff_sec % 86400) / 3600 ))
      if [ "$diff_d" -gt 0 ]; then
        weekly_reset="resets ${diff_d}d ${diff_h}h"
      else
        weekly_reset="resets ${diff_h}h"
      fi
    fi
  fi

  # Extra usage
  extra_enabled=$(jq -r '.extra_usage.is_enabled // false' "$CACHE_FILE" 2>/dev/null)
  extra_limit=$(jq -r '.extra_usage.monthly_limit // "null"' "$CACHE_FILE" 2>/dev/null)
  if [ "$extra_enabled" = "true" ]; then
    if [ "$extra_limit" = "null" ]; then
      extra_info="Unlimited"
    else
      extra_info="$extra_limit limit"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------
R='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
WHITE='\033[37m'
GRAY='\033[90m'
MAGENTA='\033[35m'

# ---------------------------------------------------------------------------
# Progress bar -15 chars wide
# ---------------------------------------------------------------------------
bar() {
  local pct=$1 width=15 filled=0
  if [ -n "$pct" ] && [ "$pct" -eq "$pct" ] 2>/dev/null; then
    filled=$(( pct * width / 100 ))
    [ "$filled" -gt "$width" ] && filled=$width
    [ "$pct" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
  fi
  local empty=$(( width - filled ))
  local s=""
  for i in $(seq 1 $filled 2>/dev/null); do s="${s}█"; done
  for i in $(seq 1 $empty  2>/dev/null); do s="${s}░"; done
  printf "%s" "$s"
}

bar_color() {
  local pct=$1
  if [ -n "$pct" ] && [ "$pct" -eq "$pct" ] 2>/dev/null; then
    if   [ "$pct" -ge 80 ]; then printf "%s" "$RED"
    elif [ "$pct" -ge 50 ]; then printf "%s" "$YELLOW"
    else                         printf "%s" "$GREEN"
    fi
  else
    printf "%s" "$GREEN"
  fi
}

fmt_k() {
  local n=$1
  if [ "$n" -ge 1000 ] 2>/dev/null; then
    printf "%dk" "$(( n / 1000 ))"
  else
    printf "%d" "$n"
  fi
}

# ---------------------------------------------------------------------------
# Print
# ---------------------------------------------------------------------------
ctx_size_k=$(fmt_k "$ctx_size")
ctx_pct="${used_pct%%.*}"
[ -z "$ctx_pct" ] && ctx_pct=0

SEP="─────────────────────────────────────────"
LW=17

# Line 1: model | user | dir (branch) N changed
printf "${CYAN}${BOLD}%s${R} ${GRAY}|${R} ${WHITE}%s${R} ${GRAY}|${R} ${WHITE}%s${R}${MAGENTA}%s${R}\n" \
  "$model_short" "$user" "$dir" "$git_info"

# Line 2: Context Window
ctx_c=$(bar_color "$ctx_pct")
printf "${BOLD}%-${LW}s${R} ${ctx_c}%s${R}  ${GRAY}%d%% of %s${R}\n" \
  "Context Window" "$(bar "$ctx_pct")" "$ctx_pct" "$ctx_size_k"

# Line 3: Separator
printf "${DIM}%s${R}\n" "$SEP"

# Line 4: Session -5h window
sess_c=$(bar_color "$session_pct")
sess_extra=""
[ -n "$session_reset" ] && sess_extra=" · $session_reset"
printf "${BOLD}%-${LW}s${R} ${sess_c}%s${R}  ${GRAY}%d%% used%s${R}\n" \
  "Session" "$(bar "$session_pct")" "$session_pct" "$sess_extra"

# Line 5: Weekly -7d window
week_c=$(bar_color "$weekly_pct")
week_extra=""
[ -n "$weekly_reset" ] && week_extra=" · $weekly_reset"
printf "${BOLD}%-${LW}s${R} ${week_c}%s${R}  ${GRAY}%d%% used%s${R}\n" \
  "Weekly" "$(bar "$weekly_pct")" "$weekly_pct" "$week_extra"

# Line 6: Extra usage (if enabled)
if [ -n "$extra_info" ]; then
  printf "${BOLD}%-${LW}s${R} ${GREEN}%s${R}\n" \
    "Extra usage" "$extra_info"
fi
STATUSLINE_EOF

chmod +x "$SCRIPT_FILE"
ok "Script salvo em $SCRIPT_FILE"

# ---------------------------------------------------------------------------
# Update settings.json
# ---------------------------------------------------------------------------
info "Atualizando $SETTINGS_FILE..."

if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Use jq to add/update statusLine entry
TMPFILE=$(mktemp)
jq --arg cmd "bash $HOME/.claude/statusline-command.sh" \
  '.statusLine = { "type": "command", "command": $cmd }' \
  "$SETTINGS_FILE" > "$TMPFILE" && mv "$TMPFILE" "$SETTINGS_FILE"

ok "settings.json atualizado"

# ---------------------------------------------------------------------------
# Verify credentials
# ---------------------------------------------------------------------------
if [[ "$(uname)" == "Darwin" ]]; then
  if security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
    ok "Credenciais encontradas (macOS Keychain)"
  else
    warn "Credenciais não encontradas no Keychain. Faça login no Claude Code primeiro."
  fi
elif [ -f "$HOME/.claude/.credentials.json" ]; then
  ok "Credenciais encontradas (~/.claude/.credentials.json)"
else
  warn "Credenciais não encontradas. Faça login no Claude Code primeiro."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
printf "${GREEN}${BOLD}  ✓ Instalação concluída!${R}\n"
echo ""
echo "  Reinicie o Claude Code para ver a status line."
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Opus 4.6 | user | project (main) 3 changed        │"
echo "  │  Context Window  ██░░░░░░░░░░░░░  13% of 200k      │"
echo "  │  ─────────────────────────────────────────           │"
echo "  │  Session          █░░░░░░░░░░░░░░  7% · resets 4h   │"
echo "  │  Weekly            █░░░░░░░░░░░░░░  4% · resets 6d  │"
echo "  │  Extra usage       Unlimited                         │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
