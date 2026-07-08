# LocalModelsBar

A tiny native macOS menu bar utility that shows **every local LLM you have**, in one place: [llama.cpp](https://github.com/ggml-org/llama.cpp) GGUF models, [Ollama](https://ollama.com) models, and your Hugging Face cache.

No Python runtime, no Electron, no third-party menu bar framework (no SwiftBar/xbar/rumps) — just AppKit and Swift Package Manager, compiled to a single binary.

## Why

If you juggle local model runners you end up with model weights scattered across a couple of directories and no single view of what's actually on disk, what's running, and how much space it's all eating. LocalModelsBar answers "what do I have?" without you needing to remember three different CLI incantations.

## What it shows

- **Local (lcp)** — GGUF files in your llama.cpp models directory, with live llama-server running/stopped status. Split GGUF files (`model-00001-of-00006.gguf` etc.) are automatically grouped and shown as one logical model with the combined size.
- **Ollama** — models pulled via `ollama pull`, read live from Ollama's local HTTP API (`:11434`). Cloud-proxied models (`model:cloud`) are marked separately since they don't consume local disk.
- **Hugging Face cache** — repos in `~/.cache/huggingface/hub`, sized on disk.

Each section header shows a running count and total size. Click any entry to reveal it in Finder (or copy its name to the clipboard, for Ollama models that have no single file on disk).

## Requirements

- macOS 13+
- Xcode Command Line Tools (for the Swift toolchain — `xcode-select --install` if you don't have it)

## Build & run

```bash
git clone https://github.com/sriinnu/local-models-bar.git
cd local-models-bar
./build.sh
open LocalModelsBar.app
```

It's a menu bar–only app (no Dock icon). Click the chip icon in your menu bar to see your models. Add it to **System Settings → General → Login Items** if you want it to start automatically.

## Configuring paths

The defaults assume:

| What | Default path |
|---|---|
| llama.cpp models dir | `~/llama-cpp-setup/models` |
| llama-server pidfile | `~/.cache/lcp/llama-server.pid` |
| Hugging Face cache | `~/.cache/huggingface/hub` |
| Ollama API host | `http://127.0.0.1:11434` |

If your setup differs, override any of them with environment variables before launching the binary directly (env vars set via `open` on a `.app` don't reliably reach the process — export them and run the binary inside the bundle instead):

```bash
LOCALMODELSBAR_LCP_DIR="$HOME/my-models" \
LOCALMODELSBAR_LCP_PIDFILE="$HOME/.cache/my-server.pid" \
LOCALMODELSBAR_HF_CACHE_DIR="$HOME/.cache/huggingface/hub" \
LOCALMODELSBAR_OLLAMA_HOST="http://127.0.0.1:11434" \
./LocalModelsBar.app/Contents/MacOS/LocalModelsBar &
```

Or just edit the defaults in `Sources/LocalModelsBar/main.swift` and rebuild — it's one line each.

## How it works

- Everything is read fresh each time you open the menu (`NSMenuDelegate.menuWillOpen`) — no background polling, no daemon, negligible idle cost.
- The "is llama-server running" check reads a pidfile and confirms the process is alive with `kill(pid, 0)` — no assumptions beyond that.
- Ollama data comes from a local HTTP request to Ollama's own `/api/tags` endpoint with a short timeout, so a stopped Ollama just shows "not reachable" instead of hanging the menu.

## License

MIT — see [LICENSE](LICENSE).
