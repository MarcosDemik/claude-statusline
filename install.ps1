# ============================================================================
# Claude Code Status Line Installer (Windows)
# Shows real session/weekly usage, context window, git info
#
# Usage:
#   irm https://raw.githubusercontent.com/MarcosDemik/claude-statusline/main/install.ps1 | iex
#   — or —
#   .\install.ps1
#
# Requirements: Claude Code CLI (logged in), git (optional)
# No external dependencies (jq/curl not needed — uses native PowerShell)
# ============================================================================

$ErrorActionPreference = "Stop"

$CLAUDE_DIR = "$env:USERPROFILE\.claude"
$SCRIPT_FILE = "$CLAUDE_DIR\statusline-command.ps1"
$SETTINGS_FILE = "$CLAUDE_DIR\settings.json"

function Write-Info($msg)  { Write-Host "  -> " -NoNewline -ForegroundColor Cyan; Write-Host $msg }
function Write-Ok($msg)    { Write-Host "  OK " -NoNewline -ForegroundColor Green; Write-Host $msg }
function Write-Warn($msg)  { Write-Host "  !  " -NoNewline -ForegroundColor Yellow; Write-Host $msg }
function Write-Fail($msg)  { Write-Host "  X  " -NoNewline -ForegroundColor Red; Write-Host $msg; exit 1 }

if (-not (Test-Path $CLAUDE_DIR)) {
    Write-Fail "Diretorio $CLAUDE_DIR nao existe. Rode 'claude' pelo menos uma vez primeiro."
}

Write-Host ""
Write-Host "  Claude Code Status Line Installer (Windows)" -ForegroundColor Cyan
Write-Host "  -----------------------------------------------"
Write-Host ""

# ---------------------------------------------------------------------------
# Write statusline script
# ---------------------------------------------------------------------------
Write-Info "Escrevendo $SCRIPT_FILE..."

$statuslineScript = @'
# Claude Code Status Line — Real usage data from Anthropic API (Windows)
# github.com/MarcosDemik/claude-statusline

$input_data = $input | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Extract fields from JSON
# ---------------------------------------------------------------------------
$model_full = if ($input_data.model.display_name) { $input_data.model.display_name } else { "Claude" }
$cwd = if ($input_data.workspace.current_dir) { $input_data.workspace.current_dir } elseif ($input_data.cwd) { $input_data.cwd } else { "" }
$used_pct = if ($null -ne $input_data.context_window.used_percentage) { [int]$input_data.context_window.used_percentage } else { 0 }
$ctx_size = if ($null -ne $input_data.context_window.context_window_size) { [int]$input_data.context_window.context_window_size } else { 200000 }

# ---------------------------------------------------------------------------
# Model + directory + git
# ---------------------------------------------------------------------------
$model_short = $model_full -replace '^Claude ', ''
if (-not $model_short) { $model_short = $model_full }
$dir = if ($cwd) { Split-Path $cwd -Leaf } else { "" }
$user = $env:USERNAME

$git_info = ""
if ($cwd -and (Get-Command git -ErrorAction SilentlyContinue)) {
    try {
        $branch = git -C $cwd branch --show-current 2>$null
        $changed = (git -C $cwd diff --name-only 2>$null | Measure-Object).Count
        $staged = (git -C $cwd diff --cached --name-only 2>$null | Measure-Object).Count
        $total_changed = $changed + $staged
        if ($branch) { $git_info = " ($branch)" }
        if ($total_changed -gt 0) { $git_info += " $total_changed changed" }
    } catch {}
}

# ---------------------------------------------------------------------------
# Fetch REAL usage from Anthropic OAuth API (cached 2 min)
# ---------------------------------------------------------------------------
$CACHE_FILE = "$env:TEMP\.claude-usage-cache.json"
$CACHE_MAX_AGE = 120

function Fetch-Usage {
    # Try credentials file
    $creds_file = "$env:USERPROFILE\.claude\.credentials.json"
    if (-not (Test-Path $creds_file)) { return $false }

    try {
        $creds = Get-Content $creds_file -Raw | ConvertFrom-Json
        $token = $creds.claudeAiOauth.accessToken
        if (-not $token) { return $false }

        $headers = @{
            "Authorization"  = "Bearer $token"
            "anthropic-beta" = "oauth-2025-04-20"
            "Accept"         = "application/json"
        }

        $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
            -Headers $headers -Method Get -TimeoutSec 5 -ErrorAction Stop

        $response | ConvertTo-Json -Depth 10 | Set-Content $CACHE_FILE -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

# Check cache age
$need_fetch = $true
if (Test-Path $CACHE_FILE) {
    $cache_age = ((Get-Date) - (Get-Item $CACHE_FILE).LastWriteTime).TotalSeconds
    if ($cache_age -lt $CACHE_MAX_AGE) { $need_fetch = $false }
}

if ($need_fetch) { Fetch-Usage | Out-Null }

# Read usage data
$session_pct = 0
$session_reset = ""
$weekly_pct = 0
$weekly_reset = ""
$extra_info = ""

if (Test-Path $CACHE_FILE) {
    try {
        $usage = Get-Content $CACHE_FILE -Raw | ConvertFrom-Json

        $session_pct = if ($usage.five_hour.utilization) { [int]$usage.five_hour.utilization } else { 0 }
        $weekly_pct = if ($usage.seven_day.utilization) { [int]$usage.seven_day.utilization } else { 0 }

        # Session reset
        if ($usage.five_hour.resets_at) {
            $reset_time = [DateTimeOffset]::Parse($usage.five_hour.resets_at)
            $diff = $reset_time - [DateTimeOffset]::UtcNow
            if ($diff.TotalSeconds -gt 0) {
                $h = [int]$diff.TotalHours
                $m = $diff.Minutes
                if ($h -gt 0) { $session_reset = "resets ${h}h ${m}m" }
                else { $session_reset = "resets ${m}m" }
            }
        }

        # Weekly reset
        if ($usage.seven_day.resets_at) {
            $reset_time = [DateTimeOffset]::Parse($usage.seven_day.resets_at)
            $diff = $reset_time - [DateTimeOffset]::UtcNow
            if ($diff.TotalSeconds -gt 0) {
                $d = [int]$diff.TotalDays
                $h = [int]($diff.TotalHours % 24)
                if ($d -gt 0) { $weekly_reset = "resets ${d}d ${h}h" }
                else { $weekly_reset = "resets ${h}h" }
            }
        }

        # Extra usage
        if ($usage.extra_usage.is_enabled -eq $true) {
            if ($null -eq $usage.extra_usage.monthly_limit) {
                $extra_info = "Unlimited"
            } else {
                $extra_info = "$($usage.extra_usage.monthly_limit) limit"
            }
        }
    } catch {}
}

# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------
$e = [char]27
$R       = "$e[0m"
$BOLD    = "$e[1m"
$DIM     = "$e[2m"
$CYAN    = "$e[36m"
$GREEN   = "$e[32m"
$YELLOW  = "$e[33m"
$RED     = "$e[31m"
$WHITE   = "$e[37m"
$GRAY    = "$e[90m"
$MAGENTA = "$e[35m"

# ---------------------------------------------------------------------------
# Progress bar — 15 chars wide
# ---------------------------------------------------------------------------
function Get-Bar($pct) {
    $width = 15
    $filled = [Math]::Min([Math]::Floor($pct * $width / 100), $width)
    if ($pct -gt 0 -and $filled -eq 0) { $filled = 1 }
    $empty = $width - $filled
    return ([string]::new([char]0x2588, $filled) + [string]::new([char]0x2591, $empty))
}

function Get-BarColor($pct) {
    if ($pct -ge 80) { return $RED }
    elseif ($pct -ge 50) { return $YELLOW }
    else { return $GREEN }
}

function Format-K($n) {
    if ($n -ge 1000) { return "$([Math]::Floor($n / 1000))k" }
    return "$n"
}

# ---------------------------------------------------------------------------
# Print
# ---------------------------------------------------------------------------
$ctx_size_k = Format-K $ctx_size
$SEP = [string]::new([char]0x2500, 41)
$LW = 17

# Line 1: model | user | dir (branch) N changed
$line1 = "${CYAN}${BOLD}$model_short${R} ${GRAY}|${R} ${WHITE}$user${R} ${GRAY}|${R} ${WHITE}$dir${R}${MAGENTA}$git_info${R}"
Write-Host $line1

# Line 2: Context Window
$ctx_c = Get-BarColor $used_pct
$ctx_bar = Get-Bar $used_pct
$label = "Context Window".PadRight($LW)
Write-Host "${BOLD}$label${R} ${ctx_c}$ctx_bar${R}  ${GRAY}$used_pct% of $ctx_size_k${R}"

# Line 3: Separator
Write-Host "${DIM}$SEP${R}"

# Line 4: Session
$sess_c = Get-BarColor $session_pct
$sess_bar = Get-Bar $session_pct
$sess_extra = if ($session_reset) { " $([char]0x00B7) $session_reset" } else { "" }
$label = "Session".PadRight($LW)
Write-Host "${BOLD}$label${R} ${sess_c}$sess_bar${R}  ${GRAY}$session_pct% used$sess_extra${R}"

# Line 5: Weekly
$week_c = Get-BarColor $weekly_pct
$week_bar = Get-Bar $weekly_pct
$week_extra = if ($weekly_reset) { " $([char]0x00B7) $weekly_reset" } else { "" }
$label = "Weekly".PadRight($LW)
Write-Host "${BOLD}$label${R} ${week_c}$week_bar${R}  ${GRAY}$weekly_pct% used$week_extra${R}"

# Line 6: Extra usage
if ($extra_info) {
    $label = "Extra usage".PadRight($LW)
    Write-Host "${BOLD}$label${R} ${GREEN}$extra_info${R}"
}
'@

Set-Content -Path $SCRIPT_FILE -Value $statuslineScript -Encoding UTF8
Write-Ok "Script salvo em $SCRIPT_FILE"

# ---------------------------------------------------------------------------
# Update settings.json
# ---------------------------------------------------------------------------
Write-Info "Atualizando $SETTINGS_FILE..."

if (-not (Test-Path $SETTINGS_FILE)) {
    '{}' | Set-Content $SETTINGS_FILE -Encoding UTF8
}

$settings = Get-Content $SETTINGS_FILE -Raw | ConvertFrom-Json
$cmd = "powershell -NoProfile -File `"$SCRIPT_FILE`""
$statusLine = [PSCustomObject]@{ type = "command"; command = $cmd }
if ($settings.PSObject.Properties["statusLine"]) {
    $settings.statusLine = $statusLine
} else {
    $settings | Add-Member -NotePropertyName "statusLine" -NotePropertyValue $statusLine
}
$settings | ConvertTo-Json -Depth 10 | Set-Content $SETTINGS_FILE -Encoding UTF8

Write-Ok "settings.json atualizado"

# ---------------------------------------------------------------------------
# Verify credentials
# ---------------------------------------------------------------------------
$creds_path = "$env:USERPROFILE\.claude\.credentials.json"
if (Test-Path $creds_path) {
    Write-Ok "Credenciais encontradas ($creds_path)"
} else {
    Write-Warn "Credenciais nao encontradas. Faca login no Claude Code primeiro."
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  OK Instalacao concluida!" -ForegroundColor Green
Write-Host ""
Write-Host "  Reinicie o Claude Code para ver a status line."
Write-Host ""
Write-Host "  +-------------------------------------------------------+"
Write-Host "  |  Opus 4.6 | user | project (main) 3 changed          |"
Write-Host "  |  Context Window  ##............  13% of 200k          |"
Write-Host "  |  -----------------------------------------            |"
Write-Host "  |  Session          #.............   7% . resets 4h     |"
Write-Host "  |  Weekly           #.............   4% . resets 6d     |"
Write-Host "  |  Extra usage      Unlimited                           |"
Write-Host "  +-------------------------------------------------------+"
Write-Host ""
