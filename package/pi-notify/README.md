# pi-notify

Notification extension based on Pi's `examples/extensions/notify.ts`.

The upstream behavior is retained:

- Windows toast in Windows Terminal/WSL
- OSC 99 in Kitty
- OSC 777 elsewhere

This package adds:

- a TTY guard so redirected output stays clean
- a BEL after the visual notification
- environment-variable opt-outs

## Install

From the repository root:

```bash
pi install .
```

For local package development:

```bash
pi install ./package/pi-notify
```

The second form links the checkout and stops working if it is moved or deleted.

## Configuration

| Variable | Effect |
| --- | --- |
| `PI_NOTIFY_DISABLE=1` | Disable all notifications |
| `PI_NOTIFY_BEL=0` | Disable BEL while retaining OSC or Windows toast |

Nothing is emitted when stdout is not a TTY.

## Terminal notes

- GNOME Terminal ignores OSC 777, so enable its terminal bell for an audible or visual cue.
- Kitty uses OSC 99.
- Other terminal behavior depends on OSC 777 support.
- The Windows toast path is inherited from the Pi example and is not tested by this Linux-focused repository.

Delivery is best-effort. Terminal settings may suppress OSC notifications or BEL.
