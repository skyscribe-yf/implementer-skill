---
name: implementer
description: Use when implementing a feature or bugfix that requires a self-contained subagent with review-fix loops, CI-gated PR creation, and multi-lane parallel work
disable-model-invocation: true
---

# Implementer Subagent Workflow

## Overview
Self-contained implementation subagent with review-fix loop and CI-gated PR creation. Implements a task, runs a parallel five-angle review (correctness & regressions, tests & validation, simplicity & maintainability, security & privacy, contracts & project compliance), delegates fixes to worker subagents, creates a PR, and loops on CI failures until green or max retries.

## When to Use
- Medium-to-large feature implementation requiring structured review
- Multi-lane parallel work that needs integration
- Changes requiring CI-gated PR creation
- Tasks where the orchestrator should NOT write code itself

## When NOT to Use
- Pure investigation or documentation tasks
- Trivial one-line fixes
- Tasks where the main agent can complete faster than the dispatch overhead

---

## Absolute Local Verification Policy

This policy applies to the implementer, every implementation/fix worker, and every reviewer
while working in a local checkout. It is an absolute prohibition, not a default or a suggestion:

- **NEVER run a full test or regression suite locally.** This includes full backend/frontend
  suites, directory or glob test runs, builds or graded test aliases, and any local fallback
  intended to replace CI when CI is unavailable.
- **NEVER pull, build, start, or use a local container.** Do not invoke Docker, Docker Compose,
  Podman, Testcontainers, or scripts that do so; do not pull images or connect tests to a local
  container.
- **NEVER run database-dependent tests locally.** This includes tests, fixtures, migrations,
  integration checks, or scripts that require PostgreSQL, MySQL, SQLite, Redis, or another
  database/service. If a check's database/container requirement is uncertain, treat it as
  forbidden and defer it to CI.
- Targeted checks are allowed only when they are demonstrably database-free and
  container-free. Record deferred database/container/full-regression checks with their exact
  command; CI owns them.

These prohibitions remain in force during review-fix rounds and when CI is unreachable.

---

## ABSOLUTE FIRST ACTION — EXCLUSIVE LOCK GATE

**STOP. Do not proceed until this gate passes.**

### Resolve the lock path first

The lock lives under the **git-common-dir anchor**, NOT in the working directory.
Never hardcode `.pi-implementer.lock` relative to `$PWD`: when the harness runs you
inside a per-session worktree (Paseo puts every agent in a fresh
`~/.paseo/worktrees/<hash>/<slug>`), a `$PWD`-relative lock is created inside a
directory that is thrown away afterwards — the next run sees no lock, and two
implementers on the same repo happily collide. Resolve it once:

```bash
POOL_SCRIPTS="$HOME/.agents/skills/implementer"
. "$POOL_SCRIPTS/wt-anchor.sh"
wt_ensure_dirs
LOCK="$(wt_lock_file implementer)"     # <git-common-dir>/wt-pool/locks/implementer.lock
```

This makes the lock **per git project**: the main checkout and every worktree of
that repo share it; two unrelated repos never see each other. Set
`WT_ANCHOR_DISABLE=1` to fall back to the legacy `<toplevel>/.worktrees` layout.

### Check for an existing lock

```bash
if [ -f "$LOCK" ]; then
  echo "LOCK EXISTS"
  cat "$LOCK"
else
  echo "NO LOCK"
fi
```

Do **not** gate on PID liveness. The shell that wrote `pid=$$` is short-lived, so
`ps -p` reports "dead" within seconds and every lock looks stealable — that is how
this lock became decorative. Judge staleness by **age** (`POOL_STALE_SEC`,
default 6h), the same rule `pool-take.sh` already uses.

**If lock exists and is younger than `POOL_STALE_SEC`:**
- Report `Status: BLOCKED` immediately:
  > "Another implementer holds the lock for this repo (see `$LOCK`, claimed <age> ago). Wait for it to finish, or start on a different repo."
- Do NOT proceed. Do NOT remove the active lock.

**If lock exists but is older than `POOL_STALE_SEC`:**
- Report `Status: BLOCKED`:
  > "Stale implementer lock found at `$LOCK` (claimed <age> ago; owner process is gone). Lock details: `<contents>`. Ask the user whether to remove and re-dispatch, or abort."
- Use `AskUserQuestion` to confirm removal before proceeding.

**If no lock exists:** Create your own — `mkdir` so acquisition is atomic against
a concurrent starter:

```bash
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "RACE: 另一个 implementer 刚抢到锁" >&2; exit 2
fi
cat > "$LOCK/claim" <<EOF
pid=$$
branch=$(git branch --show-current)
timestamp=$(date -Iseconds)
task=<brief task description>
EOF
```

Nothing needs a `.gitignore` entry: the lock sits inside `.git/`, which git never
tracks or syncs.

**Immediately after acquiring the lock, mark any linked issue/PR as in-progress** so other agents do not pick up the same work:

```bash
ISSUE_NUM=$(git branch --show-current | grep -oP '\d{2,}' | head -1)
if [ -z "$ISSUE_NUM" ]; then
  ISSUE_NUM=$(grep '^task=' "$LOCK/claim" | grep -oP '\d{2,}' | head -1)
fi
if [ -n "$ISSUE_NUM" ]; then
  if gh issue view "$ISSUE_NUM" >/dev/null 2>&1; then
    gh issue edit "$ISSUE_NUM" --add-label "inprogress" 2>/dev/null \
      && echo "✓ Marked issue #$ISSUE_NUM as inprogress" \
      || echo "⚠ Could not label issue #$ISSUE_NUM"
  elif gh pr view "$ISSUE_NUM" >/dev/null 2>&1; then
    gh pr edit "$ISSUE_NUM" --add-label "inprogress" 2>/dev/null \
      && echo "✓ Marked PR #$ISSUE_NUM as inprogress" \
      || echo "⚠ Could not label PR #$ISSUE_NUM"
  else
    echo "⚠ Could not find issue/PR #$ISSUE_NUM"
  fi
fi
```

**Lock cleanup (MANDATORY):** Remove the lock before reporting — regardless of outcome.

```bash
rm -rf "$LOCK"     # $LOCK from the gate above: <git-common-dir>/wt-pool/locks/implementer.lock
```

---

## Hard Constraints

- 🚫 NEVER cherry-pick commits into master/main
- 🚫 NEVER modify master/main directly
- 🚫 NEVER leave partial work for the orchestrator to finish
- 🚫 NEVER attempt *cross-branch* integration in the orchestrator session (merge lane branches, cherry-pick, resolve another agent's PR)
- ✅ ALWAYS keep **your own PR branch** current with its base. A `CONFLICTING`/`DIRTY`/`BEHIND` PR has no buildable merge ref, so GitHub never starts the PR workflows and `gh pr checks` reports "no checks" or stays pending forever — waiting on that is a stall, not patience. Rebasing your own head branch onto the latest base and `git push --force-with-lease origin HEAD:<head>` is pre-authorized (see the Mergeability Preflight in Phase 3). Never master/main, never another agent's branch, never plain `--force`.
- 🚫 NEVER start Phase 2 (review) while any implementation lane is pending
- 🚫 NEVER report DONE without confirming CI is green
- 🚫 NEVER launch multiple implementer instances for lanes of the same feature. Use ONE implementer that fans out `Agent` subagents internally
- 🚫 NEVER overtake subagent work — if an `Agent` is running, do NOT edit code yourself
- 🚫 NEVER poll subagents in a loop. Dispatch with `run_in_background=true`, wait for automatic completion notification, or use ONE `TaskOutput` check after expected duration
- 🚫 NEVER start without acquiring the lock first
- 🚫 NEVER write any lock file relative to `$PWD` — harness-managed worktree directories are
  discarded after the run, so a `$PWD` lock is invisible to every later run. Always resolve it
  through `wt-anchor.sh` (`wt_lock_file`).
- 🚫 NEVER judge lock staleness by PID liveness — orchestrator shells are short-lived, so every
  lock looks dead immediately. Use age (`POOL_STALE_SEC`).
- 🚫 NEVER forget lock cleanup
- 🚫 NEVER dispatch a lane, fix-worker, or reviewer without the Verification Scope Contract embedded verbatim in the prompt. Subagents cannot read this skill: with no contract they fall back to the project's AGENTS.md pre-push checklist and run it.
- 🚫 NEVER let any local participant run full-suite verification (full `pytest`, full frontend test suite, `build`, `react-doctor`, Playwright/browser scripts, smoke runs, contract-verification skills), pull/start/use a local container, or run a database-dependent test. Full regression and database/container-backed checks belong to CI; local work is limited to small-scoped, database-free, container-free gates.

---

## Verification Scope Contract (embed in EVERY subagent dispatch)

Subagents see only your prompt plus the repository's `AGENTS.md`. `AGENTS.md` tells every agent to run the full pre-push checklist for any backend/frontend change, and verification-discipline skills say "run the FULL command" — so **a dispatch without an explicit contract ends in full frontend/backend regression inside a lane that was asked to implement code.** Measured on real child runs over 30 days: 15 child sessions executed `react-doctor`, 18 executed browser/chromium scripts, 1 executed `npm run build`.

### Lane / fix-worker scope block (paste verbatim, do not summarize)

```
## Verification Scope (contract — overrides the repo AGENTS.md pre-push COMMAND list for this task)
You are a child in an implementer run, not the PR owner. The implementer runs the small-scoped
pre-PR gate (fast gates + targeted tests) and drives CI to green; CI is the DETECTOR of full
regression, not a waiver. Nothing here excuses a red PR.

This contract scopes COMMANDS ONLY. It never waives design, audit, privacy, i18n, or
cross-client contract obligations. A missing required artifact (TS type not synced, i18n key
missing, audit record absent) is still a defect.

ALLOWED is a whitelist: anything not listed is not allowed. Nested forbidden commands stay
forbidden when reached through an alias or chain (a `check:frontend` script chains
typecheck && lint && test && build — running it runs forbidden members).

ALLOWED here:
- reading code; editing only the files in scope; committing
- installing the dependencies your allowed commands need — a worktree lane cannot run its
  allowed tests without it
- fast gates on the paths you changed: lint, format, typecheck — scoped to those paths
  (typecheck is inherently whole-project — that is fine; format/lint/check gates are not)
- read-only artifact verifiers for obligations this contract does not waive
  (e.g. an i18n key check, an import/compile smoke of the package you changed)
- targeted tests you name by file, run with the repo package manager, only when they are
  demonstrably database-free and container-free

FORBIDDEN here — do not run these even if AGENTS.md, a skill, or your own instinct says to:
- full suites: bare `pytest`, `pytest -n` / `--dist`, a directory or glob of tests
  (`pytest tests/unit/`), full frontend `test`, or any alias script that chains them
- app-wide audits that merely live in one file (`test:a11y`, page sweeps) and anything else
  that boots the whole project — "one file" is not the test; "only what my diff touches" is
- builds and graded checks: `build`, `react-doctor`, or the equivalent for your stack
- any Docker/Podman/Testcontainers command, image pull/build, compose command, or script that
  starts or connects to a local container
- any database-dependent test, fixture, migration, integration check, or service-backed script
  (including PostgreSQL, MySQL, SQLite, Redis, or an equivalent datastore)
- whole-repo writes or scans outside your scope (`ruff format app/`, `eslint .`)
- browser / e2e / smoke: Playwright, chromium or node harnesses, staging or production checks
- project verification skills (contract checks, browser page verification)
- scratch reproduction harnesses — writing and running your own scripts

If you think a forbidden check is genuinely required (e.g. the diff changes an API contract or
needs a database fixture),
do NOT run it and do NOT silently ship it unverified. Report it under deferred gates with the
exact command, then finish your lane report. Do not self-authorize.

If your lane's file list cannot hold an obligation you must not waive (a second locale file,
a mobile client model, a TS type), STOP and ask the implementer to widen the scope. Do not
pick one side and do not silently skip the obligation.

MINIMUM (not optional) — this is a floor, not a menu:
- run the fast gates above on the paths you changed, and targeted tests for what you changed only
  when they are database-free and container-free
- if you ran none of them, say so explicitly in `Checks run:` and why — silence is a violation

MANDATORY final lines of your report:
Checks run: <exact commands you executed — "none" only with a stated reason>
Deferred gates: <for each: exact command the implementer must run + why it matters; or "none">
```

### Reviewer scope block (read-only — paste verbatim)

```
## Reviewer Scope (read-only, no execution)
Evidence for your findings = the diff, not a local re-run of CI.
- ALLOWED: reading files, `git diff` / `git log` / `git show`, grep, `gh pr checks`,
  `gh run view <id> --log-failed`
- FORBIDDEN: running test suites, builds, react-doctor, typecheck, browser/Playwright
  scripts, smoke runs; pulling, building, starting, or using Docker/Podman/Testcontainers or
  another local container; running database-dependent tests, fixtures, migrations, or service
  checks; any worktree mutation (`git stash`, checkout, commit, add); writing and executing
  scratch scripts
- Every finding must cite file:line and be establishable by reading. If a claim needs runtime
  evidence, do NOT run it — list it under deferred gates with the exact command instead of
  filing it as Critical/Important.
- You are read-only. Do not fix anything you find.

MANDATORY final lines of your report:
Checks run: <exact commands you executed — read-only commands count>
Deferred gates: <for each: exact command the implementer must run + why it matters; or "none">
```

### Parent rules

- Paste the block **verbatim**: "keep it small-scoped" is not a contract, models act on the concrete FORBIDDEN and whitelist lines.
- Never write "run the test suite" in a subagent prompt; write "the test files you changed".
- **Deferred-gate resolution:** resolve every deferred gate to exactly one of — (a) **CI owns it** (the default when a CI job runs on PRs), (b) **you run it at the Phase Gate** when no PR-triggered CI job covers it AND it is a small-scoped check (e.g. a contract/static check), or (c) **record it as residual risk** when it is full-regression class and CI is unreachable. Never let a deferred gate vanish by default.
- The gates CI does NOT run on a PR still need an owner (repo smoke jobs are often `workflow_dispatch`/scheduled). If the diff changes an API contract, run the contract check only when it is database-free and container-free; if it changes UI covered by the acceptance criteria, run the page verification only when it does not pull/start/use a local container or database. Otherwise defer it to CI or record it as residual risk.
- If a subagent ran a forbidden check anyway, record a scope violation in your report; do not re-dispatch to "do it properly".
- Treat `Checks run:` as a claim, not proof. It is evidence about scope only; the diff is what you review.

---

## Phase 1: Implementation

1. Implement exactly what the task specifies
2. Write tests (use `test-driven-development` skill if applicable)
3. Verify small-scoped: fast gates (lint, format, typecheck) + targeted tests for the files you changed only when they are database-free and container-free. Full regression and database/container-backed checks run in CI.
4. Commit with a clear message (use `caveman-commit` skill)
5. Self-review
6. Proceed to Phase Gate, then Phase 2

**Delegation does not move the gate.** Subagents run only what their scope contract allows; you still own the Phase 3 small-scoped verification of the merged result, and CI owns full regression. Never run a full suite locally just because a subagent left it out — that is the designed split, not a gap.

**Reuse lane worktrees.** A lane worktree costs ~145 MB of host writes to create (checkout + dependency bootstrap); reusing one costs ~6 MB, because its ignored `node_modules`/`.venv` trees stay in place. Warm the lane worktrees before dispatching:

```bash
POOL_SCRIPTS="$HOME/.agents/skills/implementer"
for b in <lane-branch-a> <lane-branch-b>; do "$POOL_SCRIPTS/wt-pool.sh" "$b" "<feature-base>"; done   # idempotent
```

This warm-up is optional: `pool-take.sh` creates a missing slot on first use. Pre-warming just
moves the cost earlier and parallelises it across lanes.

If a lane already had a worktree from a previous run on that branch, this resets it to the base and keeps its dependency trees. Then dispatch the lane with the printed path as its working directory (or `worktree: false` when the platform would otherwise allocate a fresh temp worktree). Only fall back to the platform's `worktree: true` when no warm worktree exists for the lane. **Never `git worktree remove` a lane worktree after merging it** — that discards its dependencies and makes the next lane on that branch pay the full bootstrap again.

**Worktree pool — cross-run sharing (git-anchored worktrees, skill-owned scripts).** The pool reuses by BRANCH NAME, so per-feature one-off branch names (`feat/1234-lane-a`) defeat it: the branch dies at squash merge, and the next run mints a new name → new path → full bootstrap. Use FIXED slot branches instead, one per concurrent lane. **Scripts live in THIS skill directory** (`wt-pool.sh`, `wt-pool.sh`'s `wt-anchor.sh`, `pool-take.sh`, `pool-release.sh`, `wt-migrate-anchor.sh`, next to this file — resolve as `$POOL_SCRIPTS="$HOME/.agents/skills/implementer"`).

**Where the pool lives — and why it is NOT under the workspace.** Slots are anchored on
`git rev-parse --path-format=absolute --git-common-dir`, i.e. `<repo>/.git/wt-pool/pool/<slot>`,
resolved by `wt-anchor.sh`. This matters because harnesses put agents in disposable worktrees:

- **Paseo** gives every agent a fresh `~/.paseo/worktrees/<hash>/<slug>` and bumps the path
  (`-1`, `-2`, …) whenever the target exists — it never reuses. A pool anchored at
  `$PWD/.worktrees/pool` therefore dies with each run; that is exactly why reuse stopped working.
- Anchoring on git identity fixes it: same repo (from the main checkout, from a harness
  worktree, or from a different folder) → **one** pool, warm `node_modules`/`.venv` survive.
- Different repos → different `.git` → **fully isolated**, including locks and slot branches.
- `.git/` is never committed, never rsynced, and disappears with the repo, so the anchor needs
  no `.gitignore` entry and no cleanup rule.

```bash
POOL_SCRIPTS="$HOME/.agents/skills/implementer"
"$POOL_SCRIPTS/wt-pool.sh" pool/lane-a origin/master   # → <repo>/.git/wt-pool/pool/lane-a (venv/node_modules persist)
```

Branch names keep the `pool/` prefix because they are repo-wide refs and need a namespace;
the directory name drops it (`pool/lane-a` → `pool/lane-a`, not `pool/pool/lane-a`). Two
workspaces of the same repo deliberately share the pool — coordinate with `pool-take.sh`
rather than by forking the anchor.

**Migrating an existing pool** (one-time, from the old `<toplevel>/.worktrees/pool` layout;
dependency trees move with the directories, so nothing is reinstalled):

```bash
"$POOL_SCRIPTS/wt-migrate-anchor.sh" --dry-run
"$POOL_SCRIPTS/wt-migrate-anchor.sh"
```

Do **not** hand-move pool directories. A moved worktree's git bookkeeping breaks in two places
at once — the absolute path inside `.git/worktrees/<name>/gitdir`, and the stale entry that
`git worktree prune` then drops — and `git worktree repair` alone does **not** fix it (it repairs
the inverse corruption). Slots silently become `prunable`, i.e. invisible to git. The migration
script rewrites `gitdir` per slot and verifies every slot afterwards.

**Branch namespace**: slot branches are repo-wide refs — each workspace must namespace its own (`pool/lane-a` for this workspace; another workspace uses `pool/<ws-tag>/lane-a`) or git refuses the second checkout.

Dispatch discipline per run:
0. **Claim the slot atomically** (multi-agent safety — two runs starting at once would otherwise
   both take lane-a): `"$POOL_SCRIPTS/pool-take.sh" lane-a "<task>"` —
   exit 0 = claimed, 2 = busy (try the next slot or wait), 3 = dirty (previous run crashed with
   uncommitted work; triage before reuse). Steal threshold is age-based only (POOL_STALE_SEC,
   default 6h) — PID liveness is meaningless when orchestrator shells are short-lived. Release
   with `"$POOL_SCRIPTS/pool-release.sh" lane-a` after the lane's PR is pushed and the slot is switched back.
1. Reset each slot to the new base BEFORE creating the PR branch. `wt-pool.sh` prints status
   to **stderr** and only the path to stdout, so capture stdout alone — never `&& cd "$wt"`
   (that would splice status lines into the variable):
   ```bash
   slot=$("$POOL_SCRIPTS/wt-pool.sh" pool/lane-a origin/master)   # warm slot, deps preserved
   ```
   `pool-take.sh <slot> <task>` does this for you and additionally enforces the lock; it
   creates the slot on first use, so a fresh repo needs no separate warm-up step. Pass
   `POOL_SLOT_BASE=<ref>` to override the base it branches from when creating.
2. Create the PR branch INSIDE the slot worktree: `git -C <slot> checkout -q -b feat/<issue>-<slug>` (keeps the warm deps; the slot's files become the lane's working tree).
3. After the PR is pushed (squash-merged later), switch the slot back: `git -C <slot> checkout -q pool/lane-a` and delete the PR branch — the worktree stays warm on the slot branch for the next run. Then `"$POOL_SCRIPTS/pool-release.sh" lane-a`.
4. NEVER `git worktree remove` a pool slot (that is the whole point of the pool). Cleanup at run end covers PR branches and remote branches only — pool slots and their lock dirs stay. Note that
   archiving a harness-owned workspace (e.g. `paseo archive_workspace`) removes **its** worktree
   only; pool slots anchored in `.git/` are not harness-owned and survive.
5. **Slots are flat siblings, never nested.** A run executing *inside* a slot (a nested implementer
   launched from `lane-a`) gets a **different** slot, not a subdirectory of its own: the anchor is
   repo-global, so `lane-a` and `lane-b` are side by side under `<repo>/.git/wt-pool/pool/` and the
   nested run reuses a warm sibling. `pool-take.sh` refuses (exit code **4**) to hand a run the slot
   it is already standing in — two lanes writing one directory concurrently is exactly how a
   duplicate-writer orphan incident starts. Pick another slot, or work in place when the current
   slot is already the right one.
6. **Over-capacity is safe degradation, not an error.** When every slot is claimed or dirty,
   acquisition fails and the run proceeds in whatever directory it already has — no queue, no
   blocking wait. Surface the contention to the user; never poll waiting for a slot to free up.
7. **Capacity — two separate limits, one shared pool.** `pool-take.sh` imposes no slot limit; the
   caller picks the name. Use:
   - `lane-a` `lane-b` `lane-c` — **this skill's default: 3 concurrent lanes within ONE run.** Plan
     for at most three lanes; if the plan needs more, split the run.
   - `lane-d` … `lane-h` — reserved for the Paseo plugin's workspaces (`WARM_POOL_SLOTS`, default 8).
     Do not claim these; they belong to other runs.
   Both draw from the **same** `<repo>/.git/wt-pool/pool/`, so the plugin's extra capacity is
   available without a second pool, and an implementer lane never collides with a workspace.
   Multiple agents running their own implementer concurrently must still claim distinct slots via
   pool-take (busy → next slot or wait); beyond capacity, fall back to a cold one-off worktree
   (`wt-pool.sh feat/<one-off>`) instead of stealing a warm slot mid-run. Bootstrapping a new
   workspace's pool needs pnpm/uv on PATH (`~/.local/share/pnpm`, `~/.local/bin`).

A lane in a cold worktree runs its allowed install command (`pnpm --dir web install --frozen-lockfile`, `uv sync --frozen`) only when the dependency tree is absent — never delete an existing tree to "make sure".

### 1a. Multi-Lane Implementation (Parallel Work)

If the task plan has multiple independent lanes:

**Use the `using-git-worktrees` skill** to create isolated worktrees (it reuses warm ones first). Do NOT manually create worktrees unless the skill directs you to.

**Override the skill's Step 0 in this one case — it is a false negative under a
worktree-based harness.** The skill stops when `GIT_DIR != GIT_COMMON` and reports
"already in an isolated workspace, skip creation". That test is true for **every** agent
run on Paseo (`~/.paseo/worktrees/<hash>/<slug>`, freshly allocated, path bumped whenever it
exists, nothing survives the run), so following it literally skips lane worktrees entirely and
leaves you working in a throwaway directory. Classify the current directory before obeying it:

```bash
. "$HOME/.agents/skills/implementer/wt-anchor.sh"
case "$PWD" in
  "$(wt_pool_dir)"/*) echo "POOL SLOT — warm and persistent; reuse as-is" ;;
  ~/.paseo/worktrees/*|*/.claude/worktrees/*)
    echo "HARNESS SCRATCH — disposable; ignore Step 0 and take a pool slot via pool-take.sh" ;;
  *) echo "genuinely isolated worktree — Step 0 applies" ;;
esac
```

On `HARNESS SCRATCH`, do not build the lanes here. Take slots from the pool
(`pool-take.sh`, see the Worktree pool section) and pass each slot path to its lane as the
working directory. Everything else in `using-git-worktrees` — reuse-first ordering, the
`git clean -fd` (never `-fdx`) rule, dependency-tree preservation, retention window — applies
unchanged.

**Branch naming:** Each lane works on a branch derived from your feature branch (e.g. `feat/xxx-lane-a`).

**Dispatch pattern:**

```python
Agent(
    subagent_type="coder",
    description="Lane A: <description>",
    run_in_background=True,
    prompt=VERIFICATION_SCOPE + """
## Lane A: <description>
You are working in an isolated git worktree on branch <lane-branch-name>.
The worktree root is at <ABSOLUTE_WORKTREE_PATH>.
All file operations MUST use relative paths from that directory root.

## Your Tasks
<lane scope and files>

## Rules
- Commit your work with: git add -A && git commit -m "<message>"
- Report back with Status: DONE | BLOCKED | NEEDS_CONTEXT
- If DONE, confirm the branch has commits: git log --oneline -3
"""
)
```

`VERIFICATION_SCOPE` is the lane scope block from **Verification Scope Contract**, pasted verbatim. Omitting it is a hard-constraint violation: the lane runs the project's full pre-push checklist instead of implementing.

**Verify lane results** after each worker completes:
```bash
git log <lane-branch-name> --oneline -5
```
If the branch has no new commits, the worker likely wrote to the wrong directory. Re-dispatch with explicit commit instructions.

**Merge lane branches** once all are verified:
```bash
git merge <lane-branch-name-a> --no-edit
git merge <lane-branch-name-b> --no-edit
# Then run small-scoped verification (database-free, container-free targeted checks only; full
# regression and database/container-backed checks run in CI)
```

### 1b. Phase Gate (MANDATORY)

Before entering Phase 2, verify:
- [ ] Every lane: worker completed? Branch has commits? Targeted checks pass?
- [ ] All lanes merged into feature branch
- [ ] Small-scoped verification passes on merged result (database-free, container-free targeted
      checks only; full regression and database/container-backed checks in CI)
- [ ] Lane Scope Audit passed: every subagent reported `Checks run:` and `Deferred gates:`, none ran a forbidden check, and every deferred gate has an owner/decision
- [ ] Lane worktrees KEPT (not removed): `git worktree list` still shows the lane branches, and no worktree was wiped with `git clean -fdx`

**Worktree retention (do NOT skip):** prune a lane worktree only when its branch is merged/abandoned AND the worktree is older than 7 days (default). Immediate removal after merge is what forces every later task on that branch to pay the full checkout + dependency bootstrap again.

**The sweep MUST skip the pool and harness directories.** They are not lane worktrees:
pool slots carry the warm `node_modules`/`.venv` that reuse depends on, and harness
directories belong to the tool that created them. `git worktree list` enumerates all of
them, so an unguarded sweep plus `--force` silently destroys the pool — which is the exact
cost the pool exists to avoid. Prune by *lane branch*, never by "every worktree":

```bash
. "$HOME/.agents/skills/implementer/wt-anchor.sh"
POOL="$(wt_pool_dir)"
SELF="$(git rev-parse --show-toplevel)"
# 只清理本次 run 用过的 lane 分支；池槽位与 harness 目录一律不碰
for wt in $(git worktree list --porcelain | awk '/^worktree /{print $2}'); do
  case "$wt" in
    "$SELF"|"$POOL"/*|~/.paseo/worktrees/*|~/.claude/worktrees/*) continue ;;
  esac
  br=$(git -C "$wt" branch --show-current)
  case "$br" in
    ""|master|main) continue ;;
    feat/*|fix/*|pool/*|implement-*) ;;   # 本 run 的 lane 分支；按需收窄
    *) continue ;;                        # 其它分支的 worktree 不归本次 run 管
  esac
  git -C "$wt" merge-base --is-ancestor "$br" origin/master 2>/dev/null \
    || { echo "skip (未合并): $br"; continue; }
  [ "$(find "$wt" -maxdepth 0 -mtime +7)" = "$wt" ] && git worktree remove --force "$wt"
done
```

When in doubt, skip. A pool slot wrongly deleted costs a full reinstall; a stale lane
worktree costs a few MB of disk.

If any lane is still pending: do NOT start review. Wait for the background agent to complete (kimi will notify you). Use `TaskOutput(task_id=...)` for a single status check if needed — do NOT poll in a loop.

### 1c. Lane Scope Audit (MANDATORY)

For every subagent result (lane, fix-worker, reviewer), before accepting it:

1. Read the `Checks run:` and `Deferred gates:` lines. **A missing line is itself a violation.**
2. If `Checks run:` names a forbidden check — full suite runs, `build`, `react-doctor`, Playwright/browser scripts, smoke runs, a chained alias script, a verification skill, a local Docker/Podman/Testcontainers command, or a database-dependent check — record `⚠ SCOPE VIOLATION: <agent> ran <command>`.
3. Do NOT re-dispatch to "verify properly", and do NOT run the forbidden command yourself on the subagent's behalf. Your targeted checks + the Phase 3 gate + CI already cover it.
4. **Triage `Deferred gates:` — this is where a lane's honest restraint becomes your work.** Resolve each item to exactly one: (a) CI owns it (a PR-triggered job covers it), (b) you run it at the Phase Gate (no PR-triggered CI job covers it, and it is small-scoped — e.g. the contract check), or (c) record it as residual risk (full-regression class and CI unreachable). A deferred gate nobody picks up is the one failure mode this contract can create, and it lands as a red PR you still own.
5. Aggregate violations into `Lane Scope Compliance` and deferred decisions into `Deferred Gates (decisions)`. Repeat offenders within one run mean the dispatch prompt was missing the contract — fix the prompt, not the agent.

---

## Phase 2: Review-Fix Loop (max 20 rounds)

**Pre-flight:** Confirm Phase 1b gate passed.

Each round:
1. Dispatch **one reviewer per angle — all five, in parallel** (see Review Angles below)
2. Synthesize findings across angles (dedupe overlapping findings; keep the strictest severity)
3. If no Critical/Important issues remain → break
4. Else delegate fixes to a fix-worker `Agent` (see prompt below)
5. Verify fixes with targeted checks on the changed files only when they are database-free and
   container-free (never a full suite, local container, or database-dependent test)
6. Next round

### Review Angles (platform-neutral — these semantics are the portable part)

One fresh-context, read-only reviewer per angle, ALL launched in parallel. The five base angles
are mandatory; angle 5 may be swapped for Performance or Accessibility when the diff calls for
it. This list is mirrored from pi's `/implement` prompt (`.pi/prompts/implement.md` Phase 4) —
change the two files together.

1. **Correctness & Regressions** — Does the change satisfy the task and its acceptance criteria?
   Does it preserve existing behavior (regressions at call sites)? Edge cases, boundary
   conditions, hidden runtime failures?
2. **Tests & Validation** — Tests added at the right layer? Meaningful assertions? Verification
   commands cover the validation contract? Coverage gaps for the changed scope?
3. **Simplicity & Maintainability** — Unnecessary complexity? Duplicated structure? Brittle
   abstractions? Confusing names? Error handling and logging? Performance smells?
4. **Security & Privacy** — Unsafe input/output handling? Auth boundary violations? Data
   exposure? Sensitive data in logs/responses/notifications? PIPL / minor-protection exposure?
   Injection risks? Missing authorization checks?
5. **Contracts & Project Compliance** — API/schema/type drift between backend and clients
   (Pydantic ↔ TS types), migration/version compatibility, and the repository's AGENTS.md
   cross-cutting hard rules for the touched domain (crisis ↔ consultation separation, audit,
   idempotency, i18n, pagination). Swap for **Performance** (data-heavy / latency-sensitive
   diffs) or **Accessibility** (UI diffs) when the work calls for it.

**Reviewer dispatch:** `REVIEWER_SCOPE` is the reviewer scope block above, pasted verbatim into
EVERY reviewer prompt. The `Agent` tool below is the ZCode/Claude Code shape (illustrative —
see Dispatch Mechanism below for other platforms); one call PER ANGLE, all in parallel:

```python
# Angle 1 — Correctness & regressions (shown in full; angles 2-5 follow the same shape)
Agent(
    subagent_type="coder",
    description="Review: correctness & regressions",
    run_in_background=True,
    prompt=REVIEWER_SCOPE + f"""
You are a correctness & regressions reviewer. Review the diff against {base_branch}.

Task: {task_description}
Diff: Run `git diff {base_branch}` in {cwd}

Check:
- Does the change satisfy the task and its acceptance criteria?
- Does it preserve existing behavior? Regressions at call sites?
- Edge cases, boundary conditions, hidden runtime failures?

Report ONLY Critical/Important/Minor issues. Be specific: file:line + fix suggestion.
"""
)

# Angles 2-5: same Agent() shape, replace the role line and Check list with:
#   "You are a tests & validation reviewer." →
#     - Tests added at the right layer? Meaningful assertions?
#     - Verification commands cover the validation contract?
#     - Coverage gaps for the changed scope?
#   "You are a simplicity & maintainability reviewer." →
#     - Unnecessary complexity? Duplicated structure? Brittle abstractions?
#     - Confusing names? Error handling and logging? Performance smells?
#   "You are a security & privacy reviewer." →
#     - Unsafe input/output handling? Auth boundary violations? Data exposure?
#     - Sensitive data in logs/responses/notifications? PIPL / minor-protection exposure?
#     - Injection risks? Missing authorization checks?
#   "You are a contracts & project compliance reviewer." →
#     - API/schema/type drift between backend and clients (Pydantic ↔ TS types)?
#     - Migration/version compatibility?
#     - AGENTS.md cross-cutting hard rules for the touched domain (crisis ↔ consultation
#       separation, audit, idempotency, i18n, pagination)?
#   Angle 5 swaps: "You are a performance reviewer." (N+1 queries, payload sizes, latency)
#                  "You are an accessibility reviewer." (a11y semantics, labels, focus, contrast)
```

**Dispatch mechanism (portability):** the invariant is one fresh-context, read-only subagent
per angle, ALL launched in parallel, each with `REVIEWER_SCOPE` pasted verbatim. Translate the
syntax to your platform: pi → a single `runs.all([...])` workflow with one
`reviewer-override.reviewer` entry per angle; other agents → your equivalent background
subagent fan-out. `subagent_type` values are illustrative — use your platform's
general-purpose worker type.

**Stop conditions** (all must be true):
- No Critical or Important issues remain
- Database-free, container-free targeted checks for the changed scope pass (full regression is
  CI's job, not a round gate)
- At least 2 review rounds completed

**Fix-worker dispatch:**

```python
Agent(
    subagent_type="coder",
    description="Apply review fixes",
    prompt=VERIFICATION_SCOPE + f"""
Apply the following fixes. You are working in the directory at {cwd}.
All file operations MUST use relative paths from that directory root.

<findings to fix>

After applying fixes, run only database-free, container-free targeted checks for the files you
touched and end your report with `Checks run: <commands>` and `Deferred gates: <...>`. Full
regression and database/container-backed checks run in CI — do not run them here.
"""
)
```

---

## Phase 3: PR & CI Loop

### PR Creation

Push feature branch and create PR against base branch.
Title: use conventional commit prefix.
Body includes:
- What changed and why
- Test plan / verification steps
- Known limitations or follow-ups

### Local Verification (SMALL-SCOPED — MANDATORY)

This gate is **yours alone** — no subagent performs it (see Verification Scope Contract). Run after every push:

**Backend (if Python files changed):**
```bash
ruff check app/
ruff format --check app/
pytest -q <changed test files / modules covering the change>   # targeted and DB/container-free only
```

**Frontend (if web/ files changed):**
```bash
pnpm --dir web run lint && pnpm --dir web run typecheck
pnpm --dir web exec vitest run <changed test files>   # targeted and DB/container-free only
```

**Conditional gates CI does not run on a PR** (owner: you):
- Diff changes an API contract / response shape → run the `fullstack-contract-check` skill yourself
  only when it is database-free and container-free.
- Diff changes UI covered by the task's acceptance criteria → run the `browser-page-verify` /
  `pageverify` skill yourself only when it does not pull/start/use a local container or database.
- Neither applies → record both as residual risk in the report.

**Do NOT run full regression, local containers, or database-dependent tests locally** — full
`pytest`, full frontend test suite, build, and `react-doctor` are scheduled on CI and verified via
`gh pr checks`; database/container-backed checks also belong in CI. If ANY allowed local check
fails: fix, re-run that database-free/container-free check, push.

### Mergeability Preflight (MANDATORY — before every CI wait or poll)

A conflicting PR has **no buildable merge ref**: GitHub does not start the `pull_request`
workflows, so a poll sees "no checks", "pending" forever, or checks attached to a stale
commit — with no failure to read. That is the conflict signature, not a CI outage, and it
is never a reason to escalate or to ask the user.

```bash
scripts/ci/pr-preflight.sh <PR_NUMBER>        # exit 2 = needs rebase (repo may ship this helper)
gh pr view <PR_NUMBER> --json mergeable,mergeStateStatus,headRefOid,statusCheckRollup
gh run list --branch <headRefName> --limit 1 --json headSha,status,conclusion
```

**Rebase immediately** (pre-authorized for YOUR PR's own head branch) when any holds:
- `mergeable=CONFLICTING`, or `mergeStateStatus` ∈ {`DIRTY`, `BEHIND`}
- zero registered checks AND the newest workflow run's `headSha` ≠ the PR head SHA
- someone force-pushed the head and no new run started

```bash
git fetch origin <base> && git rebase origin/<base>
# conflicts inside generated artifacts (API docs, PG fixture collections, secrets
# baselines, lockstep fixtures) are RE-GENERATED with their owning script, never hand-merged
git push --force-with-lease origin HEAD:<head>     # --force-with-lease ONLY, never --force
```

Never rebase or force-push `master`/`main`, and never a branch another agent has checked
out. If the rebase conflicts in real code, resolve it — do not abort and wait for a human.
"PR is CONFLICTING — needs rebase" is not a reportable finding: you are the author.

### CI Fix Loop (MANDATORY)

**Stop conditions for DONE:**
- All local small-scoped checks pass
- GitHub CI checks green on PR (confirmed via `gh pr checks <PR_NUMBER>`) — full regression runs there
- At least one full CI run completed

**If CI is unreachable after 3 retry attempts**, you may still finish, but only as:
- `Status: DONE (CI unavailable)` with `Full regression: NOT RUN — CI unreachable (<the gh error>)`,
  `Local containers/database tests: NOT RUN — prohibited`, and every deferred gate listed; and
- keep the PR open and say so. **Never use a local full-regression, local-container, or
  database-dependent test as fallback evidence.**

This exception is for `gh` failing to answer. A PR that never triggered CI is NOT "CI
unreachable" — re-run the Mergeability Preflight and rebase.

Local small-scoped checks alone never license a plain `DONE`.

**Loop:**
1. Push, create PR
2. **Mergeability preflight** — clear a conflicted PR before any wait
3. Run local small-scoped verification — fix failures before proceeding
4. Wait for GitHub CI: `gh pr checks <PR_NUMBER> --watch`
5. If the wait ends with zero checks, or with checks that never attach to the current head → go back to step 2 (conflict signature, not an outage)
6. If unreachable after 3 tries → follow the CI-unavailable rule above
7. If all green → proceed
8. If red → get logs (`gh run view <RUN_ID> --log-failed`), fix, push, repeat
9. If CI fails 3+ times on same job → report BLOCKED

---

## Quality & Escalation

### Self-Review Checklist

Before reporting:
- [ ] All acceptance criteria met
- [ ] Database-free, container-free targeted checks pass locally; full regression and
      database/container-backed tests are covered by CI
- [ ] Lane Scope Audit done: every subagent reported `Checks run:` and `Deferred gates:`, none ran a forbidden check, and every deferred gate has an owner/decision
- [ ] CI green on PR (`gh pr checks` confirmed) — or the report carries `DONE (CI unavailable)` + `Full regression: NOT RUN`
- [ ] Mergeability preflight clean: `mergeable=MERGEABLE` and checks attached to the current head SHA (no "waiting on a conflicted PR" state was reported as progress)
- [ ] No TODO/FIXME/HACK left (unless noted)
- [ ] Follows project conventions (AGENTS.md)
- [ ] No unnecessary changes outside task scope
- [ ] Error handling covers edge cases
- [ ] No hardcoded values that should be configurable

### When to Escalate

**BLOCKED:**
- Requirements genuinely ambiguous
- Approach fundamentally flawed
- Stuck after 3+ attempts on same issue
- CI fails 3+ times on same job
- Missing prerequisite dependency
- A conflicted PR is **never** BLOCKED: it is a rebase. Run the Mergeability Preflight, resolve it, keep going.

**NEEDS_CONTEXT:**
- Need files/info not available
- Task references something unfound

### When NOT to Create a PR

- Pure investigation/documentation → report findings directly
- Trivial changes not warranting PR → report diff
- CI fundamentally broken → report BLOCKED with details

---

## Report Format

```
## Implementation Report

### Task: <title>
### Status: DONE | BLOCKED | NEEDS_CONTEXT

### Summary
<1-2 sentences>

### Changes
<key changes, grouped by area>

### PR
<URL or N/A>

### CI Status
All checks green on PR <NUMBER> (confirmed with `gh pr checks`); full regression ran on CI.
If CI was unreachable: `Full regression: NOT RUN — CI unreachable (<error>)`; local full tests,
containers, and database-dependent tests are prohibited, so leave the PR open and state that
explicitly. Status is `DONE (CI unavailable)`.

### Test Results
<summary>

### Lane Scope Compliance
<subagents dispatched, and: "no scope violations" | the ⚠ SCOPE VIOLATION lines>

### Deferred Gates (decisions)
<each gate a subagent deferred + your decision: CI owns it | you run it at the Phase Gate | recorded as residual risk — with the reason>

### Issues / Follow-ups
<remaining concerns>
```

**Report MUST NOT contain:**
- Raw file diffs
- Verbose test output
- Internal details unless they affect orchestrator decisions

**LOCK CLEANUP (MANDATORY):**
```bash
rm -f .pi-implementer.lock
```
Do this before delivering the report, regardless of status.
