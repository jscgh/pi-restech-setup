import { type Api, type Model, uuidv7 } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { convertToLlm, serializeConversation } from "@earendil-works/pi-coding-agent";

const SUMMARIZATION_SYSTEM_PROMPT = `You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.`;

const SUMMARIZATION_PROMPT = `The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.`;

const UPDATE_SUMMARIZATION_INSTRUCTIONS = `Update the existing structured summary with new information. RULES:
- PRESERVE all existing information from the previous summary
- ADD new progress, decisions, and context from the new messages
- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
- UPDATE "Next Steps" based on what was accomplished
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it

Use this EXACT format:

## Goal
[Preserve existing goals, add new ones if the task expanded]

## Constraints & Preferences
- [Preserve existing, add new ones discovered]

## Progress
### Done
- [x] [Include previously done items AND newly completed items]

### In Progress
- [ ] [Current work - update based on progress]

### Blocked
- [Current blockers - remove if resolved]

## Key Decisions
- **[Decision]**: [Brief rationale] (preserve all previous, add new)

## Next Steps
1. [Update based on current state]

## Critical Context
- [Preserve important context, add new if needed]

Keep each section concise. Preserve exact file paths, function names, and error messages.`;

const UPDATE_SUMMARIZATION_PROMPT = `The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

${UPDATE_SUMMARIZATION_INSTRUCTIONS}`;

const TURN_PREFIX_SUMMARIZATION_PROMPT = `The messages above are earlier context from an ongoing conversation. Later messages are stored separately and do not need to be reconstructed.

Create a concise checkpoint of the user's request and the progress shown above. This checkpoint will be placed before the later messages so the conversation can continue with the necessary context.

## Original Request
[What did the user ask for?]

## Progress So Far
- [Key decisions and work completed in these messages]

## Context Needed to Continue
- [Information from these messages needed to understand the later work]

Only summarize information explicitly present above. Do not infer or recreate later messages.`;

const HISTORY_MAX_TOKENS = 13107;
const TURN_PREFIX_MAX_TOKENS = 8192;
const FIRST_LIFE_TIMEOUT_MS = 45_000;
const ATTEMPT_DEADLINE_MS = 420_000;
const MAX_ATTEMPTS_PER_RUNG = 2;
const RETRY_BACKOFF_MS = 2_000;
const RETRYABLE_ERROR_RE =
	/timeout|timed out|terminated|socket|connection|reset|fetch failed|429|5\d\d|overloaded|rate.?limit|high demand/i;

const DEFAULT_CHAIN = [
	["restech", "qwen3.8-flash-next"],
	["openai-codex", "gpt-5.6-luna"],
	["current", ""],
] as const;

type ChainRef = readonly [provider: string, modelId: string];

type ChainModel = Model<Api>;

export interface ChainRegistryLike<T extends ChainModel = ChainModel> {
	find(provider: string, modelId: string): T | undefined;
	getAvailable(): T[];
	current: T | undefined;
}

interface UsageLike {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cacheWrite1h?: number;
	reasoning?: number;
	totalTokens: number;
	cost: { input: number; output: number; cacheRead: number; cacheWrite: number; total: number };
}

function parseChainOverrides(raw: string | undefined): { refs: ChainRef[]; invalid: string[] } {
	if (!raw || !raw.trim()) return { refs: [], invalid: [] };
	const refs: ChainRef[] = [];
	const invalid: string[] = [];
	for (const token of raw.split(",")) {
		const entry = token.trim();
		if (!entry) continue;
		if (entry === "current") {
			refs.push(["current", ""]);
			continue;
		}
		const slash = entry.indexOf("/");
		if (slash <= 0 || slash === entry.length - 1 || entry.indexOf("/", slash + 1) !== -1) {
			invalid.push(entry);
			continue;
		}
		refs.push([entry.slice(0, slash), entry.slice(slash + 1)]);
	}
	return { refs, invalid };
}

function resolveChainTargets<T extends ChainModel>(
	chainRefs: readonly ChainRef[],
	registry: ChainRegistryLike<T>,
): { targets: T[]; warnings: string[] } {
	const available = registry.getAvailable();
	const attempted = new Set<string>();
	const targets: T[] = [];
	const warnings: string[] = [];
	for (const [provider, modelId] of chainRefs) {
		const model =
			provider === "current"
				? registry.current
				: available.find((candidate) => candidate.provider === provider && candidate.id === modelId) ??
					registry.find(provider, modelId);
		if (!model) {
			warnings.push(provider === "current" ? "current model unavailable" : `${provider}/${modelId} unavailable`);
			continue;
		}
		const key = `${model.provider}/${model.id}`;
		if (attempted.has(key)) continue;
		attempted.add(key);
		targets.push(model);
	}
	return { targets, warnings };
}

function isRetryableFailure(stopReason: string, errorMessage: string | undefined): boolean {
	if (stopReason !== "error") return false;
	return RETRYABLE_ERROR_RE.test(errorMessage ?? "");
}

function isAcceptableSummary(message: {
	stopReason: string;
	content: ReadonlyArray<{ type: string; text?: string }>;
}): boolean {
	if (message.stopReason !== "stop" || message.content.some((part) => part.type === "toolCall")) return false;
	return withoutFileTags(message.content.filter((part) => part.type === "text").map((part) => part.text ?? "").join("\n")).length > 0;
}

function combineUsage(first: UsageLike, second: UsageLike): UsageLike {
	return {
		input: first.input + second.input,
		output: first.output + second.output,
		cacheRead: first.cacheRead + second.cacheRead,
		cacheWrite: first.cacheWrite + second.cacheWrite,
		...(first.cacheWrite1h !== undefined || second.cacheWrite1h !== undefined
			? { cacheWrite1h: (first.cacheWrite1h ?? 0) + (second.cacheWrite1h ?? 0) }
			: {}),
		...(first.reasoning !== undefined || second.reasoning !== undefined
			? { reasoning: (first.reasoning ?? 0) + (second.reasoning ?? 0) }
			: {}),
		totalTokens: first.totalTokens + second.totalTokens,
		cost: {
			input: first.cost.input + second.cost.input,
			output: first.cost.output + second.cost.output,
			cacheRead: first.cost.cacheRead + second.cost.cacheRead,
			cacheWrite: first.cost.cacheWrite + second.cost.cacheWrite,
			total: first.cost.total + second.cost.total,
		},
	};
}

function taggedFiles(summary: string | undefined, tag: "read-files" | "modified-files"): string[] {
	if (!summary) return [];
	const match = summary.match(new RegExp(`<${tag}>\\s*([\\s\\S]*?)\\s*</${tag}>`, "i"));
	return match ? match[1].split("\n").map((line) => line.trim()).filter(Boolean) : [];
}

function withoutFileTags(summary: string): string {
	return summary
		.replace(/<read-files>[\s\S]*?<\/read-files>/gi, "")
		.replace(/<modified-files>[\s\S]*?<\/modified-files>/gi, "")
		.trim();
}

type AnyAgentMessage = Parameters<typeof convertToLlm>[0][number];

function buildHistoryPrompt(messages: AnyAgentMessage[], previousSummary: string | undefined, customInstructions: string | undefined): string {
	let basePrompt = previousSummary ? UPDATE_SUMMARIZATION_PROMPT : SUMMARIZATION_PROMPT;
	if (customInstructions) basePrompt = `${basePrompt}\n\nAdditional focus: ${customInstructions}`;
	let promptText = `<conversation>\n${serializeConversation(convertToLlm(messages))}\n</conversation>\n\n`;
	if (previousSummary) promptText += `<previous-summary>\n${previousSummary}\n</previous-summary>\n\n`;
	return promptText + basePrompt;
}

function buildTurnPrefixPrompt(messages: AnyAgentMessage[]): string {
	return `# Conversation\n${serializeConversation(convertToLlm(messages))}\n\n# Instructions\n${TURN_PREFIX_SUMMARIZATION_PROMPT}`;
}

function sleep(ms: number, signal: AbortSignal): Promise<boolean> {
	if (signal.aborted) return Promise.resolve(false);
	return new Promise((resolve) => {
		const timer = setTimeout(() => settle(true), ms);
		const onAbort = () => settle(false);
		const settle = (ok: boolean) => {
			clearTimeout(timer);
			signal.removeEventListener("abort", onAbort);
			resolve(ok);
		};
		signal.addEventListener("abort", onAbort, { once: true });
	});
}

type AttemptOutcome =
	| { status: "ok"; text: string; usage: UsageLike }
	| { status: "failed"; message: string; retryable: boolean }
	| { status: "aborted" };

export default function (pi: ExtensionAPI) {
	pi.on("session_before_compact", async (event, ctx) => {
		const { preparation, customInstructions, signal } = event;

		const parsed = parseChainOverrides(process.env.PI_COMPACT_MODELS);
		const refs: ChainRef[] =
			parsed.refs.length > 0 ? parsed.refs : DEFAULT_CHAIN.map((entry) => [entry[0], entry[1]] as const);
		const { targets, warnings } = resolveChainTargets(refs, {
			find: (provider, modelId) => ctx.modelRegistry.find(provider, modelId),
			getAvailable: () => ctx.modelRegistry.getAvailable(),
			current: ctx.model,
		});
		const notices = [
			...parsed.invalid.map((entry) => `ignoring PI_COMPACT_MODELS entry "${entry}"`),
			...warnings,
		];
		if (notices.length > 0 && ctx.hasUI) {
			ctx.ui.notify(`summary-router: ${notices.join("; ")}`, "warning");
		}
		if (signal.aborted || targets.length === 0) return undefined;

		const textOf = (message: { content: ReadonlyArray<{ type: string; text?: string }> }): string =>
			message.content.filter((part) => part.type === "text").map((part) => part.text ?? "").join("\n");

		async function requestSummary(model: ChainModel, promptText: string, maxTokens: number): Promise<AttemptOutcome> {
			const watchdog = new AbortController();
			const options = {
				maxTokens: Math.min(maxTokens, model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY),
				reasoning: model.reasoning ? ("low" as const) : undefined,
				cacheRetention: "none" as const,
				sessionId: uuidv7(),
				signal: AbortSignal.any([signal, watchdog.signal]),
			};
			const startedAt = Date.now();
			let watchdogError: string | undefined;
			const fire = (message: string) => {
				if (watchdogError) return;
				watchdogError = message;
				watchdog.abort();
			};
			let timer = setTimeout(
				() => fire(`no first token within ${FIRST_LIFE_TIMEOUT_MS / 1000}s (timeout)`),
				FIRST_LIFE_TIMEOUT_MS,
			);
			try {
				const stream = ctx.modelRegistry.streamSimple(model, {
					systemPrompt: SUMMARIZATION_SYSTEM_PROMPT,
					messages: [{ role: "user", content: [{ type: "text", text: promptText }], timestamp: Date.now() }],
				}, options);
				let sawLife = false;
				for await (const streamEvent of stream) {
					if (sawLife || streamEvent.type === "start") continue;
					sawLife = true;
					clearTimeout(timer);
					timer = setTimeout(
						() => fire(`summary generation exceeded ${ATTEMPT_DEADLINE_MS / 1000}s (timeout)`),
						Math.max(0, startedAt + ATTEMPT_DEADLINE_MS - Date.now()),
					);
				}
				const message = await stream.result();
				if (signal.aborted) return { status: "aborted" };
				if (watchdogError) return { status: "failed", message: watchdogError, retryable: true };
				if (isAcceptableSummary(message)) {
					return { status: "ok", text: withoutFileTags(textOf(message)), usage: message.usage };
				}
				if (message.stopReason === "length") {
					return {
						status: "failed",
						message: `${model.provider}/${model.id}: summary hit the token cap and is incomplete`,
						retryable: false,
					};
				}
				const detail =
					message.stopReason === "error"
						? message.errorMessage || "Unknown error"
						: `unexpected stopReason "${message.stopReason}"`;
				return {
					status: "failed",
					message: `${model.provider}/${model.id}: ${detail}`,
					retryable: isRetryableFailure(message.stopReason, message.errorMessage),
				};
			} catch (error) {
				if (signal.aborted) return { status: "aborted" };
				if (watchdogError) return { status: "failed", message: watchdogError, retryable: true };
				const detail = error instanceof Error ? error.message : String(error);
				return {
					status: "failed",
					message: `${model.provider}/${model.id}: ${detail}`,
					retryable: isRetryableFailure("error", detail),
				};
			} finally {
				clearTimeout(timer);
			}
		}

		async function summarizeWithRetries(model: ChainModel, promptText: string, maxTokens: number): Promise<AttemptOutcome> {
			let last: { message: string; retryable: boolean } | undefined;
			for (let attempt = 1; attempt <= MAX_ATTEMPTS_PER_RUNG; attempt++) {
				if (signal.aborted) return { status: "aborted" };
				const outcome = await requestSummary(model, promptText, maxTokens);
				if (outcome.status !== "failed") return outcome;
				last = outcome;
				if (!outcome.retryable || attempt === MAX_ATTEMPTS_PER_RUNG) break;
				if (!(await sleep(RETRY_BACKOFF_MS, signal))) return { status: "aborted" };
			}
			return { status: "failed", message: last?.message ?? "unknown failure", retryable: false };
		}

		async function runRung(model: ChainModel): Promise<{ summary: string; usage: UsageLike } | "aborted" | undefined> {
			let summary: string;
			let usage: UsageLike | undefined;
			if (preparation.messagesToSummarize.length > 0) {
				const outcome = await summarizeWithRetries(
					model,
					buildHistoryPrompt(preparation.messagesToSummarize, preparation.previousSummary, customInstructions),
					HISTORY_MAX_TOKENS,
				);
				if (outcome.status === "aborted") return "aborted";
				if (outcome.status === "failed") {
					lastError = outcome.message;
					return undefined;
				}
				summary = outcome.text;
				usage = outcome.usage;
			} else {
				summary = preparation.previousSummary ?? "No prior history.";
			}
			if (preparation.isSplitTurn && preparation.turnPrefixMessages.length > 0) {
				const outcome = await summarizeWithRetries(model, buildTurnPrefixPrompt(preparation.turnPrefixMessages), TURN_PREFIX_MAX_TOKENS);
				if (outcome.status === "aborted") return "aborted";
				if (outcome.status === "failed") {
					lastError = outcome.message;
					return undefined;
				}
				summary = `${summary}\n\n---\n\n**Turn Context (split turn):**\n\n${outcome.text}`;
				usage = usage ? combineUsage(usage, outcome.usage) : outcome.usage;
			}
			return {
				summary,
				usage: usage ?? {
					input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
				},
			};
		}

		let lastError = "no attempt made";
		let success: { summary: string; usage: UsageLike } | undefined;
		for (const model of targets) {
			const outcome = await runRung(model);
			if (outcome === "aborted") return undefined;
			if (outcome) {
				success = outcome;
				break;
			}
		}
		if (!success) {
			if (ctx.hasUI) {
				ctx.ui.notify(`summary-router: all models failed (${lastError}) — falling back to built-in compaction`, "warning");
			}
			return undefined;
		}

		const modified = new Set<string>([
			...taggedFiles(preparation.previousSummary, "modified-files"),
			...preparation.fileOps.written,
			...preparation.fileOps.edited,
		]);
		const read = new Set<string>([
			...taggedFiles(preparation.previousSummary, "read-files"),
			...preparation.fileOps.read,
		]);
		for (const path of modified) read.delete(path);
		const readFiles = [...read].sort();
		const modifiedFiles = [...modified].sort();
		let summary = success.summary;
		if (readFiles.length > 0) summary += `\n\n<read-files>\n${readFiles.join("\n")}\n</read-files>`;
		if (modifiedFiles.length > 0) summary += `\n\n<modified-files>\n${modifiedFiles.join("\n")}\n</modified-files>`;

		return {
			compaction: {
				summary,
				firstKeptEntryId: preparation.firstKeptEntryId,
				tokensBefore: preparation.tokensBefore,
				usage: success.usage,
				details: { readFiles, modifiedFiles },
			},
		};
	});
}
