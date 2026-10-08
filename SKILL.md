---
name: implementer
description: Use when implementing a feature or bugfix that requires a self-contained subagent with review-fix loops, CI-gated PR creation, and multi-lane parallel work
disable-model-invocation: true
---

# Implementer Subagent Workflow

Self-contained implementation subagent: claims the GitHub issue, implements, runs a
five-angle parallel review, delegates fixes, creates a PR, loops on CI until green.

**Deep reference (`REFERENCE.md`, same directory) — read the section you need, on demand:**
- §A Lane/Fix-worker scope block — paste verbatim into EVERY worker dispatch (MANDATORY)
- §B Reviewer scope block — paste verbatim into EVERY reviewer dispatch
- §C Local Verification Policy — CI-backed vs CI-absent, who runs what
- §D Worktree pool — anchor rationale, migration, retention/sweep rules
- §E CI failure triage — classification table, Mergeability Preflight detail

## When to Use / Not Use

Use: medium-to-large features needing structured review; multi-lane parallel work;
CI-gated PRs; work that should not be done by the orchestrator itself.
Not: investigation/docs tasks, trivial fixes, tasks faster than the dispatch overhead.

## ABSOLUTE FIRST ACTIONS — claim the issue, then take the lock

Order matters: Step 0 is the cross-person lock (GitHub), Step 1 the same-clone lock.
Skipping Step 0 = two people build the same issue twice. Skipping Step 1 = two sessions
in one clone interleave on one branch.

### Step 0 — Claim the GitHub issue

Resolve the issue number from the task text / branch / `#N` reference. No issue reference
(local, exploratory task)? Skip Step 0 and say so in the report — never invent one.

```bash
gh issue view "$N" --json number,title,state,assignees,labels \
  --jq '{n:.number,title:.title,state:.state,assignees:[.assignees[].login],labels:[.labels[].name]}'
```

| Observed | Action |
| --- | --- |
| CLOSED | STOP — report `BLOCKED` |
| Assigned to someone else | STOP — do not steal; report `BLOCKED` |
| Open PR already targets it (`gh pr list --state open \| grep -E "(^\|[^0-9])${N}([^\|0-9]\|$)")` | STOP — report the PR URL |
| Assigned to you | idempotent: ensure `inprogress` label, proceed |
| Unassigned | claim (below) |

```bash
gh issue edit "$N" --add-assignee @me
gh issue edit "$N" --add-label inprogress 2>/dev/null || echo "⚠ label 'inprogress' unavailable"
```

Re-read after writing: a different assignee now showing = you lost a race — back off.
Claim failed (no `gh`, offline)? Warn loudly, continue, record `Issue claim: FAILED — <reason>`.

**Picking work when none was named:** prefer unassigned issues without `inprogress`
(`gh issue list --json number,title,assignees,labels` + filter). Never take another
person's claimed issue without explicit user authorization.

**Release on every exit path:** remove the `inprogress` label; keep the assignee (it
records who owns the follow-up).

### Step 1 — Take the exclusive local lock

```bash
POOL_SCRIPTS="$HOME/.agents/skills/implementer"   # canonical script location
. "$POOL_SCRIPTS/wt-anchor.sh"
wt_ensure_dirs
LOCK="$(wt_lock_file implementer)"    # <repo>.wt-pool/locks/implementer.lock
```

Never write a lock relative to `$PWD` — harness worktrees (Paseo `~/.paseo/worktrees/…`)
are disposable, so a `$PWD` lock vanishes with the run and two implementers collide.
The anchor is git-identity-based: main checkout and all worktrees of one repo share
one lock; different repos never see each other.

- Lock exists and is **younger than `POOL_STALE_SEC`** (default 6h) → report `BLOCKED`
  with the lock path/age. Do not proceed, do not remove.
- Lock exists but is **older** → report `BLOCKED`, ask the user (AskUserQuestion)
  before removing.
- No lock → acquire atomically with `mkdir`:

```bash
if ! mkdir "$LOCK" 2>/dev/null; then echo "RACE: 另一个 implementer 刚抢到锁" >&2; exit 2; fi
cat > "$LOCK/claim" <<EOF
pid=$$
branch=$(git branch --show-current)
timestamp=$(date -Iseconds)
task=<brief task description>
EOF
```

Judge staleness by **age**, never PID liveness — orchestrator shells are short-lived,
so `ps -p` always says dead. After acquiring, confirm Step 0 landed (or no-issue stated).

**Lock cleanup (MANDATORY, every exit path):** `rm -rf "$LOCK"` before reporting.

## Hard Constraints

- 🚫 NEVER cherry-pick into / modify master/main directly; NEVER leave partial work
- 🚫 NEVER attempt cross-branch integration in the orchestrator session
- 🚫 NEVER start Phase 2 while any lane is pending; NEVER report DONE without green CI
- 🚫 NEVER launch multiple implementer instances for one feature — ONE implementer fans out workers
- 🚫 NEVER overtake subagent work; NEVER poll subagents in a loop (background + notification, or one TaskOutput check)
- 🚫 NEVER start without the lock; NEVER forget lock cleanup or releasing the GitHub claim
- 🚫 NEVER work an issue assigned to someone else — takeover needs explicit user authorization
- 🚫 NEVER push to / rebase / force-push a branch you did not create (teammate's or another agent's)
- 🚫 NEVER dispatch a worker/reviewer without the scope block pasted verbatim (REFERENCE.md §A/§B) — without it they run the project's full pre-push checklist
- 🚫 NEVER let a worker run full suites, builds, react-doctor, browser/smoke scripts, containers, or DB-dependent tests — see REFERENCE.md §C for who verifies what
- 🚫 NEVER assume CI exists; confirm before deferring anything to it
- 🚫 NEVER report DONE while behind base or with conflict markers left in the tree
- ✅ ALWAYS keep your own PR branch mergeable: rebasing YOUR head branch + `git push --force-with-lease` is pre-authorized (REFERENCE.md §E)

## Verification Scope Contract

Subagents see only your prompt plus AGENTS.md. AGENTS.md tells every agent to run the
full pre-push checklist — **a dispatch without the pasted scope block ends in full
regression inside an implementation lane.** Paste §A (workers) / §B (reviewers) from
REFERENCE.md verbatim; "keep it small-scoped" is not a contract, models act on the
concrete FORBIDDEN/whitelist lines. Never write "run the test suite" in a subagent prompt.

**Deferred-gate resolution** (Lane Scope Audit, Phase 1c): every deferred gate resolves to
exactly one — (a) CI owns it (PR-triggered job), (b) you run it at the Phase Gate
(no CI covers it AND small-scoped), or (c) recorded as residual risk (full-regression
class, CI unreachable). Never let one vanish by default.

Treat a worker's `Checks run:` as a scope claim, not proof; review the diff. A worker that
ran a forbidden check → record `⚠ SCOPE VIOLATION` in your report; do not re-dispatch.

## Phase 1: Implementation

1. Implement exactly what the task specifies; write tests (TDD where applicable)
2. Verify small-scoped: fast gates (lint, format, typecheck) + targeted tests for changed
   files only, database-free and container-free. Full regression: CI (CI-backed) or you at
   the Phase Gate (CI-absent) — never a worker. Mode and rationale: REFERENCE.md §C.
3. Commit (`caveman-commit` style), self-review, proceed to Phase Gate

**Delegation does not move the gate** — you still own Phase Gate verification of the
merged result.

### 1a. Multi-Lane Implementation

Group lanes by write-set overlap: disjoint files → one directory each; same files forced
serial → one directory, one at a time; same files must be parallel → serialize instead.
Never two writers in one directory — that is the double-writer failure (lost commits,
orphaned branches) the pool design exists to prevent.

**Warm worktree pool** (reuse across runs; full mechanics + migration: REFERENCE.md §D):

```bash
POOL_SCRIPTS="$HOME/.agents/skills/implementer"
slot=$("$POOL_SCRIPTS/pool-take.sh" lane-a "<task>")   # 0=claimed 2=busy 3=dirty 4=that slot is cwd
# creates <repo>.wt-pool/pool/lane-a on first use; deps persist across runs
git -C "$slot" checkout -q -b feat/<issue>-<slug>      # PR branch inside the warm slot
# ... dispatch the lane with cwd=$slot ...
# after PR pushed: git -C "$slot" checkout -q pool/lane-a; delete PR branch;
"$POOL_SCRIPTS/pool-release.sh" lane-a
```

Rules: slots are `lane-a`-`lane-c` for this skill (lane-d+ belong to the Paseo plugin);
never `git worktree remove` a slot; no free slot → proceed in the current directory and
surface the contention, never wait. Over-capacity is safe degradation, not an error.
On Paseo (`~/.paseo/worktrees/…` = HARNESS SCRATCH): ignore the using-git-worktrees
"already isolated" short-circuit and take pool slots, passing each slot path as the
lane's working directory.

Dispatch pattern (background, each prompt = §A verbatim + lane scope + "commit with
`git add -A && git commit -m …`" + report `Status: DONE|BLOCKED|NEEDS_CONTEXT`).
After completion verify the branch has commits (`git log <lane-branch> --oneline -5`);
no commits = worker wrote to the wrong directory. Merge lane branches only after all
verified — you merge, you never cross-integrate other agents' work.

### 1b. Phase Gate (MANDATORY)

- [ ] Every lane done, branch has commits, targeted checks pass
- [ ] All lanes merged; small-scoped verification passes on the merged result
- [ ] Lane Scope Audit (1c) passed
- [ ] Lane worktrees KEPT (prune only: merged/abandoned AND >7 days old; never pool
      slots or harness directories — REFERENCE.md §D)

### 1c. Lane Scope Audit (MANDATORY)

For every subagent result: read `Checks run:` / `Deferred gates:` (a missing line is
itself a violation); flag forbidden commands as `⚠ SCOPE VIOLATION`; resolve every
deferred gate to (a)/(b)/(c) above. Aggregate into `Lane Scope Compliance` +
`Deferred Gates (decisions)`. Repeat offenders = the dispatch prompt was missing the
contract — fix the prompt.

## Phase 2: Review-Fix Loop (max 20 rounds)

Pre-flight: Phase Gate passed. Each round:
1. Dispatch one fresh-context, read-only reviewer per angle — all five, in parallel,
   each with §B pasted verbatim. Angles: ① Correctness & regressions ② Tests &
   validation ③ Simplicity & maintainability ④ Security & privacy ⑤ Contracts & project
   compliance (swap ⑤ for Performance or Accessibility when the diff calls for it).
   Report only Critical/Important/Minor, file:line + fix suggestion.
2. Synthesize (dedupe, keep strictest severity)
3. No Critical/Important left → break (after ≥2 rounds)
4. Else dispatch one fix-worker (§A verbatim), verify with targeted checks only

## Phase 2.5: Pre-CI Base Sync (MANDATORY GATE)

An out-of-sync branch is the #1 avoidable red-CI cause.

```bash
BASE_BRANCH=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
git fetch origin "$BASE_BRANCH" && git merge "origin/$BASE_BRANCH" --no-edit
```

- Conflicts: additive → take both; one-sided → take base; semantic → base for shared
  infra, yours for feature logic; generated artifacts regenerated with their owning
  script, never hand-merged; too complex → `BLOCKED` with the file list.
- Re-run small-scoped checks after every sync.
- Gate: `git rev-list --count HEAD..origin/<base>` = 0, else do not proceed.

## Phase 3: PR & CI Loop

PR: conventional-commit title; body covers what/why, test plan, limitations.

**Local small-scoped verification (yours alone, after every push):**
- Python changed: `ruff check app/` + `ruff format --check app/` + targeted `pytest -q <files>`
- Web changed: `pnpm --dir web run lint && typecheck` + targeted `vitest run <files>`
- API contract changed → fullstack-contract-check; acceptance-criteria UI → page-verify
  — each only when database-free/container-free; else residual risk.
- Full regression: CI-backed → never locally; CI-absent → you run it once here, on the
  merged branch (REFERENCE.md §C).

**Mergeability Preflight — before every CI wait** (detail: REFERENCE.md §E): a
CONFLICTING/DIRTY/BEHIND PR has no buildable merge ref, so GitHub never starts the
workflows — "no checks"/"pending forever" is the conflict signature, not an outage.
`gh pr view --json mergeable,mergeStateStatus,headRefOid,statusCheckRollup`; if
conflicting → rebase your head branch (pre-authorized) → `git push --force-with-lease`.

**CI Fix Loop:**
1. Push, create PR → 2. preflight → 3. local small-scoped checks →
4. `gh pr checks <N> --watch` → 5. zero checks / stale head SHA → back to 2 →
6. `gh` unreachable after 3 tries → `Status: DONE (CI unavailable)` +
   `Full regression: NOT RUN — CI unreachable (<error>)`, keep PR open — never fill the
   gap with local full tests → 7. green → DONE gate → 8. red → triage (REFERENCE.md §E:
   out-of-sync / conflict / your bug / infra / third-party) → 9. same job fails 3+ → `BLOCKED`.

**Final gate before DONE:**

```bash
git fetch origin "$BASE_BRANCH" && [ "$(git rev-list --count HEAD..origin/$BASE_BRANCH)" -eq 0 ] \
  || echo "BLOCKED: branch behind base"
grep -rnE '^(<<<<<<<|=======|>>>>>>>)' --include='*.py' --include='*.ts' --include='*.tsx' \
  --include='*.js' --include='*.jsx' . 2>/dev/null   # must be empty
```

## Quality & Escalation

**Self-review before reporting:** acceptance criteria met; issue claim settled; verification
matches CI mode; Lane Scope Audit done; CI green (or `DONE (CI unavailable)` recorded);
preflight clean (`mergeable=MERGEABLE`, checks on current head); not behind base; no
conflict markers; no TODO/FIXME/HACK left; follows AGENTS.md; no out-of-scope changes;
error handling covers edge cases; no hardcoded values that should be configurable.

**Escalate BLOCKED:** requirements ambiguous; approach flawed; stuck 3+ attempts; CI
fails 3+ on same job; missing dependency; issue assigned to another person / open PR
exists; base sync unsafely conflicting. A conflicted PR is never BLOCKED — it is a rebase.

**NEEDS_CONTEXT:** needed files/info unavailable. **No PR:** investigation/docs or trivial
diff → report findings; CI fundamentally broken → `BLOCKED`.

## Report Format

```
## Implementation Report
### Task: <title>    ### Status: DONE | BLOCKED | NEEDS_CONTEXT
### Summary / ### Changes (grouped by area) / ### PR <URL or N/A>
### Issue Claim   #<N>: assignee=@me, inprogress released | FAILED — <reason> | no issue reference
### CI Status     green via gh pr checks; branch synced (rev-list = 0); no conflict markers.
                  Or: DONE (CI unavailable) + Full regression: NOT RUN — CI unreachable (<err>)
### Test Results  <summary>
### Lane Scope Compliance   <dispatched agents; "no scope violations" | ⚠ lines>
### Deferred Gates (decisions)  <each: CI owns | run at Phase Gate | residual risk — why>
### Issues / Follow-ups
```

No raw diffs, no verbose test output. **Cleanup before delivering the report (every exit
path):** `rm -rf "$LOCK"` + `gh issue edit "$N" --remove-label inprogress 2>/dev/null || true`.

## Orchestrator Contract (for reference)

The orchestrator reads reports and decides; it never writes code, resolves conflicts, or
commits. Multi-lane features use ONE implementer. One issue = one implementer (GitHub
assignee arbitrates). Stale-lock removal requires explicit user confirmation — the user
may know why it exists.
