# local-llm-server

A local LLM code assistant plus an OpenAI-compatible API server for Windows, built on
[Ollama](https://ollama.com). Runs 14B-class coding models fully on a ~12 GB GPU
(e.g. RTX 5070) for **code review, test generation, and summarization** — private,
offline, and free.

## What's included

| File | Purpose |
|------|---------|
| `llm-tools.ps1` | PowerShell helpers: `review-diff`, `gen-test`, `summarize-code`, `deep-review` |
| `ollama-serve.vbs` | Starts the Ollama API server headless at login, bound to the LAN |

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

## Usage

### PowerShell helpers

```powershell
review-diff                     # review uncommitted git changes
review-diff main                # review against a ref
gen-test .\src\foo.py pytest    # generate unit tests
summarize-code .\src\foo.py     # explain / summarize a file
deep-review                     # slower, deeper reasoning review (DeepSeek-R1)
```

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
