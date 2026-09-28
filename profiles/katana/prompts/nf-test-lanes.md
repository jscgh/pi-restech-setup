---
description: Run nf-test suites in parallel on Katana allocations
argument-hint: "[optional: test paths or nf-test tags]"
---

Run the requested nf-test scope for the current repository in parallel background lanes: $@

1. Read the repository's `AGENTS.md` and `~/.pi/agent/references/katana-jobs.md`. If `~/.pi/agent/references/katana-personal.md` exists, read it for personal paths and GPU sessions.
2. Inventory matching pipeline, module, and subworkflow tests. Classify them as stub-only, real CPU, or GPU tests, and restrict the scope when paths or tags were supplied.
3. Inspect existing allocations with `qstat -u $USER` and obtain queue, node, resource, and walltime details with `qstat -f <jobid>`. Use an allocation only when those resources suit the requested work, and prefer it over requesting another. Scheduler mutations require explicit approval.
4. Enter allocated nodes as documented in `katana-jobs.md`; the PBS job ID must be set on the client side. Stop and ask if allocation access fails.
5. Use `$TMPDIR` in an interactive allocation or the verified `/scratch/pbs.<jobid>` directory for non-interactive SSH. Give every lane a distinct `NFT_WORKDIR`; never use `/tmp` or share work directories.
6. Run long lanes in background subagents so the main thread remains responsive. Use three to five CPU lanes where useful and one GPU lane per GPU.
7. For real tests, use the local test database documented by the repository or optional `katana-personal.md`, and verify it exists. Never allow an undeclared network-data fallback. Do not set `test_nostub` globally when that would also disable stubbing for pipeline tests.
8. Let test files select their profiles unless the repository instructions say otherwise. Use verbose output, treat "No tests to execute" as a discovery failure, and update snapshots only when explicitly requested.
9. While lanes run, execute the repository's normal lint or pre-commit command on changed files.
10. Report each lane's result, failing test names and first useful error, lint status, and anything not run. Remove only temporary outputs created by this run. Do not modify or commit repository files.

Run scientific validation only when explicitly requested and follow the repository's documented invocation exactly.
