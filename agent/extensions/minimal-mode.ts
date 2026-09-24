/**
 * Minimal Mode (compressed) - Codex-style single-line tool rendering
 *
 * Collapsed (default): each tool call shows exactly ONE short line
 * (e.g. `$ npm test`, `read src/foo.ts`) with pi's default state-based
 * background tint (pending/success/error), so it looks like stock pi -
 * just smaller. No output. Ctrl+O expands both the command (full text,
 * default styling) and the output (indented). Errors show a one-line
 * error hint while collapsed.
 *
 * Based on the official minimal-mode.ts example from pi, modified:
 * - TruncatedText-equivalent single-line rendering with the same
 *   toolPendingBg/toolSuccessBg/toolErrorBg tint the default box uses
 * - renderCall honors context.expanded (full command when expanded)
 * - collapsed results render nothing (except a short error line)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
	createBashTool,
	createEditTool,
	createFindTool,
	createGrepTool,
	createLsTool,
	createReadTool,
	createWriteTool,
} from "@earendil-works/pi-coding-agent";
import { Text, truncateToWidth, type Component } from "@earendil-works/pi-tui";
import { homedir } from "os";

/** Shorten a path by replacing home directory with ~ */
function shortenPath(path: string): string {
	const home = homedir();
	if (path.startsWith(home)) {
		return `~${path.slice(home.length)}`;
	}
	return path;
}

/** Collapse to one line, capped at a sane length. */
function oneLine(text: string, max = 120): string {
	const flat = (text || "").replace(/\s+/g, " ").trim();
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

/** Style each line of multi-line text with the same style fn, joined. */
function styleLines(text: string, style: (line: string) => string): string {
	return text
		.split("\n")
		.map((line) => style(line))
		.join("\n");
}

/**
 * Single-line component: truncates to terminal width (ANSI-safe) and
 * applies pi's state background tint, mimicking the default Box shell.
 */
class TintedLine implements Component {
	private text: string;
	private bgFn: ((text: string) => string) | undefined;
	private cachedWidth?: number;
	private cachedLines?: string[];

	constructor(text: string, bgFn?: (text: string) => string) {
		this.text = text;
		this.bgFn = bgFn;
	}

	setText(text: string, bgFn?: (text: string) => string): void {
		if (text !== this.text || bgFn !== this.bgFn) {
			this.text = text;
			this.bgFn = bgFn;
			this.cachedWidth = undefined;
		}
	}

	invalidate(): void {
		this.cachedWidth = undefined;
		this.cachedLines = undefined;
	}

	render(width: number): string[] {
		// Empty text renders ZERO lines (not one blank line) - keeps the
		// collapsed layout to exactly: 1 blank separator + the command line.
		if (!this.text) return [];
		if (this.cachedLines === undefined || this.cachedWidth !== width) {
			let line = truncateToWidth(this.text, Math.max(1, width), "…");
			if (this.bgFn) line = this.bgFn(line);
			this.cachedLines = [line];
			this.cachedWidth = width;
		}
		return this.cachedLines;
	}
}

// Cache for built-in tools by cwd
const toolCache = new Map<string, ReturnType<typeof createBuiltInTools>>();

function createBuiltInTools(cwd: string) {
	return {
		read: createReadTool(cwd),
		bash: createBashTool(cwd),
		edit: createEditTool(cwd),
		write: createWriteTool(cwd),
		find: createFindTool(cwd),
		grep: createGrepTool(cwd),
		ls: createLsTool(cwd),
	};
}

function getBuiltInTools(cwd: string) {
	let tools = toolCache.get(cwd);
	if (!tools) {
		tools = createBuiltInTools(cwd);
		toolCache.set(cwd, tools);
	}
	return tools;
}

function firstText(result: { content: Array<{ type: string; text?: string }> }): string {
	const textContent = result.content.find((c) => c.type === "text" && c.text);
	return textContent && textContent.type === "text" ? textContent.text : "";
}

/** State-dependent background tint, same tokens the default Box shell uses. */
function stateBg(theme: any, context: any): (text: string) => string {
	if (context?.isPartial) return (text: string) => theme.bg("toolPendingBg", text);
	if (context?.isError) return (text: string) => theme.bg("toolErrorBg", text);
	return (text: string) => theme.bg("toolSuccessBg", text);
}

/** Expanded tool output: indented under the command, in toolOutput color. */
function expandedOutput(result: any, theme: any, bgFn: (text: string) => string): Text {
	const text = firstText(result).trim();
	if (!text) return new Text("", 0, 0, bgFn);
	const styled = styleLines(text, (line) => theme.fg("toolOutput", line));
	return new Text(`\n${styled}`, 1, 0, bgFn);
}

export default function (pi: ExtensionAPI) {
	/**
	 * Register a built-in with a custom renderer.
	 * - `compact(args, theme)` returns the single collapsed line.
	 * - `full(args, theme)` returns the expanded call view (default pi style).
	 */
	const register = (
		name: string,
		description: string,
		compact: (args: any, theme: any) => string,
		full: (args: any, theme: any) => string,
	) => {
		const original = (getBuiltInTools(process.cwd()) as any)[name];
		pi.registerTool({
			name,
			label: name,
			description,
			parameters: original.parameters,

			async execute(toolCallId: string, params: any, signal: any, onUpdate: any, ctx: any) {
				return (getBuiltInTools(ctx.cwd) as any)[name].execute(toolCallId, params, signal, onUpdate);
			},

			renderCall(args: any, theme: any, context: any) {
				const bg = stateBg(theme, context);
				if (context?.expanded) return new Text(full(args, theme), 1, 0, bg);
				return new TintedLine(compact(args, theme), bg);
			},

			renderResult(result: any, options: any, theme: any, context: any) {
				if (!options.expanded) {
					if (context?.isError) {
						return new TintedLine(theme.fg("error", `✗ ${name} failed`), stateBg(theme, context));
					}
					return new TintedLine("");
				}
				return expandedOutput(result, theme, stateBg(theme, context));
			},
		});
	};

	// --- read ---
	register(
		"read",
		"Read the contents of a file. Supports text files and images. Output is truncated to 2000 lines or 50KB. Use offset/limit for large files.",
		(args, theme) => {
			let text = theme.fg("toolTitle", theme.bold("read ")) + theme.fg("accent", shortenPath(args.path || "..."));
			if (args.offset !== undefined || args.limit !== undefined) {
				const start = args.offset ?? 1;
				const end = args.limit !== undefined ? start + args.limit - 1 : "";
				text += theme.fg("dim", `:${start}${end ? `-${end}` : ""}`);
			}
			return text;
		},
		(args, theme) => {
			let text = theme.fg("toolTitle", theme.bold("read ")) + theme.fg("accent", args.path || "...");
			if (args.offset !== undefined || args.limit !== undefined) {
				const start = args.offset ?? 1;
				const end = args.limit !== undefined ? start + args.limit - 1 : "";
				text += theme.fg("dim", `:${start}${end ? `-${end}` : ""}`);
			}
			return text;
		},
	);

	// --- bash ---
	register(
		"bash",
		"Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB.",
		(args, theme) => {
			const timeout = args.timeout as number | undefined;
			const suffix = timeout ? theme.fg("muted", ` (timeout ${timeout}s)`) : "";
			return theme.fg("toolTitle", theme.bold(`$ ${oneLine(args.command || "...")}`)) + suffix;
		},
		(args, theme) => {
			const timeout = args.timeout as number | undefined;
			const suffix = timeout ? theme.fg("muted", ` (timeout ${timeout}s)`) : "";
			const command = (args.command || "...").replace(/\s+$/, "");
			return (
				theme.fg("toolTitle", theme.bold("$ ")) +
				styleLines(command, (line) => theme.fg("toolTitle", theme.bold(line))) +
				suffix
			);
		},
	);

	// --- write ---
	register(
		"write",
		"Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
		(args, theme) =>
			theme.fg("toolTitle", theme.bold("write ")) + theme.fg("accent", shortenPath(args.path || "...")),
		(args, theme) => theme.fg("toolTitle", theme.bold("write ")) + theme.fg("accent", args.path || "..."),
	);

	// --- edit ---
	register(
		"edit",
		"Edit a file by replacing exact text. The oldText must match exactly (including whitespace). Use this for precise, surgical edits.",
		(args, theme) =>
			theme.fg("toolTitle", theme.bold("edit ")) + theme.fg("accent", shortenPath(args.path || "...")),
		(args, theme) => theme.fg("toolTitle", theme.bold("edit ")) + theme.fg("accent", args.path || "..."),
	);

	// --- find ---
	register(
		"find",
		"Find files by name pattern (glob). Searches recursively from the specified path. Output limited to 200 results.",
		(args, theme) =>
			theme.fg("toolTitle", theme.bold("find ")) +
			theme.fg("accent", oneLine(args.pattern || "...", 60)) +
			theme.fg("dim", ` ${shortenPath(args.path || ".")}`),
		(args, theme) => {
			let text =
				theme.fg("toolTitle", theme.bold("find ")) +
				theme.fg("accent", args.pattern || "") +
				theme.fg("toolOutput", ` in ${args.path || "."}`);
			if (args.limit !== undefined) text += theme.fg("toolOutput", ` (limit ${args.limit})`);
			return text;
		},
	);

	// --- grep ---
	register(
		"grep",
		"Search file contents by regex pattern. Uses ripgrep. Output limited to 200 matches.",
		(args, theme) =>
			theme.fg("toolTitle", theme.bold("grep ")) +
			theme.fg("accent", `/${oneLine(args.pattern || "...", 50)}/`) +
			theme.fg("dim", ` ${shortenPath(args.path || ".")}`),
		(args, theme) => {
			let text =
				theme.fg("toolTitle", theme.bold("grep ")) +
				theme.fg("accent", `/${args.pattern || ""}/`) +
				theme.fg("toolOutput", ` in ${args.path || "."}`);
			if (args.glob) text += theme.fg("toolOutput", ` (${args.glob})`);
			if (args.limit !== undefined) text += theme.fg("toolOutput", ` limit ${args.limit}`);
			return text;
		},
	);

	// --- ls ---
	register(
		"ls",
		"List directory contents with file sizes. Output limited to 500 entries.",
		(args, theme) =>
			theme.fg("toolTitle", theme.bold("ls ")) + theme.fg("accent", shortenPath(args.path || ".")),
		(args, theme) => {
			let text = theme.fg("toolTitle", theme.bold("ls ")) + theme.fg("accent", args.path || ".");
			if (args.limit !== undefined) text += theme.fg("toolOutput", ` (limit ${args.limit})`);
			return text;
		},
	);
}
