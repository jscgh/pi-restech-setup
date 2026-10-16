#!/usr/bin/env node
/**
 * Test harness for agent/extensions/vcs-guard.ts
 *
 * Pi loads extensions with jiti, so this extracts the RULES/protected-path
 * tables straight out of the TypeScript source and evaluates them -- no build
 * step, and the test can never drift from the shipped file.
 *
 *   node tests/vcs-guard.test.cjs          # run
 *   node --test tests/                     # via the node test runner
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const EXT = path.join(__dirname, '..', 'agent', 'extensions', 'vcs-guard.ts');
const source = fs.readFileSync(EXT, 'utf8');

/** Slice out a top-level table and drop the type annotations. */
function extract(startMarker, endMarker) {
	const start = source.indexOf(startMarker);
	const end = source.indexOf(endMarker, start);
	assert.ok(start !== -1, `start marker not found: ${startMarker}`);
	assert.ok(end !== -1, `end marker not found: ${endMarker}`);
	return source
		.slice(start, end)
		.replace(/\(w: string\)/g, '(w)')
		.replace(/: Rule\[\]/g, '')
		.replace(/^type Rule = .*$/gm, '');
}

function loadInContext(names) {
	const code = [
		extract('const tok =', '// These files cannot be written'),
		extract('// These files cannot be written', 'export default'),
	].join('\n');
	const exported = names.map((n) => `exports.${n} = ${n};`).join('\n');
	const box = {};
	new Function('exports', `${code}\n${exported}`)(box);
	return box;
}

const { RULES, PROTECTED_FILE_DEFAULTS } = loadInContext(['RULES', 'PROTECTED_FILE_DEFAULTS']);

const PROTECTED = PROTECTED_FILE_DEFAULTS.map((s) => new RegExp(s));

/** A remote write is flagged if any rule matches. */
const flagsRemoteWrite = (cmd) => RULES.some((r) => r.re.test(cmd));
const touchesProtectedFile = (p) => PROTECTED.some((re) => re.test(p));

// ---------------------------------------------------------------------------
// Cases. `push` = must be flagged for approval.
// `commit` and friends must NEVER be flagged: this is the regression that
// motivated the whole suite (ARG was once `\s+\S+`, which consumed the
// subcommand word and silently disabled every gh/glab/npm/cargo rule).
// ---------------------------------------------------------------------------

const MUST_FLAG = [
	'git push origin main',
	'cd ~/repo && git push',
	'git push --force-with-lease',
	'git push -u origin feature/x',
	'git commit -am tidy && git push',
	'GIT_SSH_COMMAND=ssh git push',
	'git push --tags',
	'git send-email --to x@y',
	'git filter-branch --all',
	'gh pr create --title x',
	'gh pr merge 123',
	'gh pr close 4',
	'gh release create v1.0.0',
	'gh api /repos/o/r/issues -X POST -f t=1',
	'gh workflow run ci.yml',
	'glab mr create',
	'glab mr merge 5',
	'hub pull-request',
	'arc diff',
	'cr submit',
	'npm publish --access public',
	'pnpm publish',
	'cargo publish',
	'twine upload dist/*',
	'uv publish',
	'mvn deploy',
	'./gradlew deploy',
	'docker push reg/img:tag',
	'podman push quay.io/o/i',
	'helm push chart.tgz oci://x',
	'helm upgrade rel .',
	'kubectl apply -f deploy.yaml',
	'kubectl delete pod web-1',
	'terraform apply -auto-approve',
	'terraform destroy',
	'curl -X PATCH https://api.github.com/repos/o/r',
	'curl --request PUT https://api.example.com/x',
	'curl --upload-file a.txt https://x',
	'wget --post-data=a=b https://x',
];

const MUST_NOT_FLAG = [
	// git local workflow -- the point of the guard is to leave these alone
	'git status',
	'git commit -m "fix: off-by-one"',
	'git add -A && git commit -m x',
	'git diff HEAD',
	'git log --oneline -20',
	'git fetch origin',
	'git pull --ff-only',
	'git checkout -b feature/create-thing',
	'git branch -d old-topic',
	'git stash && git stash pop',
	'git stash push -m checkpoint',
	'git rebase -i HEAD~3',
	'git reset --soft HEAD~1',
	'git cherry-pick abc123',
	'git tag -a v1.0.0 -m msg',
	'git worktree add ../wt',
	'git rm --cached secret.txt',
	// read-only host CLIs
	'gh pr view 123',
	'gh pr list --state open',
	'gh issue list --state open',
	'gh api /repos/o/r/commits -X GET',
	'gh repo view',
	'glab mr list',
	'glab mr view 5',
	// ordinary dev commands
	'npm test',
	'npm install lodash',
	'npm run build',
	'cargo build --release',
	'cargo test',
	'mvn -q compile',
	'./gradlew test',
	'kubectl get pods',
	'kubectl logs deploy/web',
	'terraform plan',
	'terraform fmt',
	'helm list',
	'helm template rel .',
	'docker build -t img .',
	'docker run --rm img',
	'curl -s https://api.github.com/repos/o/r',
	'wget -qO- https://example.com/page.html',
	// word-boundary traps: substring matches must not fire
	'git pushg remote',
	'cat notes/git-push.md',
	'echo pushing forward',
	'grep -rn create src/',
	'sed -i s/foo/bar/ deploy.yaml',
	'python3 train.py',
	'ls -la',
	'node dist/index.js',
];

test('remote-write commands are flagged', () => {
	for (const cmd of MUST_FLAG) {
		assert.ok(flagsRemoteWrite(cmd), `expected BLOCK for: ${cmd}`);
	}
});

test('local work is not flagged', () => {
	for (const cmd of MUST_NOT_FLAG) {
		assert.ok(!flagsRemoteWrite(cmd), `expected ALLOW for: ${cmd}`);
	}
});

test('guard config files are protected from edit/write', () => {
	for (const p of ['~/.bashrc', '/home/u/.pi/agent/settings.json', '/home/u/.pi/agent/models.json', '/home/u/.pi/.env', '~/.ssh/id_ed25519', '.git-credentials']) {
		assert.ok(touchesProtectedFile(p), `expected BLOCK for: ${p}`);
	}
	for (const p of ['src/main.ts', 'README.md', 'docs/git-push.md', 'src/settings.json', 'package.json']) {
		assert.ok(!touchesProtectedFile(p), `expected ALLOW for: ${p}`);
	}
});

test('rules are well-formed regexes with a reason', () => {
	assert.ok(RULES.length >= 25, `expected a broad rule table, got ${RULES.length}`);
	for (const r of RULES) {
		assert.ok(r.re instanceof RegExp, `not a RegExp: ${r.why}`);
		assert.ok(r.why && r.why.length > 5, `rule missing why: ${r.re.source}`);
	}
});

if (require.main === module) {
	const flagged = MUST_FLAG.filter(flagsRemoteWrite).length;
	const cleared = MUST_NOT_FLAG.filter((c) => !flagsRemoteWrite(c)).length;
	console.log(`vcs-guard: ${flagged}/${MUST_FLAG.length} blocks, ${cleared}/${MUST_NOT_FLAG.length} allows`);
}
