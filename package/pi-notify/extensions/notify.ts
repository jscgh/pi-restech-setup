/**
 * pi-notify
 *
 * Notifies when the agent finishes and is waiting for input, with a short
 * preview of the final assistant message.
 *
 * Design rules, in priority order:
 *   1. Never block or break the agent. pi *awaits* the agent_settled handler, so
 *      this path is on the critical path: a normal call is ~10 ms synchronous.
 *      A wedged bus costs one timeout (1500 ms by default); the error classifier
 *      stops before paying the deadline again in the fallback helper.
 *      If it ever registers as a hitch, switch to execFile and *always* attach
 *      an 'error' handler, since an unhandled ENOENT would crash pi.
 *   2. Prefer the desktop session bus (org.freedesktop.Notifications). It is
 *      the one channel that works across GNOME Terminal (VTE), Ghostty and
 *      VS Code's integrated terminal on Linux, because it belongs to the
 *      desktop rather than to the terminal.
 *   3. Fall back to in-terminal escape sequences only when no bus is
 *      reachable (e.g. a plain ssh session into a headless node).
 *
 * Transport, deliberately conservative:
 *   - Primary helper is `gdbus call` (GLib: effectively always present in a
 *     GNOME session, tiny, and takes the message as an argv element so no
 *     shell quoting is involved).
 *   - `notify-send` is only a secondary helper; it lives in libnotify-bin and
 *     is frequently absent on slim images.
 *   - No `--wait`/`-A`, and no detached `sh -c` click helper: both were
 *     verified broken under gnome-shell (the notification gets queued to the
 *     message list instead of popping a banner -- observed, though this specific
 *     claim is inherited from the extension's earlier notes rather than
 *     re-measured). Click-to-focus is not worth the failure mode.
 *
 * Config (all optional, env-only so this stays a single-file extension):
 *   PI_NOTIFY_DISABLE=1        emit nothing at all
 *   PI_NOTIFY_DESKTOP=0        skip the bus, force escape sequences
 *   PI_NOTIFY_BEL=0            suppress the audible bell
 *   PI_NOTIFY_PREVIEW=0        send a fixed line instead of message text
 *   PI_NOTIFY_TITLE=<str>      default "Pi"
 *   PI_NOTIFY_TIMEOUT_MS=<int> per-helper deadline, default 1500
 *
 * Terminals: Ghostty/iTerm2/WezTerm/Konsole/rxvt speak OSC 777, Kitty speaks
 * OSC 99, and VS Code's integrated terminal speaks neither -- which is exactly
 * why the bus comes first.
 */

import { execFileSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PREVIEW_MAX = 140;

function num(name: string, fallback: number): number {
	const raw = process.env[name];
	if (!raw) return fallback;
	const n = Number.parseInt(raw, 10);
	return Number.isFinite(n) && n >= 0 ? n : fallback;
}

function off(name: string): boolean {
	return process.env[name] === "0" || process.env[name] === "false";
}

function title(): string {
	return process.env.PI_NOTIFY_TITLE || "Pi";
}

// ---------------------------------------------------------------------------
// Escape sequences
// ---------------------------------------------------------------------------

/** Control chars would terminate or corrupt an OSC frame. */
function sanitize(text: string): string {
	return text.replace(/[\x00-\x1f\x7f]/g, " ").replace(/\s+/g, " ").trim();
}

function preview(text: string): string {
	const clean = sanitize(text);
	if (!clean) return "";
	return clean.length > PREVIEW_MAX ? clean.slice(0, PREVIEW_MAX - 1).trimEnd() + "…" : clean;
}

function osc777(t: string, b: string): string {
	return `\x1b]777;notify;${t};${b}\x07`;
}

function osc99(t: string, b: string): string {
	// i=id, d=0 => not yet done, p=body for the second frame
	return `\x1b]99;i=1:d=0;${t}\x1b\\` + `\x1b]99;i=1:p=body;${b}\x1b\\`;
}

/** Inside tmux, OSC must ride in a DCS passthrough with nested ESCs doubled. */
function wrap(seq: string): string {
	return process.env.TMUX ? `\x1bPtmux;${seq.replace(/\x1b/g, "\x1b\x1b")}\x1b\\` : seq;
}

function writeTerminal(text: string): void {
	// Never throw, never write into piped/print output.
	if (!process.stdout.isTTY) return;
	try {
		process.stdout.write(text);
	} catch {
		/* stdout gone (e.g. parent exited) -- nothing to notify */
	}
}

// ---------------------------------------------------------------------------
// Desktop bus
// ---------------------------------------------------------------------------

/**
 * The freedesktop Notify signature is (s,u,s,s,s,as,a{sv},i):
 *   app_name, replaces_id, app_icon, summary, body, actions, hints, timeout
 * Hint variants verified on GNOME Shell 46 via dbus-monitor: `urgency` and
 * `expire-time` are both int32. `timeout` is deprecated (notify-send sends -1);
 * the expire-time hint is what actually bounds a banner's life, so it is
 * derived from the helper deadline rather than left at the server default.
 */
const DEST = "org.freedesktop.Notifications";
const PATH = "/org/freedesktop/Notifications";

function hints(t: string, b: string, ms: number): string[] {
	return [t, "0", "", t, b, "[]", `{'urgency': <1>, 'expire-time': <${ms}>}`, "-1"];
}

type Helper = { cmd: string; args: (t: string, b: string, ms: number) => string[] };

const HELPERS: Helper[] = [
	{
		cmd: "gdbus",
		args: (t, b, ms) => [
			// `call` is the gdbus subcommand; without it gdbus prints its usage
			// block and exits 1, so the primary helper never delivered and every
			// notification silently fell through to notify-send.
			"call",
			"--session",
			"--dest",
			DEST,
			"--object-path",
			PATH,
			"--method",
			`${DEST}.Notify`,
			// `--` is not cosmetic: without it gdbus parses a message body that
			// begins with "-" as its own option and the call exits 1.
			"--",
			...hints(t, b, ms),
		],
	},
	{
		cmd: "notify-send",
		// Same field order, spelled as flags -- kept as the fallback because
		// notify-send resolves the session bus for us in odd container setups.
		args: (t, b, ms) => [
			"--app-name",
			t,
			"--hint",
			"int:urgency:1",
			"--expire-time",
			String(ms),
			t,
			b,
		],
	},
];

/**
 * True when a session bus looks reachable. Kept strict on purpose: headless
 * hosts often still set XDG_RUNTIME_DIR, and we would rather fall through to
 * OSC than spawn a helper that hangs.
 */
function haveDesktopBus(): boolean {
	if (off("PI_NOTIFY_DESKTOP")) return false;
	if (process.env.PI_NOTIFY_DISABLE === "1") return false;
	if (process.env.XDG_CURRENT_DESKTOP) return true;
	if (process.env.DISPLAY || process.env.WAYLAND_DISPLAY) return true;
	const dir = process.env.XDG_RUNTIME_DIR;
	return Boolean(dir && dir.includes("/run/user") && process.env.DBUS_SESSION_BUS_ADDRESS);
}

/**
 * Dispatch via the bus. Reports "we asked for it", never "you saw it" -- a
 * filtered or dismissed notification is indistinguishable from here, so nobody
 * upstream should treat the return value as a delivery guarantee.
 *
 * Uses execFileSync on purpose: the round trip is ~9 ms (measured on GNOME
 * Shell 46), which is cheap enough to stay inside the settle callback, and it
 * lets us see the real exit status so a broken `gdbus` can fall through to
 * `notify-send`. The asynchronous forms cannot do that: execFile reports a
 * missing binary as an *async* 'error' event, so an unhandled ENOENT would
 * crash the agent -- the one outcome this file must never produce. If this
 * ever goes async, every child needs an 'error' handler.
 */
function desktopNotify(t: string, b: string): boolean {
	if (!haveDesktopBus()) return false;
	const timeoutMs = num("PI_NOTIFY_TIMEOUT_MS", 1500);
	for (const helper of HELPERS) {
		try {
			execFileSync(helper.cmd, helper.args(t, b, timeoutMs), {
				timeout: timeoutMs,
				stdio: "ignore",
				windowsHide: true,
			});
			return true;
		} catch (err) {
			// ENOENT (helper absent) or a non-zero exit / timeout: try the next
			// helper. Anything else is still our problem, never the agent's.
			const code = (err as NodeJS.ErrnoException)?.code;
			const status = (err as { status?: number | null })?.status;
			// Node v22 reports both spawn failures and timeouts with status=null,
			// not undefined. ENOENT should try the next helper; a nonzero numeric
			// status means the helper ran and rejected the request, so fallback may
			// still work. ETIMEDOUT/null means the bus is wedged: stop before paying
			// the timeout a second time in notify-send.
			if (code !== "ENOENT" && status == null) return false;
		}
	}
	return false;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function notify(t: string, b: string): void {
	if (process.env.PI_NOTIFY_DISABLE === "1") return;

	const delivered = desktopNotify(t, b);

	// In-terminal bubbles only when the bus was unusable.
	if (!delivered) {
		const seq = process.env.KITTY_WINDOW_ID ? osc99(t, b) : osc777(t, b);
		writeTerminal(wrap(seq));
	}

	// Audible cue regardless of which visual channel worked.
	if (!off("PI_NOTIFY_BEL")) writeTerminal("\x07");
}

export default function (pi: ExtensionAPI): void {
	let pendingPreview = "";

	// agent_end carries the transcript after each low-level run; a retry,
	// compaction or queued follow-up will fire another one that overwrites this.
	pi.on("agent_end", (event: { messages?: unknown[]; willRetry?: boolean }) => {
		if (event?.willRetry) return;
		const messages = event?.messages ?? [];
		for (let i = messages.length - 1; i >= 0; i--) {
			const message = messages[i] as { role?: string; content?: unknown };
			if (message?.role === "assistant") {
				pendingPreview = preview(assistantText(message.content));
				return;
			}
		}
		pendingPreview = "";
	});

	// agent_settled is final: no further retries/compaction/continuations.
	pi.on("agent_settled", () => {
		const body =
			!off("PI_NOTIFY_PREVIEW") && pendingPreview
				? pendingPreview
				: "Ready for input";
		notify(title(), body);
		pendingPreview = "";
	});
}

function assistantText(content: unknown): string {
	if (typeof content === "string") return content;
	if (Array.isArray(content)) {
		return (content as Array<{ type?: string; text?: string }>)
			.filter((block) => block?.type === "text" && typeof block.text === "string")
			.map((block) => block.text as string)
			.join("\n");
	}
	return "";
}
