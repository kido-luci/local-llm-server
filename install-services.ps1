# install-services.ps1 — run ONCE in an ELEVATED PowerShell (Run as administrator).
# Installs Ollama + the GitHub Actions runner as Windows services so PR auto-review
# works headless (no login required). Idempotent-ish: safe to re-run.

$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'D:\ollama-service\install.log' -Force -ErrorAction SilentlyContinue | Out-Null

# --- must be elevated ------------------------------------------------------
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: run this in an ELEVATED PowerShell (Run as administrator)." -ForegroundColor Red; exit 1 }

# The runner service (NETWORK SERVICE) runs PS scripts; default machine policy is
# Restricted and blocks them. RemoteSigned allows local scripts (the CI wrapper +
# pr-review.ps1) while still blocking unsigned scripts downloaded from the internet.
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

$nssm       = 'D:\ollama-service\nssm.exe'
$ollamaExe  = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"   # C:\Users\Admin\...
$ollamaDir  = Split-Path $ollamaExe
$modelsDir  = "$env:USERPROFILE\.ollama\models"                # so LocalSystem finds YOUR models
$runnerDir  = 'D:\actions-runner'
$logDir     = 'D:\ollama-service'

# --- free the port / registration held by any interactive instances --------
Write-Host "`n[1/4] stopping interactive ollama + foreground runner (if any)..." -ForegroundColor Cyan
Get-Process ollama          -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process 'Runner.Listener' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2

# --- Ollama service (via NSSM, runs as LocalSystem) -------------------------
# Native tools (nssm/svc.cmd) write to stderr; under ErrorActionPreference=Stop that
# aborts the script in PS 5.1, so drop to Continue and verify by state at the end.
$ErrorActionPreference = 'Continue'
Write-Host "[2/4] installing Ollama service (OllamaServe)..." -ForegroundColor Cyan
if (Get-Service OllamaServe -ErrorAction SilentlyContinue) { & $nssm stop OllamaServe; & $nssm remove OllamaServe confirm; Start-Sleep 1 }
& $nssm install OllamaServe $ollamaExe serve
& $nssm set     OllamaServe AppDirectory $ollamaDir
& $nssm set     OllamaServe DisplayName  "Ollama API server"
& $nssm set     OllamaServe Description  "Local Ollama LLM API (headless, for PR auto-review)"
& $nssm set     OllamaServe Start        SERVICE_AUTO_START
& $nssm set     OllamaServe AppEnvironmentExtra "OLLAMA_HOST=0.0.0.0:11434" "OLLAMA_MODELS=$modelsDir" "OLLAMA_KV_CACHE_TYPE=q8_0" "OLLAMA_FLASH_ATTENTION=1"
& $nssm set     OllamaServe AppStdout "$logDir\ollama.log"
& $nssm set     OllamaServe AppStderr "$logDir\ollama.log"
& $nssm start   OllamaServe

# --- GitHub Actions runner service (config --runasservice) ------------------
# This runner build has no svc.cmd; the service is installed by re-running config
# with --runasservice (installs as NT AUTHORITY\NETWORK SERVICE and starts it).
# Grant NETWORK SERVICE read+execute on the tools repo so it can run pr-review.ps1.
Write-Host "[3/4] installing runner service (config --runasservice)..." -ForegroundColor Cyan
icacls 'D:\dev\local-llm-server' /grant '*S-1-5-20:(OI)(CI)RX' /T /C | Out-Null
Set-Location $runnerDir
[Environment]::CurrentDirectory = $runnerDir
# Runner is already configured (foreground mode); remove that, then re-add as a service.
# Both tokens come from gh (elevated runs as same user -> keyring auth works).
$removeToken = (gh api -X POST repos/kido-luci/watch-your-ai-code/actions/runners/remove-token -q .token)
if ($removeToken) { & "$runnerDir\config.cmd" remove --token $removeToken }
$regToken = (gh api -X POST repos/kido-luci/watch-your-ai-code/actions/runners/registration-token -q .token)
if (-not $regToken) {
    Write-Host "ERROR: could not fetch runner registration token via gh" -ForegroundColor Red
} else {
    & "$runnerDir\config.cmd" --url https://github.com/kido-luci/watch-your-ai-code --token $regToken --runasservice --labels self-hosted,windows --name $env:COMPUTERNAME --unattended
}

# --- status ----------------------------------------------------------------
Write-Host "`n[4/4] status:" -ForegroundColor Cyan
Start-Sleep 3
Get-Service | Where-Object { $_.Name -match 'OllamaServe|actions\.runner' } | Select-Object Name,Status,StartType | Format-Table -Auto
try {
    $r = Invoke-WebRequest 'http://localhost:11434/api/tags' -UseBasicParsing -TimeoutSec 10
    Write-Host "Ollama API: HTTP $($r.StatusCode) OK" -ForegroundColor Green
} catch { Write-Host "Ollama API not answering yet: $($_.Exception.Message)" -ForegroundColor Yellow }
Write-Host "`nDone. Both services are set to auto-start at boot (no login needed)." -ForegroundColor Green
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
