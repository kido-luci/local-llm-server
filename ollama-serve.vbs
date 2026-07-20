' Auto-start the Ollama API server (headless) at login, hidden window.
' The tray app on this machine does not spawn the server, so we start it directly.
' Env vars are set explicitly so LAN binding works regardless of how this is launched.
Set sh = CreateObject("WScript.Shell")
Set env = sh.Environment("Process")
env("OLLAMA_HOST") = "0.0.0.0:11434"
env("OLLAMA_KV_CACHE_TYPE") = "q8_0"
env("OLLAMA_FLASH_ATTENTION") = "1"
sh.Run """" & sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Programs\Ollama\ollama.exe"" serve", 0, False
