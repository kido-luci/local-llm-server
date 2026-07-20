# LLM code tools — local Ollama models (qwen-review / deepseek-review)
# review-diff [ref]   : review git diff (default: HEAD = staged + unstaged)
# gen-test <file> [fw]: generate unit tests for a file
# summarize-code <file>: explain/summarize a source file
# deep-review [ref]   : slower reasoning review (DeepSeek-R1) for subtle bugs

# Ensure ollama is reachable even in terminals opened before Ollama was installed.
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    $env:Path += ";$env:LOCALAPPDATA\Programs\Ollama"
}

function review-diff {
    param([string]$Ref)
    $diff = if ($Ref) { git diff $Ref } else { git diff HEAD }
    if (-not $diff) { Write-Host "No changes to review."; return }
    $diff | ollama run qwen-review "You are a senior code reviewer. Review this git diff for bugs, edge cases, missing error handling, and style issues. Be specific, cite file and line, and keep it concise. Respond in Vietnamese. The diff:"
}

function gen-test {
    param(
        [Parameter(Mandatory)][string]$File,
        [string]$Framework
    )
    $fw = if ($Framework) { "using $Framework" } else { "using the most appropriate framework for the language" }
    Get-Content -Raw $File | ollama run qwen-review "Write thorough unit tests $fw for the following code. Cover edge cases and error paths. Output only the test code with brief comments. The code:"
}

function summarize-code {
    param([Parameter(Mandatory)][string]$File)
    Get-Content -Raw $File | ollama run qwen-review "Summarize this code: purpose, overall structure, key functions, data flow, and any notable issues or TODOs. Respond in Vietnamese. The code:"
}

function deep-review {
    param([string]$Ref)
    $diff = if ($Ref) { git diff $Ref } else { git diff HEAD }
    if (-not $diff) { Write-Host "No changes to review."; return }
    $diff | ollama run deepseek-review "Carefully analyze this git diff for subtle logic bugs, race conditions, off-by-one errors, and broken invariants. Think step by step, then give a final verdict. Respond in Vietnamese. The diff:"
}
