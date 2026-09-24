# pi-notify

Pi extension that notifies you when the agent finishes and is waiting for input,
with a one-line preview of its final message.

## Why not just OSC 777?

There is **no standardised terminal notification sequence.** OSC 777 is an
unofficial rxvt extension; Ghostty/iTerm2/WezTerm/Konsole implement it, and VTE
(GNOME Terminal) and VS Code's integrated terminal ignore it entirely. The only
truly universal sequences are BEL and OSC 0 (title), and BEL is audio-only —
it is invisible when the window is unfocused or the bell is muted.

So the **desktop session bus (`org.freedesktop.Notifications`) is the primary
channel**: it belongs to the desktop, not the terminal, which is why one code
path covers GNOME Terminal, Ghostty and VS Code on Linux. Escape sequences are
the fallback for when no bus is reachable (e.g. plain ssh into a headless node).

| Terminal | Bus | OSC fallback |
| --- | --- | --- |
| GNOME Terminal (VTE) | ✅ primary | ❌ ignored |
| Ghostty | ✅ primary | ✅ OSC 777 |
| VS Code integrated | ✅ primary | ❌ ignored |
| Kitty | ✅ primary | ✅ OSC 99 |
| tmux over ssh | ✅ primary | ✅ DCS-wrapped |

## Install

```bash
pi install git:github.com/jscgh/pi-restech-setup
```

The repository's root `package.json` explicitly exposes
`package/pi-notify/extensions/notify.ts`. This exact layout was tested in a
fresh pi process: one settle produced one D-Bus `Notify` frame.

For local development, `pi install <repo>/package/pi-notify` also works, but it
symlinks the checkout; moving or deleting the checkout breaks the install.

Uninstall with the same source string:
`pi uninstall git:github.com/jscgh/pi-restech-setup`.

## Teammates on VS Code

Nothing special is needed: VS Code on Linux shows the same desktop banners.
`PI_NOTIFY_TITLE` changes the visible summary and bus app name; it does not make
the notification acquire VS Code's icon or application identity.

## Config

| Variable | Default | Effect |
| --- | --- | --- |
| `PI_NOTIFY_DISABLE=1` | off | emit nothing |
| `PI_NOTIFY_DESKTOP=0` | off | skip the bus, force escape sequences |
| `PI_NOTIFY_BEL=0` | off | silence the audible bell |
| `PI_NOTIFY_PREVIEW=0` | off | fixed line instead of the message preview |
| `PI_NOTIFY_TITLE` | `Pi` | banner app-name + summary |
| `PI_NOTIFY_TIMEOUT_MS` | `1500` | per-helper deadline |

## Verifying it actually works

A notification extension can only be tested by looking at the screen — the code
can report "sent" but never "displayed". The ground truth is the D-Bus frame:

```bash
dbus-monitor --session "destination=org.freedesktop.Notifications","member=Notify" &
pi -p "say ok"     # expect exactly one Notify method call
```

Check gnome-shell did not drop it:

```bash
journalctl --user --since "-2 min" | grep -i "messageTray\|notification"
```

Note: `notify-send` exiting 0 proves nothing — it does not wait for display.

## Known limits

- **`pi -p` still raises a banner.** `agent_settled` fires in print mode too, and
  a banner is visible OS state, so scripted use will pop notifications. Set
  `PI_NOTIFY_DISABLE=1` (or `PI_NOTIFY_DESKTOP=0`) around scripted calls;
  `PI_NOTIFY_DESKTOP=0` was confirmed to skip the bus entirely (0 D-Bus frames).
  BEL and OSC are correctly suppressed when stdout is not a TTY — verified
  against a pipe, a redirect and `--no-session` — but the bus path cannot be
  detected that way, so it stays opt-out rather than automatic.
- Only one notification per run. Subagent activity does not add frames (checked
  against pi-subagents); each top-level settle fires exactly one.
- Click-to-open was removed. It required `notify-send --wait` in a detached
  `sh -c`; that combination was **observed** to queue the item to the gnome-shell
  message list instead of popping a banner. The specific `--wait`-on-GNOME
  behaviour is quoted from the extension's own earlier notes and was not
  independently re-verified, but `--wait` requires a blocking callback and pi
  loads extensions with the same permissions as the agent, so it was cut.
- **Which terminals honour OSC 777 / 99 is unverified.** The table above is
  based on those protocols' origin implementations (rxvt-unicode, Kitty) plus
  what pi's own bundled example claims. Ghostty is the only case tested here,
  via `ghostty +show-config --default` — it does support them and ships them
  switched off. iTerm2/WezTerm/Konsole/rxvt are inherited from upstream docs,
  not measured. On Linux this matters little: the bus is the primary path and
  OSC only runs when no bus is reachable.
- Delivery is best-effort and unverified. A filtered/snoozed notification is
  indistinguishable from a delivered one.
- Only Linux desktops are covered by the bus path. Windows (WSL/`WT_SESSION`)
  and macOS were deliberately left out: untested here, and shipping dead
  platform code is how it rots.
