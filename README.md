# Codex WezTerm Notify

Native Windows notifications for Codex, with exact-pane return for WezTerm.

When Codex finishes a turn or needs approval, the plugin shows a compact popup with sound, session and working-directory context, and a response preview. It works from native Windows terminal emulators; in WezTerm, clicking the popup returns to the exact pane that produced it.

The same renderer can also be wired to Claude Code's lifecycle hooks. See [Use with Claude Code](docs/claude-code.md).

## Features

- Completion and approval-request notifications from Codex lifecycle hooks
- Final-response preview using Codex's supported `last_assistant_message` field
- UTF-8 previews for punctuation, non-Latin scripts, and emoji
- Distinct sound and color for completion versus approval
- Popup on the current monitor, or the originating WezTerm window's monitor
- WezTerm-only click-to-activate for the originating pane and Windows window
- Twenty-second timeout that pauses while hovered
- No PowerShell modules or other runtime dependencies

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 in Full Language mode
- Codex CLI with plugin and lifecycle-hook support
- Optional: native Windows WezTerm with `wezterm cli list`, `list-clients`, and `activate-pane` for exact-pane return

Codex must run natively on Windows with an interactive desktop. WSL and SSH-domain compatibility has not been verified.

### Terminal support

The notification is ordinary Windows UI, so it does not depend on terminal-native notification support. In Windows Terminal, Alacritty, and other native Windows terminals, it appears on the monitor containing the pointer; clicking it dismisses it.

When `WEZTERM_PANE` is available, the plugin additionally uses WezTerm's supported CLI to locate the originating monitor and return to the exact pane on click. Other terminals do not expose an equivalent verified exact-pane activation path, so the plugin does not guess. See [the terminal support research](research/terminal-support.md) for the primary-source compatibility matrix.

## Install

```powershell
codex plugin marketplace add Tomauskasz/codex-wezterm-notify
codex plugin add codex-wezterm-notify@codex-wezterm-notify
```

Start a new Codex session, review the two bundled hooks, and trust them when prompted. The plugin registers:

- `Stop` for completed turns
- `PermissionRequest` for approval prompts

No manual `config.toml` changes are required.

## Update

```powershell
codex plugin marketplace upgrade codex-wezterm-notify
```

Start a new Codex session after upgrading.

## Uninstall

```powershell
codex plugin remove codex-wezterm-notify@codex-wezterm-notify
codex plugin marketplace remove codex-wezterm-notify
```

## How it works

The hook decodes stdin as UTF-8, accepts an optional UTF-8 BOM, synchronously validates the JSON payload, and detects whether `WEZTERM_PANE` is available. For a WezTerm session it also captures the WezTerm executable and mux socket. It then starts a detached PowerShell worker with a bounded notification payload so the lifecycle hook returns immediately.

The worker renders a WinForms popup. In WezTerm, clicking it uses the JSON CLI to activate the pane, resolves the owning GUI process, and focuses the matching native window without restoring, resizing, moving, or unsnapping it. Ambiguous window matches fail closed and produce `%TEMP%\codex-wezterm-notify.log` plus an error dialog. In other terminals, clicking the popup only dismisses it.

The implementation deliberately does not read Codex's internal SQLite database or transcript format.

## Privacy

The response preview, session ID, and working directory are rendered locally on screen. The plugin makes no network requests and uploads nothing. Anyone who can see your desktop may see notification content.

## Limitations

- Windows may refuse foreground activation in some focus-stealing-policy scenarios; the plugin reports that failure instead of silently claiming success.
- If the originating pane or window has closed, click-to-focus cannot succeed.
- Exact-pane focus and originating-monitor placement are available only in WezTerm; other terminals use notify-only behavior.
- WSL and SSH-domain compatibility is not verified.
- Concurrent notifications can overlap.
- Popup rendering and focus behavior require an interactive Windows desktop and therefore are not exercised in GitHub Actions.

## Development

Run the deterministic hook and payload tests:

```powershell
.\tests\run-tests.ps1
```

Validate the plugin manifest with Codex's plugin-creator validator:

```powershell
python "$env:USERPROFILE\.codex\skills\.system\plugin-creator\scripts\validate_plugin.py" `
  ".\plugins\codex-wezterm-notify"
```

The tests cover WezTerm and generic-terminal payloads, Codex and Claude event contracts, raw UTF-8 input and exact Unicode preservation, the documented completion-message field, invalid input, hook mismatches, Unicode-safe response limits, extended UNC paths, plugin-root command resolution, and forbidden internal Codex dependencies.

## License

MIT
