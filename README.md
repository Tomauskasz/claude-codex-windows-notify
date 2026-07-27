# Codex WezTerm Notify

Native Windows notifications for Codex sessions running in WezTerm.

When Codex finishes a turn or needs approval, the plugin shows a compact popup with sound, session and working-directory context, and a response preview. Click the popup to return to the exact WezTerm pane that produced it.

## Features

- Completion and approval-request notifications from Codex lifecycle hooks
- Final-response preview using Codex's supported `last_assistant_message` field
- Distinct sound and color for completion versus approval
- Popup on the originating WezTerm window's monitor
- Click-to-activate the originating pane and Windows window
- Twenty-second timeout that pauses while hovered
- No PowerShell modules or other runtime dependencies

## Requirements

- Windows 10 or 11
- Native Windows WezTerm with `wezterm cli list`, `list-clients`, and `activate-pane`
- Windows PowerShell 5.1 in Full Language mode
- Codex CLI with plugin and lifecycle-hook support

Codex must run inside native Windows WezTerm. WSL, SSH domains, Windows Terminal, and other terminal emulators are not supported.

### Why WezTerm only?

The popup renderer itself is ordinary Windows UI. The hard part is returning to the exact terminal pane that raised the notification. WezTerm exposes both a stable `WEZTERM_PANE` identity and a supported `activate-pane` API. Windows Terminal and Alacritty cannot currently map hook context back to an existing exact pane through a supported public API; kitty has suitable remote control but no native Windows build.

The project will add another terminal only when that full click-to-return contract can be verified. See [the terminal support research](research/terminal-support.md) for the primary-source compatibility matrix.

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

The hook synchronously validates Codex's JSON payload and captures `WEZTERM_PANE`, the WezTerm executable, and mux socket. It then starts a detached PowerShell worker with a bounded notification payload so the Codex hook returns immediately.

The worker renders a WinForms popup. On click, it uses WezTerm's JSON CLI to activate the pane, resolves the owning GUI process, and focuses the matching native window. Ambiguous window matches fail closed and produce `%TEMP%\codex-wezterm-notify.log` plus an error dialog.

The implementation deliberately does not read Codex's internal SQLite database or transcript format.

## Privacy

The response preview, session ID, and working directory are rendered locally on screen. The plugin makes no network requests and uploads nothing. Anyone who can see your desktop may see notification content.

## Limitations

- Windows may refuse foreground activation in some focus-stealing-policy scenarios; the plugin reports that failure instead of silently claiming success.
- If the originating pane or window has closed, click-to-focus cannot succeed.
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

The tests cover both hook payloads, the documented completion-message field, invalid input, hook mismatches, Unicode-safe response limits, extended UNC paths, plugin-root command resolution, and forbidden internal Codex dependencies.

## License

MIT
