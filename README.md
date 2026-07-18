# KEIVO

KEIVO is a private local AI workspace with streaming answers, saved conversations, a glass sidebar, and light/dark themes. It runs entirely with Ollama on your computer.

## Start

1. Install [Ollama for Windows](https://ollama.com/download/windows) once if it is not already installed.
2. Double-click **`START-KEIVO.bat`**.
3. KEIVO starts Ollama when needed, prepares its private Python environment, and checks for `qwen3:8b`.
4. On the first launch, a small progress window remains visible while the local model downloads. The browser opens automatically when ready.

No command or Python window remains visible. Double-clicking the launcher again opens the already-running workspace instead of creating a duplicate.

The first model download is several gigabytes and can take a while. Later launches are immediate because the model remains in Ollama.

## Stop

Double-click **`STOP-KEIVO.bat`**. It verifies and stops only the KEIVO service. Ollama is deliberately left running so other local applications are not interrupted.

## Optional local configuration

The `.env` file contains server-side settings only:

```dotenv
OLLAMA_BASE_URL=http://127.0.0.1:11434
OLLAMA_MODEL=qwen3:8b
```

Change `OLLAMA_MODEL` to another installed Ollama model if desired. `OLLAMA_BASE_URL` can point to another trusted Ollama endpoint. Restart KEIVO after changing either setting.

## Requirements

- Windows 10 or 11
- [Ollama](https://ollama.com/download/windows)
- Python 3.11 or newer
- Internet access for the first dependency and model download
- Roughly 6 GB of free disk space for the default model and setup

If Ollama or Python is missing, KEIVO shows a short action message instead of leaving a terminal window open.

Runtime logs and the verified process record are stored under `%LOCALAPPDATA%\KEIVO`. No chat or local model traffic is sent to a hosted AI API by the launcher.

## Deploy with GitHub Actions to Azure Free

The included workflow defaults to the Free-compatible profile: `Standard_B2ats_v2`, `qwen3:0.6b`, CPU-only Ollama, two 64 GB P6 disks, Standard ACR, and a 20-question hourly capacity guard. It rejects accidental GPU settings. Open [`deploy/azure/automation/README.md`](deploy/azure/automation/README.md) and complete the one-time OIDC bootstrap, then add the four printed/protected values to the GitHub `production` Environment secrets. Run **Actions → Deploy KEIVO to Azure → provision**; the workflow builds, provisions, downloads the model, performs a real streamed-answer test, enables HTTPS, and prints the public URL.

The free VM has only 1 GB RAM, so this cloud profile is slower and less capable than the local `qwen3:8b` setup. Azure's allowances apply only to eligible accounts and within current monthly/first-12-month limits. The required static public IPv4 address has a small separate charge; check Cost Management after deployment.
