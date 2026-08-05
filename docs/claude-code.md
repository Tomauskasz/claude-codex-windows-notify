# Install for Claude Code

Claude Code is a fully supported target, not an add-on. It reaches the same renderer as Codex, through a wider set of lifecycle events.

Claude Code has no plugin hook mechanism, so its hooks live in your user settings file instead of a plugin manifest. That is the only difference in how the two agents are wired.

## Requirements

- The same Windows and terminal requirements listed in the project README
- Claude Code 2.1.198 or newer for the supported lifecycle event types
- A local clone of this repository at a stable absolute path

## Configure

Open `%USERPROFILE%\.claude\settings.json` and merge the following `hooks` object into the existing top-level object. Replace every `C:\\path\\to\\claude-codex-windows-notify` prefix with the absolute path to your clone. Keep existing hook event entries; Claude Code merges hook groups, but duplicate entries produce duplicate popups.

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
            "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\claude-codex-windows-notify\\plugins\\claude-codex-windows-notify\\scripts\\notify.ps1", "-Event", "ApprovalRequested", "-ProductName", "Claude"],
            "timeout": 5
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "elicitation_dialog",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\claude-codex-windows-notify\\plugins\\claude-codex-windows-notify\\scripts\\notify.ps1", "-Event", "AttentionRequested", "-ProductName", "Claude"],
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
            "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\claude-codex-windows-notify\\plugins\\claude-codex-windows-notify\\scripts\\notify.ps1", "-Event", "TurnComplete", "-ProductName", "Claude"],
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
            "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\claude-codex-windows-notify\\plugins\\claude-codex-windows-notify\\scripts\\notify.ps1", "-Event", "TurnFailed", "-ProductName", "Claude"],
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

These hooks notify for:

- main-session permission requests and `AskUserQuestion` prompts
- MCP elicitation dialogs
- main-turn completion
- API failures such as rate limits or authentication errors

Subagent completion and subagent permission prompts are ignored. Do not register `SubagentStop`.

That is a wider event set than the Codex plugin registers, because Claude Code exposes more lifecycle events.

The popup's second line shows the Claude session name (the one `/rename` sets, or the derived default) read from
`%USERPROFILE%\.claude\sessions`. Sessions with no name record fall back to the session ID.

Clicking the popup focuses the originating session. In WezTerm this activates the exact pane. For a Claude session started
in an integrated terminal inside VS Code or Cursor, it raises that editor window instead; the editor exposes no way to
focus one terminal tab, so finding the terminal within the window is left to you.

The renderer detaches immediately, so the five-second hook timeout does not limit how long the popup remains visible.

## Verify

Run `claude doctor` to validate the settings file, then start a Claude session from WezTerm and complete a turn. The popup should show `Claude finished`; clicking it should reactivate the originating pane.

Claude Code detects settings changes, but restart an already-running session if its hook list does not update.
