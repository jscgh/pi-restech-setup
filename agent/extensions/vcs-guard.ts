import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const tok = (w: string) => String.raw`(?<![A-Za-z0-9._-])(?:${w})(?![A-Za-z])`;

const ARG = String.raw`\s+`;

const STAY = "[^\\n;|&]*?";

type Rule = { re: RegExp; why: string };

const RULES: Rule[] = [
	{ re: new RegExp(`${tok("git")}${ARG}${tok("push")}`), why: "git push writes to the remote" },
	{ re: new RegExp(`${tok("git")}${STAY}${tok("send-email")}`), why: "git send-email publishes patches" },
	{ re: new RegExp(`${tok("git")}${STAY}${tok("filter-branch")}`), why: "git filter-branch rewrites history" },
	{ re: new RegExp(`${tok("git")}${STAY}${tok("cvsexportcommit")}`), why: "git cvsexportcommit publishes" },

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

	{ re: new RegExp(`${tok("npm|pnpm|yarn|deno")}${ARG}${tok("publish")}`), why: "package publish" },
	{ re: new RegExp(`${tok("cargo")}${ARG}${tok("publish")}`), why: "cargo publish" },
	{ re: new RegExp(`${tok("uv")}${ARG}${tok("publish")}`), why: "uv publish" },
	{ re: new RegExp(`${tok("twine|maturin")}${ARG}${tok("upload")}`), why: "artifact upload" },
	{ re: new RegExp(`${tok("mvn|mvnw|gradle|gradlew|sbt")}${STAY}${tok("deploy|publish|uploadArchives")}`), why: "build publish goal" },
	{ re: new RegExp(`${tok("docker")}${ARG}${tok("push")}`), why: "docker push publishes an image" },
	{ re: new RegExp(`${tok("podman|buildah|oras|nerdctl|singularity|apptainer")}${ARG}${tok("push")}`), why: "image push" },
	{ re: new RegExp(`${tok("helm")}${ARG}${tok("push")}`), why: "chart push" },

	{
		re: new RegExp(`${tok("kubectl")}${ARG}${tok("apply|delete|patch|scale|rollout|drain|cordon|label|annotate")}`),
		why: "kubectl mutates a live cluster",
	},
	{ re: new RegExp(`${tok("terraform")}${ARG}${tok("apply|destroy")}`), why: "terraform mutates live infrastructure" },
	{
		re: new RegExp(`${tok("helm")}${ARG}${tok("install|upgrade|uninstall|rollback")}`),
		why: "helm mutates a live cluster",
	},
	{
		re: new RegExp(`${tok("aws")}${STAY}${tok("(?:create|delete|put|update|modify|terminate|run|start|stop|reboot|attach|detach|associate|disassociate|authorize|revoke|register|deregister|enable|disable|tag|untag|set|reset|restore|import|deploy|copy|upload|complete|abort)(?:-[A-Za-z0-9]+)*")}`),
		why: "aws CLI mutates infrastructure",
	},
	{ re: new RegExp(`${tok("aws")}${STAY}${tok("s3")}${ARG}${tok("cp|mv|rm|sync|website")}`), why: "aws s3 writes or deletes objects" },
	{
		re: new RegExp(`${tok("gcloud")}${STAY}${tok("create|delete|update|deploy|submit|cancel|start|stop|reset|resize|move|restore|import|add-iam-policy-binding|remove-iam-policy-binding|set-iam-policy")}`),
		why: "gcloud mutates infrastructure",
	},
	{ re: new RegExp(`${tok("gcloud")}${STAY}${tok("storage")}${ARG}${tok("cp|mv|rm|rsync")}`), why: "gcloud storage writes or deletes objects" },

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

	const shellTools = new Set(["bash", "powershell", "exec", "shell", "run_command"]);

	pi.on("tool_call", async (event, ctx) => {
		const tool = event.toolName.toLowerCase();

		if (shellTools.has(tool)) {
			const command = String(inputField(event.input, "command") ?? inputField(event.input, "cmd") ?? "");
			for (const rule of RULES) {
				if (rule.re.test(command)) {
					return await ask(ctx, `${rule.why}\n\n  ${command.slice(0, 400)}`);
				}
			}
			return undefined;
		}

		if (tool === "edit" || tool === "write") {
			const path = String(inputField(event.input, "path") ?? inputField(event.input, "notebook_path") ?? "");
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

function inputField(input: unknown, name: string): unknown {
	return typeof input === "object" && input !== null ? (input as Record<string, unknown>)[name] : undefined;
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
