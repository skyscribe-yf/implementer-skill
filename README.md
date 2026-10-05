# implementer

An agent skill for implementing a feature or bugfix behind a self-contained subagent: it plans the
work, fans out lanes, runs a five-angle review, loops on fixes, and gates the result on CI.

[`SKILL.md`](SKILL.md) is the skill itself — that is what your agent reads, and it is the file to
install. This README explains what the skill enforces and why.

The defining constraint is that the orchestrator does not write code. It plans, dispatches, audits
scope, and merges — but implementation happens in workers whose verification is explicitly scoped so
they cannot quietly run a full regression suite.

## Install

The skill directory is the unit of installation. Copy it wherever your agent looks for skills:

```bash
# Claude Code
cp -r implementer ~/.claude/skills/implementer

# Pi
cp -r implementer ~/.pi/agents/skills/implementer

# or a project-local copy
cp -r implementer .claude/skills/implementer
```

## What it enforces

**An exclusive lock, first thing.** A `.pi-implementer.lock` claim under the pool anchor, taken
before any work and released on every exit path. Without it two implementers interleave on one
repository.

**A verification scope contract in every dispatch.** Workers see only their prompt plus the
repository's `AGENTS.md`, and `AGENTS.md` tells every agent to run the full pre-push checklist. A
dispatch without an explicit contract ends up running full-suite regression inside a lane that was
asked to implement code. Measured on real child runs over 30 days: 15 sessions ran `react-doctor`,
18 ran browser scripts, 1 ran a full build — every one because nobody told them not to. The contract
whitelists
what a lane may run and names the forbidden commands explicitly.

**Lane scope auditing.** Every subagent report must end with `Checks run:` and `Deferred gates:`.
A missing line is itself a violation. Each deferred gate resolves to exactly one of: CI owns it,
the orchestrator runs it, or it is recorded as residual risk. A gate nobody claims is the failure
mode this contract can create, and it lands as a red PR the orchestrator still owns.

**Five review angles, in parallel.** Correctness and regressions, tests and validation, simplicity
and maintainability, security and privacy, contracts and project compliance — each a fresh
read-only reviewer, each required to cite `file:line` and forbidden from running anything.

**Mergability preflight.** A conflicting PR has no buildable merge ref, so GitHub never starts its
workflows and `gh pr checks` reports "no checks" forever. That is a conflict signature, not an
outage. The skill rebase-firsts its own head branch (`--force-with-lease`, never `--force`, never
`master`/`main`) instead of reporting it as progress or escalating.

## The worktree pool

Concurrent lanes need isolated working trees, and a fresh worktree costs a checkout plus a full
dependency bootstrap — around 145 MB on a typical web + Python repo. Reusing one keeps its ignored
`node_modules` and `.venv` in place, so the dependency step becomes a no-op.

The pool anchors on the repository's shared git directory rather than the working directory:

```
<repo>/.git/wt-pool/
├── pool/
│   ├── lane-a/            ← a worktree, kept warm across runs
│   └── lane-b/
└── locks/
    ├── lane-a.lock/claim  ← atomic claim; the directory is the lock
    └── lane-b.lock/
```

That anchor choice is what makes reuse work under a harness. Anything keyed to `$PWD` dies with the
session — and a lock written there is invisible to the next run, so two implementers collide while a
stale lock is never seen again. The shared git dir resolves to one path for the main checkout and
every worktree of that repo, and differs between unrelated clones, so reuse and isolation both hold.

| Script | Purpose |
| --- | --- |
| `pool-take.sh <slot> <task>` | Atomically claim a slot. Prints its path on stdout. |
| `pool-release.sh <slot>` | Release the slot's lock. Idempotent. |
| `wt-pool.sh <branch> [base]` | Create-or-reuse a worktree. `--print` skips reset and bootstrap. |
| `wt-anchor.sh` | Resolves the anchor. Source it; do not execute. |
| `wt-migrate-anchor.sh` | One-time move from an older `<toplevel>/.worktrees/pool/` layout. |

```bash
POOL="$HOME/.claude/skills/implementer"
slot=$("$POOL/pool-take.sh" lane-a "implement issue 1234")
# hand $slot to the worker as its working directory
"$POOL/pool-release.sh" lane-a
```

`pool-take.sh` exit codes: `0` claimed, `2` held, `3` dirty or creation failed, `4` the slot you
asked for is the one you are standing in. Over-capacity is not an error — the run proceeds where it
already is. No queue, no blocking wait.

Slots are flat siblings, never nested. A run inside `lane-a` that needs its own lane gets a
different slot; asking for the one you occupy is refused, because two lanes writing one directory
is how duplicate-writer incidents start.

Verify the scripts in isolation:

```bash
./wt-pool.sh --self-test
```

## Pairing with Paseo

[`paseo-plugin-warm-pool`](https://github.com/skyscribe-yf/paseo-plugin-warm-pool) applies the same
protocol from inside Paseo: it redirects new worktree workspaces onto these slots so their
dependency trees are reused instead of reinstalled per run. Point it at this directory with
`WARM_POOL_SCRIPTS`.

Both draw from the same pool, so an implementer lane and a Paseo workspace never collide on a slot
name.

## Notes

- **Never `mv` a slot.** Git tracks a worktree in two places at once, and `git worktree repair` does
  not fix a moved worktree — relocated slots turn `prunable` and branch lookups start returning the
  abandoned path. Use `wt-migrate-anchor.sh`.
- **Never `git clean -fdx`** inside a worktree. `-x` deletes the ignored trees reuse depends on.
  Use `-fd`.
- **Do not remove a slot after merging.** Deleting it is exactly what forces the next task to pay
  the full bootstrap again. Prune only when the branch is done and the slot is past its retention
  window.

## License

MIT