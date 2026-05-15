# DwarfStar 4 Toolbar

A macOS menu bar app for monitoring your local **DwarfStar 4** (DS4/DeepSeek V4 Flash) inference server.

Built with **pi + DwarfStar 4** on a 512GB Mac Studio M3 Ultra with 1M context.

## Features

-   **Live server status** — green icon when `ds4-server` is running, gray when offline
-   **Model info** — model name and context window size
-   **Performance metrics** — prefill t/s and generation t/s (parsed from server logs)
-   **Auto-refresh** — polls `/v1/models` every 15 seconds
-   **Configurable endpoint** — works with custom server URLs

## Requirements

-   macOS 13+
-   [DwarfStar 4](https://github.com/antirez/ds4) running locally

## Installation

### Option 1: Pre-built binary

```bash
# Build it
cd ~/Projects/ds4-toolbar
swift build -c release

# Copy to Applications
cp .build/release/ds4toolbar /Applications/DS4ToolBar.app/Contents/MacOS/ds4toolbar
```

### Option 2: Run from source

```bash
cd ~/Projects/ds4-toolbar
swift run
```

### Auto-start on login

Add the compiled binary to your Login Items in **System Settings → General → Login Items**.

## Usage

1. Start your ds4-server:
   ```bash
   ds4-server -m ds4flash.gguf --ctx 1000000
   ```

2. For live performance stats (tokens/sec), pipe stderr to a log file:
   ```bash
   ds4-server -m ds4flash.gguf --ctx 1000000 2>/tmp/ds4-server.log &
   ```

3. Launch DS4ToolBar. The menu bar icon turns green when the server is detected.

4. Click the icon to see:
   - Server status (online/offline)
   - Model name and context window
   - Prefill and generation tokens/sec (from last inference)
   - KV cache usage
   - Time since last check

## Performance

Runs with negligible overhead — just a lightweight HTTP poll every 15 seconds.
