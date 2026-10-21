# LLM Bar

Every model you can reach, in the macOS menu bar.

**Local:** [llama.cpp](https://github.com/ggml-org/llama.cpp) GGUF models with a working start/stop for `llama-server`, [Ollama](https://ollama.com) models, and your Hugging Face cache.
**Cloud:** every Claude Code provider lane from your `claude_config.zsh` (DeepSeek, Kimi, Qwen, GLM, SiliconFlow, OpenRouter, …) with a live health dot, latency, and a one-click launch into a terminal.

Native AppKit + SwiftUI, Swift Package Manager, Sparkle auto-updates. No Python runtime, no Electron, no SwiftBar/xbar.

> Formerly **SakshiBar** / LocalModelsBar. Renamed on 2026-10-21 when cloud lanes landed and "local" stopped being true. Old release URLs under `local-models-bar` redirect.

## What it shows

- **Local (lcp)** — GGUF files in your llama.cpp models directory, with live `llama-server` running/stopped status and a start button per model (memory-checked first). Split GGUFs are grouped as one model.
- **Ollama** — models from Ollama's local API (`:11434`), cloud-proxied ones marked. Launch/quit Ollama.app from the row.
- **Cloud lanes** — the launchers defined in your `claude_config.zsh`. For each: a status dot (green ok · yellow rate-limited · red auth/balance/down · orange no key · grey not probed), the lane's one-line description, last probe latency, and a terminal button that opens the lane in a new Ghostty window (Terminal.app fallback). A header shows when the lanes were last probed and lets you re-probe now.
- **Hugging Face cache** — repos in `~/.cache/huggingface/hub`, sized on disk.

Click a local entry to reveal it in Finder, or copy its name for Ollama models.

## Cloud lanes: how it works

The app never sources your shell config. It reads two things:

1. **Lane list** — parsed from the `lcp-help` heredoc in `~/.claude_config.zsh`. Rows under `CLOUD` sections whose name is also a defined function are lanes; helpers (`or-models`, `hf`, `llp-*`, …) are skipped. Edit the help text, the menu follows.
2. **Lane status** — `~/.cache/lcp/lane-status.json`, written by `scripts/lane-status.zsh` in the [claude-local](https://github.com/sriinnu/claude-local) repo. One 8-token `/v1/messages` request per distinct endpoint+key (keys from the macOS keychain, never printed), about 5 seconds for 23 lanes. Lanes sharing an endpoint share the result.

Run the probe yourself with `lane-status` in a shell that has the config sourced, or let a launchd agent do it daily:

```xml
<!-- ~/Library/LaunchAgents/com.sriinnu.lane-status.plist (07:30 daily + at login) -->
<key>ProgramArguments</key>
<array><string>/bin/zsh</string><string>/path/to/claude-local/scripts/lane-status.zsh</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>30</integer></dict>
<key>RunAtLoad</key><true/>
```

The probe posts a macOS notification when any lane's status changes between runs.

## Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- For cloud lanes: a `~/.claude_config.zsh` with an `lcp-help` block, and [Ghostty](https://ghostty.org) (or set `LLMBAR_TERMINAL=Terminal`)

## Build & run

```bash
git clone https://github.com/sriinnu/llm-bar.git
cd llm-bar
./bundle.sh            # build, ad-hoc sign, install to /Applications, launch
```

`./bundle.sh --signed` and `--release` cover Developer ID signing, notarization and the Sparkle appcast; see the header of `bundle.sh`.

Menu bar only, no Dock icon. Add it to **System Settings → General → Login Items** to start it at login.

## Configuring paths

| What | Env var | Default |
|---|---|---|
| llama.cpp models dir | `LLMBAR_LCP_DIR` | `~/llama-cpp-setup/models` |
| llama-server binary | `LLMBAR_LCP_SERVER` | `~/.local/bin/llama-server` |
| llama-server pidfile | `LLMBAR_LCP_PIDFILE` | `~/.cache/lcp/llama-server.pid` |
| Hugging Face cache | `LLMBAR_HF_CACHE_DIR` | `~/.cache/huggingface/hub` |
| Ollama API host | `LLMBAR_OLLAMA_HOST` | `http://127.0.0.1:11434` |
| Claude Code config (lane list) | `LLMBAR_CLAUDE_CONFIG` | `~/.claude_config.zsh` |
| Lane status cache | `LLMBAR_LANE_STATUS` | `~/.cache/lcp/lane-status.json` |
| Lane probe script | `LLMBAR_LANE_PROBE` | `scripts/lane-status.zsh` next to the resolved config |
| Terminal for lane launch | `LLMBAR_TERMINAL` | `Ghostty` |

Env vars set via `open` don't reach a `.app`; export them and run the binary inside the bundle, or edit the defaults in `Sources/LLMBar/Models.swift` / `Lanes.swift`.

## How it works

- Everything is read fresh each time the popover opens; while it is open a 1.5 s poll flips "starting…" to "running". No daemon.
- `llama-server` is started directly from Swift with the same flags, port and pidfile as the `lcp` shell function, so CLI and app stay interoperable.
- Lane launch runs `open -na Ghostty --args -e zsh -ic '<lane>; exec zsh -i'`, so your `.zshrc` sources the config and the keychain loader runs exactly as in a normal terminal.

## License

MIT — see [LICENSE](LICENSE).
