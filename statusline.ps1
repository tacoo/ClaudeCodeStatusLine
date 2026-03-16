# Single line: CWD@branch | tokens | %used | %remain | 5h bar in Xh | 7d bar in Xd | extra
# Windows-only PowerShell version of statusline.sh

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'

$jsonInput = [Console]::In.ReadToEnd().Trim()

if (-not $jsonInput) {
    "Claude"
    exit 0
}

$data = $jsonInput | ConvertFrom-Json

# ANSI colors matching oh-my-posh theme
$e       = [char]0x1b
$orange  = "$e[38;2;255;176;85m"
$green   = "$e[38;2;0;160;0m"
$cyan    = "$e[38;2;46;149;153m"
$red     = "$e[38;2;255;85;85m"
$yellow  = "$e[38;2;230;200;0m"
$white   = "$e[38;2;220;220;220m"
$dim     = "$e[2m"
$reset   = "$e[0m"

function Format-Tokens([long]$num) {
    if ($num -ge 1000000) { return "{0:F1}m" -f ($num / 1000000) }
    if ($num -ge 1000)    { return "{0:F0}k" -f ($num / 1000) }
    return "$num"
}

function Build-Bar([int]$pct, [int]$width) {
    if ($pct -lt 0)   { $pct = 0 }
    if ($pct -gt 100)  { $pct = 100 }

    $filled = [math]::Floor($pct * $width / 100)
    $empty  = $width - $filled

    $barColor = if ($pct -ge 90) { $red }
                elseif ($pct -ge 70) { $yellow }
                elseif ($pct -ge 50) { $orange }
                else { $green }

    $filledStr = ([char]0x25CF).ToString() * $filled   # ●
    $emptyStr  = ([char]0x25CB).ToString() * $empty    # ○

    return "${barColor}${filledStr}${dim}${emptyStr}${reset}"
}

function Format-RemainingTime([string]$isoStr) {
    if (-not $isoStr -or $isoStr -eq 'null') { return $null }

    try {
        $resetTime = [DateTime]::Parse($isoStr, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $diff = $resetTime - [DateTime]::UtcNow
    } catch {
        return $null
    }

    if ($diff.TotalSeconds -le 0) { return "0m" }

    $days  = [int][math]::Floor($diff.TotalDays)
    $hours = $diff.Hours
    $mins  = $diff.Minutes

    if ($days -gt 0)  { return "{0}d{1}h" -f $days, $hours }
    if ($hours -gt 0) { return "{0}h{1}m" -f $hours, $mins }
    return "{0}m" -f $mins
}

function Get-OAuthToken {
    # 1. Env var override
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        return $env:CLAUDE_CODE_OAUTH_TOKEN
    }

    # 2. Windows credentials file
    $credsFile = Join-Path $env:USERPROFILE ".claude\.credentials.json"
    if (Test-Path $credsFile) {
        try {
            $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
            $token = $creds.claudeAiOauth.accessToken
            if ($token -and $token -ne 'null') { return $token }
        } catch {}
    }

    return $null
}

# ===== Extract data from JSON =====

$size = if ($data.context_window.context_window_size) { [long]$data.context_window.context_window_size } else { 200000 }
if ($size -eq 0) { $size = 200000 }

$inputTokens = if ($data.context_window.current_usage.input_tokens) { [long]$data.context_window.current_usage.input_tokens } else { 0 }
$cacheCreate = if ($data.context_window.current_usage.cache_creation_input_tokens) { [long]$data.context_window.current_usage.cache_creation_input_tokens } else { 0 }
$cacheRead   = if ($data.context_window.current_usage.cache_read_input_tokens) { [long]$data.context_window.current_usage.cache_read_input_tokens } else { 0 }
$current = $inputTokens + $cacheCreate + $cacheRead

$usedTokens  = Format-Tokens $current
$totalTokens = Format-Tokens $size

$pctUsed   = if ($size -gt 0) { [int][math]::Floor($current * 100 / $size) } else { 0 }
$pctRemain = 100 - $pctUsed

# ===== Build single-line output =====
$out = ""

# Current working directory
$cwd = $data.cwd
if ($cwd) {
    $displayDir = Split-Path -Leaf $cwd
    $gitBranch = & git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
    $out += "${cyan}${displayDir}${reset}"
    if ($gitBranch) {
        $out += "${dim}@${reset}${green}${gitBranch}${reset}"
    }
}

$sep = " ${dim}|${reset} "

$out += $sep
$out += "${orange}${usedTokens}/${totalTokens}${reset}"
$out += $sep
$out += "${green}${pctUsed}%${reset} ${dim}used${reset}"
$out += $sep
$out += "${cyan}${pctRemain}%${reset} ${dim}remain${reset}"

# ===== Usage limits with progress bars (cached) =====
$cacheDir  = Join-Path $env:TEMP "claude"
$cacheFile = Join-Path $cacheDir "statusline-usage-cache.json"
$cacheMaxAge = 60  # seconds

if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

$needsRefresh = $true
$usageData = $null

function Try-LoadCache {
    if (Test-Path $cacheFile) {
        $fileInfo = Get-Item $cacheFile
        $cacheAge = ((Get-Date) - $fileInfo.LastWriteTime).TotalSeconds
        if ($cacheAge -lt $script:cacheMaxAge) {
            $script:needsRefresh = $false
            $script:usageData = Get-Content $cacheFile -Raw | ConvertFrom-Json
        }
    }
}

Try-LoadCache

if ($needsRefresh) {
    $mutexName = "Global\ClaudeStatusLineCache"
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    $acquired = $false

    try {
        $acquired = $mutex.WaitOne(0)
        if ($acquired) {
            # Re-check cache after acquiring lock
            Try-LoadCache
            if ($needsRefresh) {
                $token = Get-OAuthToken
                if ($token) {
                    try {
                        $headers = @{
                            "Accept"         = "application/json"
                            "Content-Type"   = "application/json"
                            "Authorization"  = "Bearer $token"
                            "anthropic-beta" = "oauth-2025-04-20"
                            "User-Agent"     = "claude-code/2.1.34"
                        }
                        $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
                            -Headers $headers -TimeoutSec 10 -ErrorAction Stop

                        $usageData = $response
                        # Atomic write
                        $tmpFile = Join-Path $cacheDir (".cache." + [System.IO.Path]::GetRandomFileName())
                        $response | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpFile -Encoding UTF8
                        Move-Item -Path $tmpFile -Destination $cacheFile -Force
                    } catch {}
                }
            }
        }
    } catch {} finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }

    # Fall back to stale cache
    if (-not $usageData -and (Test-Path $cacheFile)) {
        $usageData = Get-Content $cacheFile -Raw | ConvertFrom-Json
    }
}

if ($usageData) {
    $barWidth = 6

    # ---- 5-hour (current) ----
    $fiveHourPct = [int][math]::Round(($usageData.five_hour.utilization -as [double]))
    $fiveHourResetIso = $usageData.five_hour.resets_at
    $fiveHourRemaining = Format-RemainingTime $fiveHourResetIso
    $fiveHourBar = Build-Bar $fiveHourPct $barWidth

    $out += "${sep} ${fiveHourBar} ${cyan}${fiveHourPct}%${reset}"
    if ($fiveHourRemaining) { $out += " ${dim}in ${fiveHourRemaining}${reset}" }

    # ---- 7-day (weekly) ----
    $sevenDayPct = [int][math]::Round(($usageData.seven_day.utilization -as [double]))
    $sevenDayResetIso = $usageData.seven_day.resets_at
    $sevenDayRemaining = Format-RemainingTime $sevenDayResetIso
    $sevenDayBar = Build-Bar $sevenDayPct $barWidth

    $out += "${sep} ${sevenDayBar} ${cyan}${sevenDayPct}%${reset}"
    if ($sevenDayRemaining) { $out += " ${dim}in ${sevenDayRemaining}${reset}" }

    # ---- Extra usage ----
    if ($usageData.extra_usage.is_enabled -eq $true) {
        $extraPct   = [int][math]::Round(($usageData.extra_usage.utilization -as [double]))
        $extraUsed  = "{0:F2}" -f (($usageData.extra_usage.used_credits -as [double]) / 100)
        $extraLimit = "{0:F2}" -f (($usageData.extra_usage.monthly_limit -as [double]) / 100)
        $extraBar   = Build-Bar $extraPct $barWidth

        $out += "${sep}${white}extra${reset} ${extraBar} ${cyan}`$${extraUsed}/`$${extraLimit}${reset}"
    }
}

# Off-peak indicator (peak = Mon-Fri 8:00-13:59 ET, until 2026-03-27)
try {
    $etZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $etNow  = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $etZone)
    $etDow  = [int]$etNow.DayOfWeek  # 0=Sun..6=Sat
    $etHour = $etNow.Hour
    $etDate = [int]$etNow.ToString("yyyyMMdd")

    if ($etDate -le 20260327) {
        $isWeekend = ($etDow -eq 0 -or $etDow -eq 6)
        $isOffHours = ($etHour -lt 8 -or $etHour -ge 14)
        if ($isWeekend -or $isOffHours) {
            $out += "${sep}${dim}off-peak${reset}"
        }
    }
} catch {}

# Output single line
$out

exit 0
