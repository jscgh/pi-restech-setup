/**
 * Pi Notify Extension
 *
 * Sends a terminal/desktop notification when the agent finishes and is waiting
 * for input, including a brief preview of the final assistant message.
 * Based on the official example shipped with pi
 * (examples/extensions/notify.ts), with additions for remote/HPC use:
 * - BEL fallback for terminals that don't implement OSC 777/99
 * - tmux passthrough wrapping when running inside tmux (needed over ssh)
 * - preview of the last assistant message in the notification body
 *
 * Protocols:
 * - OSC 777: Ghostty, iTerm2, WezTerm, rxvt-unicode, Konsole
 * - OSC 99:  Kitty
 * - BEL:     any terminal with an audible/urgent bell configured
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PREVIEW_MAX = 140;

function windowsToastScript(title: string, body: string): string {
	const type = "Windows.UI.Notifications";
	const mgr = `[${type}.ToastNotificationManager, ${type}, ContentType = WindowsRuntime]`;
	const template = `[${type}.ToastTemplateType]::ToastText01`;
	const toast = `[${type}.ToastNotification]::new($xml)`;
	return [
		`${mgr} > $null`,
		`$xml = [${type}.ToastNotificationManager]::GetTemplateContent(${template})`,
		`$xml.GetElementsByTagName('text')[0].AppendChild($xml.CreateTextNode('${body}')) > $null`,
		`[${type}.ToastNotificationManager]::CreateToastNotifier('${title}').Show(${toast})`,
	].join("; ");
}

function sanitize(body: string): string {
	// Strip control characters (BEL/ESC would terminate or corrupt the OSC frame).
	return body.replace(/[\x00-\x1f\x7f]/g, " ").replace(/\s+/g, " ").trim();
}

function preview(text: string): string {
	const clean = sanitize(text);
	if (!clean) return "";
	return clean.length > PREVIEW_MAX ? clean.slice(0, PREVIEW_MAX - 1).trimEnd() + "…" : clean;
}

function extractAssistantText(message: unknown): string {
	const m = message as { content?: unknown } | undefined;
	const c = m?.content;
	if (typeof c === "string") return c;
	if (Array.isArray(c)) {
		return (c as Array<{ type?: string; text?: string }>)
			.filter((b) => b?.type === "text" && typeof b.text === "string")
			.map((b) => b.text as string)
			.join("\n");
	}
	return "";
}

function rawOSC777(title: string, body: string): string {
	return `\x1b]777;notify;${title};${body}\x07`;
}

function rawOSC99(title: string, body: string): string {
	// Kitty OSC 99: i=notification id, d=0 means not done yet, p=body for second part
	return (
		`\x1b]99;i=1:d=0;${title}\x1b\\` +
		`\x1b]99;i=1:p=body;${body}\x1b\\`
	);
}

// Inside tmux, escape sequences must be wrapped in the passthrough sequence,
// with every nested ESC byte doubled so tmux forwards them verbatim.
function tmuxWrap(seq: string): string {
	return `\x1bPtmux;${seq.replace(/\x1b/g, "\x1b\x1b")}\x1b\\`;
}

function emit(seq: string): void {
	if (process.env.TMUX) {
		process.stdout.write(tmuxWrap(seq));
	} else {
		process.stdout.write(seq);
	}
}

function notify(title: string, body: string): void {
	if (process.env.WT_SESSION) {
		const { execFile } = require("child_process");
		execFile("powershell.exe", ["-NoProfile", "-Command", windowsToastScript(title, body)]);
		return;
	}
	if (process.env.KITTY_WINDOW_ID) {
		emit(rawOSC99(title, body));
		return;
	}
	// OSC 777 for capable terminals...
	emit(rawOSC777(title, body));
	// ...plus BEL for any terminal that surfaces bells as alerts instead.
	process.stdout.write("\x07");
}

export default function (pi: ExtensionAPI) {
	let pendingPreview = "";

	// `agent_end` fires after each low-level run and carries the transcript.
	// If a retry is pending, a later agent_end will overwrite this.
	pi.on("agent_end", (event: { messages?: unknown[]; willRetry?: boolean }) => {
		if (event?.willRetry) return;
		const messages = event?.messages ?? [];
		for (let i = messages.length - 1; i >= 0; i--) {
			const m = messages[i] as { role?: string };
			if (m?.role === "assistant") {
				pendingPreview = preview(extractAssistantText(m));
				return;
			}
		}
		pendingPreview = "";
	});

	// `agent_settled` fires once the full run is done (no retries/compaction/
	// queued follow-ups pending) — the right moment to notify.
	pi.on("agent_settled", async () => {
		// Only emit on a real terminal; never pollute piped/print output.
		if (!process.stdout.isTTY) return;
		notify("Pi", pendingPreview || "Ready for input");
		pendingPreview = "";
	});
}
