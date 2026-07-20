# local-llm-server

A local LLM code assistant plus an OpenAI-compatible API server for Windows, built on
[Ollama](https://ollama.com). Runs 14B-class coding models fully on a ~12 GB GPU
(e.g. RTX 5070) for **code review, test generation, and summarization** — private,
offline, and free.

## What's included

| File | Purpose |
|------|---------|
| `llm-tools.ps1` | PowerShell helpers: `review-diff`, `gen-test`, `summarize-code`, `deep-review` |
| `pr-review.ps1` | Review a GitHub PR with a local model and post the result as a PR comment |
| `ollama-serve.vbs` | Starts the Ollama API server headless at login, bound to the LAN |
| `install-services.ps1` | Installs Ollama + the PR-review runner as headless Windows services (no login) |

## Models

Two 16K-context variants, created from Ollama base models:

- **`qwen-review`** ← `qwen2.5-coder:14b` — review / tests / summaries (primary)
- **`deepseek-review`** ← `deepseek-r1:14b` — deeper chain-of-thought bug hunting

On a 12 GB card a 14B model at Q4 uses ~9 GB, leaving room for a 16K KV cache.

## Prerequisites

- Windows 10/11, NVIDIA GPU with ~12 GB VRAM
- [Ollama](https://ollama.com/download) installed
- Recent build for Blackwell (RTX 50-series) GPUs: CUDA 12.8+

## Setup

### 1. Pull base models and create the 16K variants

```powershell
ollama pull qwen2.5-coder:14b
ollama pull deepseek-r1:14b

# Default context is 4K — too short for reviewing files/diffs. Bump to 16K:
"FROM qwen2.5-coder:14b`nPARAMETER num_ctx 16384" | Set-Content Modelfile-review
"FROM deepseek-r1:14b`nPARAMETER num_ctx 16384"   | Set-Content Modelfile-deepreview
ollama create qwen-review     -f Modelfile-review
ollama create deepseek-review -f Modelfile-deepreview
```

### 2. Tune VRAM so 16K context fits in 12 GB

```powershell
setx OLLAMA_KV_CACHE_TYPE q8_0
setx OLLAMA_FLASH_ATTENTION 1
```

### 3. Install the helper commands

```powershell
Copy-Item llm-tools.ps1 "$HOME\Documents\WindowsPowerShell\"
Add-Content $PROFILE '. "$HOME\Documents\WindowsPowerShell\llm-tools.ps1"'
```

Open a new terminal — `review-diff`, `gen-test`, `summarize-code`, `deep-review` are now available.

### 4. Auto-start the API server at login

Some machines' Ollama tray app does not spawn the server. This launcher starts it
directly, hidden, at every login:

```powershell
Copy-Item ollama-serve.vbs ([Environment]::GetFolderPath('Startup'))
```

The VBS sets `OLLAMA_HOST=0.0.0.0:11434` so the API is reachable on your LAN.

### 5. Headless auto PR review (Windows services)

To auto-review every PR *without staying logged in*, run both Ollama and the GitHub
Actions runner as Windows services. `install-services.ps1` installs both:

- **`OllamaServe`** — Ollama wrapped by [nssm](https://nssm.cc) (LocalSystem, runs on
  the GPU, `OLLAMA_MODELS` pinned to your models dir).
- **`actions.runner.*`** — the self-hosted runner, via `config.cmd --runasservice`
  (runs as `NT AUTHORITY\NETWORK SERVICE`).

Prereqs: unpack the [Actions runner](https://github.com/actions/runner/releases) into
`D:\actions-runner`, drop `nssm.exe` into `D:\ollama-service`, and have `gh`
authenticated. Then, in an **elevated** PowerShell:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; & .\install-services.ps1
```

The script also sets the machine `ExecutionPolicy` to `RemoteSigned` (so the service
can run scripts) and grants `NETWORK SERVICE` read access to this repo (so it can run
`pr-review.ps1`). Both services auto-start at boot — this **replaces** the login
launcher in step 4. Edit the repo URL / paths near the top of the script for your box.

Manage them:

```powershell
Get-Service OllamaServe, actions.runner.*   # status (Restart-Service needs admin)
```

## Usage

### PowerShell helpers

```powershell
review-diff                     # review uncommitted git changes
review-diff main                # review against a ref
gen-test .\src\foo.py pytest    # generate unit tests
summarize-code .\src\foo.py     # explain / summarize a file
deep-review                     # slower, deeper reasoning review (DeepSeek-R1)
```

### GitHub PR review

`pr-review.ps1` fetches a PR's diff via `gh`, reviews it with a local model, and
either prints the result (dry-run, default) or posts it as a PR comment. Small
diffs go in one shot; large ones are reviewed per file to fit the 16K context.

```powershell
.\pr-review.ps1 -Pr 78 -Repo owner/name                    # print review (dry-run)
.\pr-review.ps1 -Pr 78 -Repo owner/name -Model deepseek-review
.\pr-review.ps1 -Pr 78 -Repo owner/name -Post              # post as a PR comment
```

Needs `gh` on PATH and Ollama reachable. This is what the optional self-hosted
GitHub Actions runner invokes to review every PR automatically.

### API (OpenAI-compatible)

Server runs at `http://localhost:11434`.

```powershell
$body = @{ model="qwen-review"; messages=@(@{ role="user"; content="Write a prime check in Python" }) } | ConvertTo-Json
$resp = Invoke-WebRequest http://localhost:11434/v1/chat/completions -Method Post -Body $body -ContentType "application/json"
$txt  = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
($txt | ConvertFrom-Json).choices[0].message.content
```

> On Windows PowerShell 5.1, `Invoke-RestMethod` mis-decodes non-ASCII responses.
> Reading `RawContentStream` as UTF-8 (above) fixes the display. Real clients
> (Python/JS) receive correct UTF-8 regardless.

Python (OpenAI SDK):

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")  # api_key ignored
r = client.chat.completions.create(
    model="qwen-review",
    messages=[{"role": "user", "content": "Review this function..."}],
)
print(r.choices[0].message.content)
```

### LAN access from other machines

Open the firewall port once, in an **elevated** PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Ollama LAN (11434)" -Direction Inbound -Protocol TCP -LocalPort 11434 -Action Allow -Profile Private
```

Then other devices call `http://<YOUR-MACHINE-IP>:11434/v1`.

> ⚠️ Ollama has **no authentication**. Only expose it on trusted networks.

## Notes

- 12 GB VRAM holds one 14B model at a time; `deep-review` swaps models (~15 s).
- Helper prompts request **Vietnamese** responses — edit `llm-tools.ps1` to change.
- The server auto-unloads idle models after ~5 min, freeing the GPU.
