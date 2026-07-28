# Use with Claude Code

The bundled PowerShell renderer also accepts Claude Code hook payloads. This is a manual user-level integration; the Codex plugin commands do not install Claude hooks.

## Requirements

- The same Windows and terminal requirements listed in the project README
- Claude Code 2.1.198 or newer for background-agent notification types
- A local clone of this repository at a stable absolute path

## Configure

Open `%USERPROFILE%\.claude\settings.json` and merge the following `hooks` object into the existing top-level object. Replace every `C:\\path\\to\\codex-wezterm-notify` prefix with the absolute path to your clone. Keep existing hook event entries; Claude merges hook groups, but duplicate entries produce duplicate popups.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\codex-wezterm-notify\\plugins\\codex-wezterm-notify\\scripts\\notify.ps1", "-Event", "ApprovalRequested", "-ProductName", "Claude"],
            "timeout": 5
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "elicitation_dialog|agent_needs_input",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\codex-wezterm-notify\\plugins\\codex-wezterm-notify\\scripts\\notify.ps1", "-Event", "AttentionRequested", "-ProductName", "Claude"],
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "agent_completed",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\codex-wezterm-notify\\plugins\\codex-wezterm-notify\\scripts\\notify.ps1", "-Event", "BackgroundComplete", "-ProductName", "Claude"],
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\codex-wezterm-notify\\plugins\\codex-wezterm-notify\\scripts\\notify.ps1", "-Event", "TurnComplete", "-ProductName", "Claude"],
            "timeout": 5
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\codex-wezterm-notify\\plugins\\codex-wezterm-notify\\scripts\\notify.ps1", "-Event", "TurnFailed", "-ProductName", "Claude"],
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

These hooks notify for:

- permission requests and `AskUserQuestion` prompts
- MCP elicitation dialogs and background agents waiting for input
- main-turn completion and background-agent completion
- API failures such as rate limits or authentication errors

The renderer detaches immediately, so the five-second hook timeout does not limit how long the popup remains visible.

## Verify

Run `claude doctor` to validate the settings file, then start a Claude session from WezTerm and complete a turn. The popup should show `Claude finished`; clicking it should reactivate the originating pane.

Claude Code detects settings changes, but restart an already-running session if its hook list does not update.
