# Cline-Olama-VS-code-intergration-automated-installed-script-
# Cline + Ollama Local AI Coding Setup

A single, self-elevating PowerShell script (`Setup-ClineLocalAI.ps1`) that sets up a fully local AI coding environment on Windows 10/11:

- **Ollama** running **Qwen3.6 27B (Q5_K_M)** on your NVIDIA GPU, with partial offload to system RAM
- **VS Code** + the **Cline** extension (`saoudrizwan.claude-dev`)
- **Cline CLI** (terminal agent), **Cline Desktop** (beta) and the **Cline SDK** (sample project)
- Supporting tools: Git, Node.js 22+, NVIDIA driver check

It is interactive, idempotent (safe to re-run; finished steps are skipped), and logs everything to a file.

> **Status:** written against the current Cline and Ollama docs but not yet run end-to-end on a real machine. Try it on a test machine first and check the log if anything fails.

---

## Requirements

| Item | Minimum | Recommended |
|---|---|---|
| OS | Windows 10 | Windows 11 |
| PowerShell | 5.1 | 5.1 or 7 |
| GPU | Any (NVIDIA best supported) | NVIDIA with 12 GB+ VRAM |
| System RAM | 16 GB | 32 GB+ (needed when the model is larger than VRAM) |
| Free disk | model size + ~3 GB | ~25 GB for Q5_K_M |
| Internet | Required | - |
| winget | Required (the script offers to install App Installer if missing) | - |

Approximate model sizes: Q5_K_M ~19.7 GB, official `qwen3.6:27b` (Q4_K_M) ~17 GB.

---

## Quick start

1. Save `Setup-ClineLocalAI.ps1` somewhere on disk.
2. Open PowerShell and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Setup-ClineLocalAI.ps1
   ```

3. Accept the UAC prompt. The script relaunches itself as administrator.
4. Choose **1 - Run full automatic install** and answer the hardware questions.
5. When it finishes, open VS Code, click the Cline icon, and enter the values the script printed (see [Configuring Cline in VS Code](#configuring-cline-in-vs-code)).

**Switches**

| Switch | Effect |
|---|---|
| `-Unattended` | Runs the full install with defaults (Q5_K_M, detected hardware) and no prompts. Needs an NVIDIA GPU that `nvidia-smi` can see. |
| `-NoElevate` | Skips self-elevation (some installs may fail). |

> Run it as the same Windows user you use day to day. If UAC asks for a *different* admin account, per-user installs (VS Code extension, npm globals, Ollama) land in that account's profile.

---

## Menu

| # | Option | What it does |
|---|---|---|
| 1 | Full automatic install | Hardware profile, requirements check, installs Git / Node / VS Code / Ollama, pulls and tunes the model, installs the Cline extension, CLI, Desktop and SDK, configures Cline, runs a test, prints a summary table. |
| 2 | Install/repair components | Individually: NVIDIA driver check, Git, Node.js 22+, VS Code 1.84+, Ollama, Cline CLI, or all. |
| 3 | Pull model | Choose Q5_K_M (bartowski), the official `qwen3.6:27b`, or enter your own model name or `ollama pull/run` command. Then builds a tuned Modelfile. |
| 4 | Install Cline extension | `code --install-extension saoudrizwan.claude-dev` (checks first, offers update). |
| 5 | Configure Cline for Ollama | Base URL, model name, context size. Configures the CLI automatically; prints and copies values for the VS Code extension and Desktop. |
| 6 | Store an API key | Anthropic, OpenAI or OpenRouter. Encrypted, never plain text. |
| 7 | `.clinerules`, auto-approve, spend limit | Writes rules for local models, prints recommended auto-approve defaults, shows spend-limit reminders. |
| 8 | Test connection | `ollama list`, a real test prompt, tokens/second, GPU/CPU split (`ollama ps`), GPU memory. |
| 9 | Install Cline Desktop, SDK and CLI | See [Cline products](#cline-products-installed). |
| 10 | Uninstall / cleanup | Asks before each removal. |
| H | Hardware and optimization profile | Re-enter GPU, RAM, offload, context size, KV cache, keep-alive. |
| 0 | Exit | |

---

## Hardware and optimization options

On first use the script detects your hardware and asks you to **confirm or edit** each value.

| Setting | Options | Notes |
|---|---|---|
| GPU name / VRAM | Detected via `nvidia-smi`, or typed in | With several GPUs, the first is used for planning. |
| System RAM | Detected, editable | |
| Free disk | Measured on the Ollama model drive, editable | If low, the script offers to move models to another drive (`OLLAMA_MODELS`). |
| Offload to RAM | yes / no | **Yes** lets layers that don't fit in VRAM run on the CPU. **No** requests everything on the GPU and warns if it won't fit. |
| Context size | `auto`, `4k`, `8k`, `16k`, `32k`, `64k`, `128k`, or a number | `auto` picks the largest of 32k/16k/8k/4k that fits your leftover memory. It is capped at 32k to keep generation speed reasonable. Cline sends a large system prompt, so **16k or more is strongly recommended**. |
| KV cache | `q8_0` (default) or `f16` | `q8_0` roughly halves KV-cache memory. Requires flash attention, which the script enables. |
| Keep-alive | e.g. `10m`, `30m`, `2h`, `-1` | How long the model stays loaded after the last request. |

### What gets generated

For each model the script writes a Modelfile (no BOM) to `%LOCALAPPDATA%\ClineLocalSetup\modelfiles\` and runs `ollama create`:

```
FROM hf.co/bartowski/Qwen_Qwen3.6-27B-GGUF:Q5_K_M
PARAMETER num_ctx 32768
PARAMETER num_gpu 40
PARAMETER temperature 0.6
PARAMETER top_p 0.95
PARAMETER top_k 20
```

The tuned model names are `qwen3.6-27b-q5km-cline` and `qwen3.6-27b-q4km-cline` (custom models get a derived `...-cline` name). The numbers above are examples; the script computes them from your hardware.

**Keep-alive is not a Modelfile setting in Ollama.** The script sets it through the `OLLAMA_KEEP_ALIVE` environment variable instead.

User-level environment variables set by the script (and removed by cleanup):

| Variable | Value |
|---|---|
| `OLLAMA_FLASH_ATTENTION` | `1` |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` (only if selected) |
| `OLLAMA_KEEP_ALIVE` | your keep-alive value |
| `OLLAMA_NUM_PARALLEL` | `1` |
| `OLLAMA_MAX_LOADED_MODELS` | `1` |
| `OLLAMA_MODELS` | only if you chose another model folder |

> The layer-offload and KV-cache numbers are **estimates** (the script reads the real layer count from Ollama when it can). Ollama makes the final decision when it loads the model. Run menu 8 and look at the `PROCESSOR` column of `ollama ps` to see the actual GPU/CPU split. Partial offload is noticeably slower than a model that fits entirely in VRAM.

---

## Model choices

| Choice | Reference | Size |
|---|---|---|
| Recommended | `hf.co/bartowski/Qwen_Qwen3.6-27B-GGUF:Q5_K_M` | ~19.7 GB |
| Smaller fallback | `qwen3.6:27b` (official, Q4_K_M) | ~17 GB |
| Your own | Paste a model name or something like `ollama pull llama3.1:8b` | varies |

For your own model, the script extracts the model reference and validates it. Arbitrary commands are never executed. Downloads use the Ollama API with progress display, retry up to 3 times, and resume automatically. If Ollama reports the model needs a newer version, the script offers to upgrade it via winget.

---

## Configuring Cline in VS Code

The Cline extension stores its provider settings inside VS Code, which a script can't write safely. Menu 5 prints (and saves to `%LOCALAPPDATA%\ClineLocalSetup\cline-ollama-settings.txt`) the values to enter:

1. Open the Cline sidebar, then the settings (gear) and **API Configuration**.
2. **API Provider:** Ollama
3. **Base URL:** `http://localhost:11434` (tick "Use custom base URL" if shown)
4. **Model:** the tuned model name (copied to your clipboard)
5. **Model Context Window:** the same number as `num_ctx`. Cline passes it to Ollama, so a mismatch silently overrides your Modelfile.

Alternative: provider **OpenAI Compatible**, Base URL `http://localhost:11434/v1`, API key `ollama` (any non-empty text), same model name.

The **Cline CLI** is configured automatically with `cline auth -p ollama -m <model> -b <url>`. Verify with `cline config`. You can also use `ollama launch cline --config`.

---

## Cline products installed

| Product | How | Notes |
|---|---|---|
| VS Code extension | `code --install-extension saoudrizwan.claude-dev` | Needs VS Code 1.84+. |
| Cline CLI ("Terminal") | `npm install -g cline` | Needs Node.js 22+. Run `cline`. |
| Cline Desktop (beta) | Latest `desktop-v*` Windows installer from the `cline/cline` GitHub releases, run with `/S` | Falls back to v0.0.49 if the lookup fails. The installer's signature is checked and its SHA256 logged. If it isn't validly signed, the script asks (default: no). Pick Ollama or a local endpoint in the app. |
| Cline SDK | `npm install @cline/sdk` in `%USERPROFILE%\cline-sdk-quickstart` | Needs Node.js 22+. Includes `agent.mjs` pointing at your local Ollama via the `openai-compatible` provider. Run with `npm start`. An existing `agent.mjs` is never overwritten. |

---

## API keys (optional)

Menu 6 supports Anthropic, OpenAI and OpenRouter.

- The key is read as a hidden `SecureString` and stored with Windows **DPAPI** (`ConvertFrom-SecureString`) in `%LOCALAPPDATA%\ClineLocalSetup\secrets\`. Only your user account on this PC can decrypt it. The file's ACL is also restricted to you.
- It is never written as plain text, never logged, and not stored in environment variables.
- Optionally apply it to the Cline CLI (`cline auth -k ...`). This briefly exposes the key in the process command line, so the script asks first.
- Optionally copy it to the clipboard for pasting into the extension. The clipboard is cleared when you press Enter.
- **Set a spend limit** in your provider's console before using agents with a cloud key. The script reminds you and shows a banner while a key is stored.

---

## `.clinerules` and auto-approve (menu 7)

- Writes a **managed block** into `.clinerules` in the project folder you choose, with rules suited to a local model (small steps, read before editing, ask before destructive actions, PowerShell syntax, no secrets). Re-running replaces only the block between the `cline-local-setup` markers. If `.clinerules` is a folder, it writes `00-local-model.md` inside it.
- Prints recommended auto-approve defaults (read files on; edits, commands, browser and MCP off at first; max requests 20 or fewer) and saves them to `auto-approve-recommendations.txt`. Cline stores auto-approve in its own settings, so you set these once in the UI.

---

## Files and logs

All under `%LOCALAPPDATA%\ClineLocalSetup\`:

| Path | Purpose |
|---|---|
| `logs\setup-YYYYMMDD.log` | Timestamped log of every step, warning and error |
| `config.json` | Saved hardware profile and choices |
| `modelfiles\` | Generated Modelfiles |
| `secrets\` | DPAPI-encrypted API keys |
| `cline-ollama-settings.txt` | Values to enter in Cline |
| `auto-approve-recommendations.txt` | Recommended auto-approve settings |

---

## Troubleshooting

| Problem | Try |
|---|---|
| `nvidia-smi` not found | Install the NVIDIA driver, reboot, re-run. Menu 2, then 1 can open the download page. |
| Model fails to load or is extremely slow | Lower the context size, enable RAM offload, or use the Q4_K_M fallback. Check `ollama ps`. |
| Pull says a newer Ollama is required | Accept the upgrade prompt, or run `winget upgrade --id Ollama.Ollama`. |
| `code`, `node` or `cline` not found right after install | Open a new terminal (PATH refresh). The script refreshes its own PATH, but other windows don't update. |
| Cline ignores your context size | Set **Model Context Window** in Cline to the same value as `num_ctx`. |
| First test prompt takes minutes | Normal for the first load of a 27B model. Later requests reuse the loaded model until keep-alive expires. |
| Cline Desktop silent install not detected | Accept the offer to run the installer interactively. |
| winget missing | Install "App Installer" from the Microsoft Store, or accept the script's offer. |

---

## Uninstall

Menu 10 asks before each item: tuned and base models, the VS Code extension, Cline CLI, Cline Desktop, the SDK sample folder, environment variables set by the script, optionally Ollama / VS Code / Node.js / Git via winget (default no), and finally the script's own data folder.

---

## Known limitations

- Not yet tested on a live Windows machine.
- The Cline VS Code extension and Desktop settings can't be written by the script; only the CLI is configured automatically.
- The silent-install flag for Cline Desktop and the winget ID `Nvidia.NVIDIAApp` are unverified.
- Offload and context calculations are heuristics.
- Cline Desktop is a beta product and changes frequently.

## References

- Cline guide: https://www.deployhq.com/guides/cline
- Cline extension: https://marketplace.visualstudio.com/items?itemName=saoudrizwan.claude-dev
- Cline SDK: https://docs.cline.bot/sdk/overview
- Cline Desktop: https://cline.bot/desktop
- Cline CLI: https://docs.cline.bot/cline-cli
- Ollama + Cline CLI: https://docs.ollama.com/integrations/cline-cli
