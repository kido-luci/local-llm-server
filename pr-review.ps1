# pr-review.ps1 — review a GitHub PR (or a raw diff) with a local Ollama model.
#
#   .\pr-review.ps1 -Pr 78 -Repo kido-luci/watch-your-ai-code            # print review (dry-run)
#   .\pr-review.ps1 -Pr 78 -Repo ... -Model deepseek-review              # deeper model
#   .\pr-review.ps1 -Pr 78 -Repo ... -Post                               # post as a PR comment
#   .\pr-review.ps1 -Pr 78 -Repo ... -OutFile review.md                  # also save to file
#
# Dry-run by default: prints markdown to stdout, posts nothing. Needs `gh` on PATH
# and Ollama reachable at $Api. PowerShell 5.1 compatible.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Pr,
    [string]$Repo,
    [string]$Model = 'qwen-review',
    [int]$ChunkThreshold = 40000,
    [switch]$Post,
    [string]$OutFile,
    [string]$Api = 'http://localhost:11434/v1/chat/completions'
)

$ErrorActionPreference = 'Stop'

$System = @'
You are a senior code reviewer. Inspect the git diff below and list ONLY real,
specific, actionable problems: logic bugs, nil/null deref, missing error handling,
resource leaks, race conditions, off-by-one, unhandled edge cases, security holes,
broken invariants.

For EACH problem, output exactly one line in this format:
- [LEVEL] `file:line` — short description + how to fix

LEVEL is one of {HIGH, MED, LOW}. Skip trivial style nits. If there is no significant
problem, say "No significant issues found." Respond in English, be concise, do NOT
repeat code, and do NOT invent files/lines that are not in the diff.
'@

function Invoke-LLM {
    param([string]$UserContent)
    $body = @{
        model       = $Model
        temperature = 0.2
        stream      = $false
        messages    = @(
            @{ role = 'system'; content = $System },
            @{ role = 'user';   content = $UserContent }
        )
    } | ConvertTo-Json -Depth 8
    # PS 5.1 mangles a string -Body on non-trivial payloads (server sees invalid JSON);
    # send explicit UTF-8 bytes instead.
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $resp = Invoke-WebRequest -Uri $Api -Method Post -Body $bytes -ContentType 'application/json' -TimeoutSec 1200 -UseBasicParsing
    $txt  = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    $content = ($txt | ConvertFrom-Json).choices[0].message.content
    # DeepSeek-R1 emits a <think>…</think> chain-of-thought; keep only the verdict.
    return ($content -replace '(?s)<think>.*?</think>', '').Trim()
}

# --- fetch the diff --------------------------------------------------------
$ghArgs = @('pr', 'diff', $Pr)
if ($Repo) { $ghArgs += @('--repo', $Repo) }
$diff = (& gh @ghArgs | Out-String)
if (-not $diff.Trim()) { Write-Error "Empty diff for PR #$Pr."; exit 1 }

Write-Host "[pr-review] PR #$Pr  model=$Model  diff=$($diff.Length) chars" -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# --- review: single-shot if small, else per-file -------------------------
if ($diff.Length -le $ChunkThreshold) {
    $review = Invoke-LLM -UserContent "Git diff cần review:`n`n$diff"
} else {
    $parts = [regex]::Split($diff, '(?m)^(?=diff --git )') | Where-Object { $_.Trim() }
    Write-Host "[pr-review] large diff -> reviewing $($parts.Count) files separately" -ForegroundColor Yellow
    $sections = foreach ($p in $parts) {
        $file = ([regex]::Match($p, 'b/(.+)')).Groups[1].Value.Trim()
        Write-Host "  - $file" -ForegroundColor DarkGray
        $r = Invoke-LLM -UserContent "Git diff của file ``$file``:`n`n$p"
        "### ``$file```n$r"
    }
    $review = $sections -join "`n`n"
}

$sw.Stop()
$elapsed = [int]$sw.Elapsed.TotalSeconds
Write-Host "[pr-review] done in ${elapsed}s" -ForegroundColor Cyan

# --- assemble comment ------------------------------------------------------
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$md = @"
## 🤖 Local LLM review — ``$Model``
> Automated first-pass by a self-hosted 14B model (Ollama). May be wrong or incomplete — for reference only. _(${elapsed}s, $stamp)_

$review
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $md, $utf8NoBom) }

if ($Post) {
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $md, $utf8NoBom)
    & gh @('pr', 'comment', $Pr) $(if ($Repo) { '--repo', $Repo }) '--body-file', $tmp
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Write-Host "[pr-review] posted comment to PR #$Pr" -ForegroundColor Green
} else {
    Write-Output $md
}
