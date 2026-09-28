# Katana jobs and GPU execution

Use this reference when selecting compute jobs or running GPU tests. For personal allocations, paths, and tmux session names, also read `~/.pi/agent/references/katana-personal.md` when it exists.

## Inspect resources

```bash
qstat -u "$USER"
qstat -f <jobid>
pstat -g
```

`qstat -f` provides the full job ID, queue, resources, walltime, and `exec_host`. `pstat -g` shows GPU models and CPU/RAM per GPU. Prefer live results over remembered limits.

Current queue and GPU limits are documented in [Running Jobs on Katana](https://docs.restech.unsw.edu.au/using_katana/running_jobs/#job-queue-limits-summary).

## Connect to an allocated node

```bash
env PBS_JOBID=<full-job-id> ssh <exec-node> '<command>'
```

The job ID must be set on the client side. Compute nodes may reject SSH without it.

A non-interactive SSH command does not source the PBS environment, so `$TMPDIR` may be unset. Use the allocation's job-local `/scratch/pbs.<jobid>` directory after verifying it exists; do not fall back to GPFS scratch for temporary work.

## Test execution

Reuse a suitable allocation. GPU tests require a compatible GPU allocation. Preserve only required logs, summaries, and evidence on GPFS.
