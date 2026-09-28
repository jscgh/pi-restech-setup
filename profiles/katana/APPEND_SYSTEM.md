<!-- pi-restech-setup profile: katana -->
# Katana HPC

- GPFS is large and slow: keep searches, scans, and indexing repository-scoped. Never run broad `find`, `grep`, `du`, or recursive tooling from unscoped paths such as `$HOME` or `/srv/scratch`.
- Never use `/tmp` on Katana. Temporary and intermediate data belongs under `$TMPDIR`, which is available inside compute jobs and is local to that job. If `$TMPDIR` is unset, move the work into a compute allocation or choose an explicitly scoped persistent location.
- Keep heavy computation off login nodes. Use compute jobs; inspect resources with `pstat` (`pstat -g` shows CPU/RAM per GPU).
- Request realistic resources and walltime. Shorter jobs generally schedule sooner, while oversized requests restrict eligible queues.
- Split long jobs when practical, and never submit a new allocation while an existing suitable allocation covers the work (see `/nf-test-lanes`).
- Scheduler mutations (`qsub`, `qdel`/`pbsdel`, `scancel`, `pbs submit`) affect shared state and require explicit approval.
- For live allocations, queue details, compute-node access, and job-local storage, read `~/.pi/agent/references/katana-jobs.md`. When present, `~/.pi/agent/references/katana-personal.md` contains user-specific paths and tmux sessions.
