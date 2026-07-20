' Auto-start the GitHub Actions self-hosted runner (headless) at login, hidden window.
' Pairs with ollama-serve.vbs: both come up in the same user session so the runner
' can reach Ollama on localhost:11434. Copy this into the Startup folder to enable.
' Adjust the path below if the runner was unpacked somewhere other than D:\actions-runner.
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "D:\actions-runner"
sh.Run """D:\actions-runner\run.cmd""", 0, False
