# Terminal support boundary

Research date: 2026-07-27. Sources are terminal-owned documentation and source code.

## Decision

Ship this release as **`codex-wezterm-notify`** with two explicit capability levels. Native Windows terminals receive the WinForms notification; WezTerm additionally gets originating-monitor placement and click-to-return to the exact pane.

Notify-only mode is supported behavior, not an exact-focus adapter. Its click action dismisses the popup, and the documentation must not imply that another terminal will be activated.

> **Superseded 2026-07-30.** Notify-only mode no longer dismisses on click. A third capability level now sits between the two above: outside WezTerm the notification focuses the *window* of the app hosting the terminal, resolved from validated process ancestry. This was prompted by terminals embedded in another app, where the notification was previously inert. It is still not exact focus, and the matrix column "Supported exact activation" below stands unchanged: no terminal other than WezTerm can be told to focus one specific pane or tab. The README is the source of truth for shipped behavior.

Keep the implementation as one Windows popup path with a conditional WezTerm capability. A terminal-adapter abstraction or repository rename would still be speculative: only WezTerm satisfies the full exact-pane contract.

## Matrix

| Terminal | Windows availability | Stable identity available to child | Supported exact activation | Terminal-native notification | Honest support now |
|---|---|---|---|---|---|
| **WezTerm** | Native Windows build | `WEZTERM_PANE`; mux socket can be preserved | `wezterm cli activate-pane --pane-id`; `list`/`list-clients` expose pane and GUI-client context | OSC 9 and OSC 777 toasts | **Yes: full exact-pane adapter** |
| **Windows Terminal** | Native Windows | `WT_SESSION` is a unique GUID per ConPTY connection | No public API maps `WT_SESSION` to a window/tab/pane. `wt -w` targets a window and `focus-tab` uses a mutable tab index; pane focus is relative | OSC 777 exists on current `main`, opt-in, and its internal click handler selects the source tab/window; not present in latest stable v1.24 source | **Yes: generic popup; no supported exact focus** |
| **Alacritty** | Native Windows | No Alacritty window/session ID is injected on Windows; Unix has `ALACRITTY_WINDOW_ID` | Windows has no IPC; Unix IPC has create/config/get-config, not focus-existing-window | No OSC 9/99/777 notification support; BEL can run a configured command | **Yes: generic popup; no supported exact focus** |
| **kitty** | No native Windows build (official binaries: Linux/macOS) | `KITTY_WINDOW_ID`; optional `KITTY_LISTEN_ON` | Remote-control `focus-window`/`focus-tab`, subject to explicit remote-control authorization | Rich OSC 99: title/body, sound, buttons, and default click-to-focus | **Strong future macOS/Linux adapter, outside this Windows plugin** |
| **Ghostty** | macOS/Linux; Windows explicitly future work | No Windows case | macOS has AppleScript automation; no cross-platform public exact-origin click adapter | Desktop notifications via OSC 9; release notes also identify OSC 777 as the recommended notification sequence | **No Windows adapter** |
| **tmux** | POSIX multiplexer; on Windows normally inside WSL/MSYS and an outer terminal | Stable `%pane` ID and `TMUX_PANE` | `select-pane -t` / `select-window -t` activate the logical tmux target only | No desktop notification service; can pass escape sequences to the outer terminal when configured | **Composable inner adapter only; it cannot focus the host OS window by itself** |

## Evidence

### WezTerm

WezTerm's CLI chooses the current pane from `WEZTERM_PANE`, and `activate-pane` accepts an explicit pane ID. `list` returns the mux's panes and `list-clients` returns GUI client PIDs plus each client's focused pane. That is enough stable, supported information to activate the logical pane and resolve the owning native Windows client; the plugin separately uses Win32 to foreground the resolved HWND.

- [`wezterm cli` pane selection rules](https://wezterm.org/cli/cli/index.html)
- [`wezterm cli activate-pane`](https://wezterm.org/cli/cli/activate-pane.html)
- [`wezterm cli list`](https://wezterm.org/cli/cli/list.html)
- [`wezterm cli list-clients`](https://wezterm.org/cli/cli/list-clients.html)
- [Windows installation](https://wezterm.org/installation/windows.html)
- [OSC 9 and OSC 777 notification handling](https://wezterm.org/config/lua/config/notification_handling.html)

This combination—not merely the ability to draw a notification—is why exact-pane return is available only in WezTerm.

### Windows Terminal

Windows Terminal injects a unique `WT_SESSION` GUID into every new ConPTY connection. That is a useful exact session identity, but its public CLI does not accept that identity. The supported CLI can target an existing window by numeric ID/name, focus a tab by current index, and move pane focus only by direction/order. There is no documented enumeration or `WT_SESSION`-to-window/tab/pane mapping.

- [`WT_SESSION` injection in `ConptyConnection.cpp`](https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalConnection/ConptyConnection.cpp#L61-L64)
- [`wt --window`, `focus-tab`, and `move-focus`](https://learn.microsoft.com/en-us/windows/terminal/command-line-arguments)

Current `main` has an opt-in `compatibility.allowOSC777` implementation. Its internal notification click callback selects the source tab and summons the owning window. That is promising because the terminal itself already knows the source; it is not a public focus API usable by this plugin's WinForms popup.

- [OSC 777 setting on `main`](https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalSettingsModel/MTSMSettings.h#L111)
- [Internal click handling selects the tab and summons the window](https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalApp/DesktopNotification.cpp#L37-L45)
- [Merged OSC 777 implementation PR](https://github.com/microsoft/terminal/pull/20012)
- [Latest stable v1.24 settings source, which has no `AllowOSC777`](https://github.com/microsoft/terminal/blob/v1.24.11911.0/src/cascadia/TerminalSettingsModel/MTSMSettings.h)

Therefore there are two future options for adding exact-return behavior beyond the current generic popup:

1. A terminal-native OSC 777 backend after the feature reaches stable and terminal attachment from a Codex hook is verified. Its presentation, sound, and click behavior belong to Windows Terminal, so it is a different backend from the custom popup.
2. A custom-popup adapter only if Windows Terminal exposes a supported exact-session activation API. Win32 title/PID heuristics are not a sufficient contract.

### Alacritty

Alacritty supports Windows, but its Windows ConPTY launcher only passes inherited/configured environment; the Unix launcher is the code that injects `ALACRITTY_WINDOW_ID`. Its socket and `alacritty msg` command are Unix-gated. The published escape-sequence table does not implement OSC 9, 99, or 777. A configured bell command is an external hook, not a structured native notification or click target.

- [Supported platforms](https://alacritty.org/)
- [Windows ConPTY environment construction](https://github.com/alacritty/alacritty/blob/master/alacritty_terminal/src/tty/windows/conpty.rs#L208-L212)
- [Unix `ALACRITTY_WINDOW_ID` injection](https://github.com/alacritty/alacritty/blob/master/alacritty_terminal/src/tty/unix.rs#L228-L234)
- [Unix-only IPC CLI source](https://github.com/alacritty/alacritty/blob/master/alacritty/src/cli.rs#L94-L97)
- [Implemented/rejected escape sequences](https://alacritty.org/misc-alacritty-escapes.html)
- [`bell.command` configuration](https://github.com/alacritty/alacritty/blob/master/extra/man/alacritty.5.scd#L495-L525)

Because Alacritty has no tabs/splits of its own, process/HWND ancestry could produce a best-effort Windows focus hack in simple single-process cases. It fails as a supported design once multiple Alacritty windows share a process or a shell is mediated by WSL, so it should not be called an adapter.

> **Revised 2026-07-30.** Ancestry-based window focus did ship, as a generic capability rather than a per-terminal adapter, because embedded terminals left the notification with nothing to click. The objection above was answered rather than dismissed: the multiple-windows-share-a-process case is resolved by matching the working directory's folder names against window titles, and a non-unique match refuses to act instead of guessing. The WSL case remains unsupported, as does anything where the host window is not on this machine.

### kitty

kitty demonstrates that the concept is not inherently WezTerm-only. `KITTY_WINDOW_ID` is explicitly intended for remote control; `focus-window` and `focus-tab` can address existing targets. Its OSC 99 protocol is substantially richer than OSC 9/777 and defaults notification activation to focusing the originating window. It can also request a sound and activation/close reports. Remote control is security-sensitive and must be enabled or granted through a listener/password policy.

- [Official platforms/binaries: Linux and macOS](https://sw.kovidgoyal.net/kitty/binary/)
- [`KITTY_WINDOW_ID`, listener, matching, and focus commands](https://sw.kovidgoyal.net/kitty/remote-control/)
- [OSC 99 desktop-notification protocol](https://sw.kovidgoyal.net/kitty/desktop-notifications/)

This is the best candidate for a future non-Windows adapter, not a reason to broaden the current Windows repository before such an adapter exists.

### Ghostty

Ghostty officially runs on macOS and Linux and says Windows is planned. It implements terminal notifications, but its documented cross-platform control surface does not connect a Codex hook's origin to an exact existing surface and then foreground it. macOS AppleScript can automate Ghostty windows/tabs/terminals, so a separate macOS adapter may be possible after proving stable origin identity and focus semantics.

- [Platforms and Windows roadmap](https://ghostty.org/docs/features)
- [OSC 9 desktop notifications](https://ghostty.org/docs/vt/osc/9)
- [OSC 777 recommendation in 1.2 release notes](https://ghostty.org/docs/install/release-notes/1-2-0#graphical-progress-bars)
- [macOS AppleScript automation](https://ghostty.org/docs/features/applescript)

### tmux

tmux assigns lifetime-stable session/window/pane IDs, exposes the current pane as `TMUX_PANE`, and accepts exact targets in `select-pane` and `select-window`. That solves only the inner multiplexer layer. It cannot identify or foreground the outer WezTerm/kitty/Windows Terminal OS window, so correct support requires a composite of tmux targeting plus a proven host-terminal adapter. Passthrough is opt-in and is not a focus API.

- [Official tmux manual source: IDs, `TMUX_PANE`, target commands, and `allow-passthrough`](https://github.com/tmux/tmux/blob/master/tmux.1)

## OSC notification protocols are not a portable adapter

There is no single interoperable notification-and-focus protocol:

| Protocol | Shape | Important limitation |
|---|---|---|
| OSC 9 | Legacy iTerm-style message | Minimal payload; collides with ConEmu's OSC 9 family; click and sound semantics are terminal-defined |
| OSC 99 | kitty's extensible protocol | Rich and explicitly supports focus/report/sound, but is not broadly implemented on the Windows terminals considered here |
| OSC 777 | De-facto `notify;title;body` convention | Broader support than OSC 99, but click, suppression, sound, and availability differ by terminal/version |

WezTerm documents OSC 9 and 777; kitty owns the OSC 99 design; Ghostty documents OSC 9; Windows Terminal's current `main` implements opt-in OSC 777; Alacritty implements none of them. An OSC backend must write to the originating TTY while it still exists. A detached notifier cannot infer that channel later, and Codex hook stdout behavior must be verified before emitting escape sequences from a hook.

## Recommendation

1. Publish **`codex-wezterm-notify`** with generic native Windows notifications and an explicit WezTerm enhancement.
2. Keep internal seams narrow: event normalization, Windows popup rendering, and `Focus-WezTermPane`. Do not publish a terminal-adapter abstraction yet.
3. Document WezTerm as the requirement for exact-pane return, not for notifications themselves.
4. Track Windows Terminal OSC 777 as an experimental future backend once it ships stable and hook-to-TTY emission is proven.
5. If expanding beyond Windows, implement kitty second. Only then consider renaming to a terminal-neutral project and preserving this repository/name as an install alias or redirect.
