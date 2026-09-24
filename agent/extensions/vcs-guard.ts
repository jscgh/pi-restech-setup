/**
 * VCS Guard — hard gate on remote-mutating commands.
 *
 * Why an extension and not a setting: Pi has no built-in permission system
 * (docs/how-pi-works.md: tools run with the OS permissions of the Pi process),
 * and `defaultTools` is bypassed by extension and SDK tools — which includes the
 * subagents' exec/Agent tools. A `tool_call` handler is the only choke point that
 * covers subagents too, and a `tool_call` handler that *throws* blocks the tool as
 * a fail-safe, so a broken matcher fails closed rather than open.
 *
 * Policy:
 *   NEVER (blocked outright, no prompt):
 *     - writes to shell init files, ~/.pi/.env, and Pi credential/settings files
 *   CONFIRM (interactive prompt; blocked when there is no UI, e.g. RPC/CI):
 *     - git push / send-email / filter-branch / cvsexportcommit
 *     - gh, glab, hub, arc/cr mutating subcommands; `gh api -X POST|PUT|PATCH|DELETE`
 *     - npm|pnpm|yarn|deno|cargo|uv publish, twine|maturin upload,
 *       mvn|gradle|sbt deploy|release, docker|podman|oras|nerdctl push, helm push
 *     - kubectl apply|delete|…, terraform apply|destroy, helm install|upgrade|…,
 *       aws/gcloud create|delete|put|update
 *     - curl/wget performing POST/PUT/PATCH/DELETE (covers raw REST publishing)
 *   ALLOWED (local work is unimpeded):
 *     - git commit/add/status/diff/log/fetch/pull/checkout/branch/stash/rebase/
 *       reset/cherry-pick/tag/worktree/rm
 *     - read-only gh/glab (`gh pr view`, `gh issue list`, `gh api -X GET`, …)
 *     - all other bash, plus read/edit/write/grep/find/ls
 *
 * Escapes:
 *   PI_VCS_GUARD=off pi          # disable this extension entirely
 *   PI_VCS_ALLOW_PUSH=1 pi       # allow pushes without prompting (loud warning)
 *   PI_VCS_PROTECTED_FILES="…"   # extra regexes for the never-write list
 *
 * Limits: this pattern-matches command text. A wrapper script that pushes, an
 * alias, or `xargs git push` can slip through. It is a seatbelt plus a prompt,
 * not a sandbox — pair it with branch protection for anything you care about.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Match a subcommand token with explicit punctuation boundaries instead of \b.
 * \b treats `-` and `.` as word boundaries, so `\bpush\b` wrongly matched the
 * filename `git-push.md`, and `\b(create|…)\b` wrongly matched `--force-with-lease`.
 */
const tok = (w: string) => String.raw`(?<![A-Za-z0-9._-])(?:${w})(?![A-Za-z])`;

/**
 * Exactly one whitespace-delimited token, so a rule can only reach the *next* word
 * and cannot skip across unrelated arguments (`gh pr view --repo x/create` stays
 * allowed). Must be `\s+`, not `\s+\S+`: the latter consumes the subcommand word
 * itself and then fails, silently disabling every gh/glab/npm/cargo rule.
 */
const ARG = String.raw`\s+`;

/** Same-line span that stops before the next whitespace-delimited token. */
const STAY = "[^\\n;|&]*?";

type Rule = { re: RegExp; why: string };

const RULES: Rule[] = [
	// ---- git ----------------------------------------------------------------
	{ re: new RegExp(`${tok("git")}${STAY}${tok("push")}`), why: "git push writes to the remote" },
	{ re: new RegExp(`${tok("git")}${STAY}${tok("send-email")}`), why: "git send-email publishes patches" },
	{ re: new RegExp(`${tok("git")}${STAY}${tok("filter-branch")}`), why: "git filter-branch rewrites history" },
	{ re: new RegExp(`${tok("git")}${STAY}${tok("cvsexportcommit")}`), why: "git cvsexportcommit publishes" },

	// ---- GitHub / GitLab CLIs: verb must sit in its own argument slot ---------
	{
		re: new RegExp(`${tok("gh")}${ARG}${tok("pr|release|repo")}${ARG}${tok("create|merge|close|delete|edit|review|comment|publish|enable|disable|rerun")}`),
		why: "gh mutates a hosted repository",
	},
	{
		re: new RegExp(`${tok("gh")}${ARG}${tok("repo")}${ARG}${tok("sync|delete|archive|rename|clone|fork")}`),
		why: "gh repo mutates the hosted repository",
	},
	{
		re: new RegExp(`${tok("gh")}${ARG}${tok("api")}${STAY}${tok("-X|--method")}${ARG}${tok("POST|PUT|PATCH|DELETE")}`),
		why: "gh api performs a write request",
	},
	{
		// `workflow run` dispatches a build; `run cancel` stops one. Both mutate the
		// hosted repo. `view`/`list`/`watch` are deliberately absent -- read-only.
		re: new RegExp(`${tok("gh")}${ARG}${tok("workflow|run")}${ARG}${tok("run|cancel|disable|enable")}`),
		why: "gh dispatches or cancels a workflow run",
	},
	{
		re: new RegExp(`${tok("glab")}${ARG}${tok("mr|release|repo")}${ARG}${tok("create|merge|close|delete|edit|review|approve")}`),
		why: "glab mutates a hosted repository",
	},
	{
		re: new RegExp(`${tok("glab")}${ARG}${tok("api")}${STAY}${tok("-X|--method")}${ARG}${tok("POST|PUT|PATCH|DELETE")}`),
		why: "glab api performs a write request",
	},
	{ re: new RegExp(`${tok("hub")}${STAY}${tok("pull-request")}`), why: "hub opens a pull request" },
	{ re: new RegExp(`${tok("arc|cr")}${ARG}${tok("diff|land|submit")}`), why: "Phabricator/arcanist publishes a revision" },

	// ---- package / artifact publication --------------------------------------
	{ re: new RegExp(`${tok("npm|pnpm|yarn|deno")}${ARG}${tok("publish")}`), why: "package publish" },
	{ re: new RegExp(`${tok("cargo")}${ARG}${tok("publish")}`), why: "cargo publish" },
	{ re: new RegExp(`${tok("uv")}${ARG}${tok("publish")}`), why: "uv publish" },
	{ re: new RegExp(`${tok("twine|maturin")}${ARG}${tok("upload")}`), why: "artifact upload" },
	{ re: new RegExp(`${tok("mvn|mvnw|gradlew?|sbt")}${ARG}${tok("deploy")}`), why: "build publish goal" },
	{ re: new RegExp(`${tok("docker")}${ARG}${tok("push")}`), why: "docker push publishes an image" },
	{ re: new RegExp(`${tok("podman|buildah|oras|nerdctl|singularity|apptainer")}${ARG}${tok("push")}`), why: "image push" },
	{ re: new RegExp(`${tok("helm")}${ARG}${tok("push")}`), why: "chart push" },

	// ---- infrastructure writes ----------------------------------------------
	{
		re: new RegExp(`${tok("kubectl")}${ARG}${tok("apply|delete|patch|scale|rollout|drain|cordon|label|annotate")}`),
		why: "kubectl mutates a live cluster",
	},
	{ re: new RegExp(`${tok("terraform")}${ARG}${tok("apply|destroy")}`), why: "terraform mutates live infrastructure" },
	{
		re: new RegExp(`${tok("helm")}${ARG}${tok("install|upgrade|uninstall|rollback")}`),
		why: "helm mutates a live cluster",
	},
	{ re: new RegExp(`${tok("aws")}${ARG}\\w+${tok("create|delete|put|update")}-?\\w+`), why: "aws CLI mutates infrastructure" },
	{ re: new RegExp(`${tok("gcloud")}${ARG}\\S+`), why: "gcloud subcommand — review before allowing" },

	// ---- raw HTTP writes -----------------------------------------------------
	{
		re: new RegExp(`${tok("curl")}${STAY}${tok("-X|--request")}${ARG}${tok("POST|PUT|PATCH|DELETE")}`),
		why: "HTTP write request",
	},
	{ re: new RegExp(`${tok("curl")}${STAY}${tok("--upload-file|-T")}`), why: "HTTP upload" },
	{
		re: new RegExp(`${tok("wget")}${STAY}${tok("--post-data|--post-file|--method")}`),
		why: "HTTP write request",
	},
];

/** Files whose compromise defeats the guard itself — never written, not even with a "yes". */
const PROTECTED_FILE_DEFAULTS = [
	"(^|/)[.]bashrc$",
	"(^|/)[.]zshrc$",
	"(^|/)[.]profile$",
	"(^|/)[.]bash_profile$",
	"(^|/)[.]zshenv$",
	"(^|/[.]pi/)[.]env$",
	"(^|/)[.]pi/agent/settings[.]json$",
	"(^|/)[.]pi/agent/auth[.]json$",
	"(^|/)[.]pi/agent/models[.]json$",
	"(^|/)[.]pi/agent/extensions/",
	"(^|/)[.]git-credentials$",
	"(^|/)[.]ssh/",
];

export default function (pi: ExtensionAPI) {
	if ((process.env.PI_VCS_GUARD ?? "").toLowerCase() === "off") return;

	if (process.env.PI_VCS_ALLOW_PUSH === "1") {
		pi.on("session_start", async (_event, ctx) => {
			ctx.ui.notify("vcs-guard: DISABLED via PI_VCS_ALLOW_PUSH=1 — remote writes will not be checked", "warning");
		});
		return;
	}

	const protectedFiles = (process.env.PI_VCS_PROTECTED_FILES ? process.env.PI_VCS_PROTECTED_FILES.split(",") : PROTECTED_FILE_DEFAULTS)
		.map((src) => new RegExp(src));

	const shellTools = new Set(["bash", "exec", "shell", "run_command"]);

	pi.on("tool_call", async (event, ctx) => {
		const tool = event.toolName.toLowerCase();

		if (shellTools.has(tool)) {
			const command = String(event.input.command ?? event.input.cmd ?? "");
			for (const rule of RULES) {
				if (rule.re.test(command)) {
					return await ask(ctx, `${rule.why}\n\n  ${command.slice(0, 400)}`);
				}
			}
			return undefined;
		}

		if (tool === "edit" || tool === "write" || tool === "multiedit" || tool === "notebookedit") {
			const path = String(event.input.path ?? event.input.notebook_path ?? "");
			if (protectedFiles.some((re) => re.test(path))) {
				return {
					block: true,
						reason:
						`vcs-guard: "${path}" is protected (editing it could weaken this guard or leak credentials). ` +
						`Ask the user to edit it directly, or run pi with PI_VCS_GUARD=off.`,
				};
			}
		}
		return undefined;
	});
}

async function ask(ctx: Parameters<Parameters<ExtensionAPI["on"]>[1]>[1], prompt: string) {
	if (!ctx.hasUI) {
		return { block: true, reason: `vcs-guard: blocked (${prompt.split("\n")[0]}); no UI to request approval` };
	}
	const choice = await ctx.ui.select(`⚠️ Remote write requested\n\n${prompt}\n\nAllow this once?`, [
		"No — block it",
		"Yes — allow once",
	]);
	if (choice !== "Yes — allow once") {
		return { block: true, reason: `vcs-guard: user declined (${prompt.split("\n")[0]})` };
	}
	ctx.ui.notify("vcs-guard: allowed once", "info");
	return undefined;
}
