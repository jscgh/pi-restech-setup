/**
 * Based on Pi's examples/extensions/minimal-mode.ts.
 * Adds one-line tinted calls, compact errors, and width-safe truncation.
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

function shortenPath(path: string): string {
	const home = homedir();
	if (path.startsWith(home)) {
		return `~${path.slice(home.length)}`;
	}
	return path;
}

function oneLine(text: string, max = 120): string {
	const flat = (text || "").replace(/\s+/g, " ").trim();
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

function styleLines(text: string, style: (line: string) => string): string {
	return text
		.split("\n")
		.map((line) => style(line))
		.join("\n");
}

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
		// An empty component must occupy no terminal row.
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

function stateBg(theme: any, context: any): (text: string) => string {
	if (context?.isPartial) return (text: string) => theme.bg("toolPendingBg", text);
	if (context?.isError) return (text: string) => theme.bg("toolErrorBg", text);
	return (text: string) => theme.bg("toolSuccessBg", text);
}

function expandedOutput(result: any, theme: any, bgFn: (text: string) => string): Text {
	const text = firstText(result).trim();
	if (!text) return new Text("", 0, 0, bgFn);
	const styled = styleLines(text, (line) => theme.fg("toolOutput", line));
	return new Text(`\n${styled}`, 1, 0, bgFn);
}

export default function (pi: ExtensionAPI) {
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
				return (getBuiltInTools(ctx.cwd) as any)[name].execute(toolCallId, params, signal, onUpdate, ctx);
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

	register(
		"write",
		"Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
		(args, theme) =>
			theme.fg("toolTitle", theme.bold("write ")) + theme.fg("accent", shortenPath(args.path || "...")),
		(args, theme) => theme.fg("toolTitle", theme.bold("write ")) + theme.fg("accent", args.path || "..."),
	);

	register(
		"edit",
		"Edit a file by replacing exact text. The oldText must match exactly (including whitespace). Use this for precise, surgical edits.",
		(args, theme) =>
			theme.fg("toolTitle", theme.bold("edit ")) + theme.fg("accent", shortenPath(args.path || "...")),
		(args, theme) => theme.fg("toolTitle", theme.bold("edit ")) + theme.fg("accent", args.path || "..."),
	);

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
