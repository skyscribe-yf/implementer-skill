# Implementer Reference — deep sections, load on demand

Companion to `SKILL.md`. Each section is self-contained; read only what the current
phase needs. §A/§B blocks are pasted VERBATIM into dispatch prompts — do not summarize.

---

## §A Lane / Fix-worker scope block (paste verbatim into EVERY worker dispatch)

```
## Verification Scope (contract — overrides the repo AGENTS.md pre-push COMMAND list for this task)
You are a child in an implementer run, not the PR owner. The implementer runs the small-scoped
pre-PR gate (fast gates + targeted tests) and owns full regression — whether that means driving CI
green or running the suite itself. Full regression is NOT your job in either case. Nothing here
excuses a red result.

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

---

## §B Reviewer scope block (paste verbatim into EVERY reviewer dispatch)

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

---

## §C Local Verification Policy — who runs what

Determines whether full regression is CI's job or yours. It applies to the implementer,
every worker, and every reviewer.

**Establish the mode first** (`gh pr checks` after PR; `ls .github/workflows/`):
- **CI-backed** — a PR-triggered job covers full regression. Full suites, builds, containers,
  and DB-backed checks are FORBIDDEN locally: they duplicate CI and cost more than they save.
  If CI is unreachable mid-run, report `DONE (CI unavailable)` and keep the PR open.
- **CI-absent** — no PR-triggered job covers them. The implementer runs full regression ONCE,
  at the Phase Gate, on the merged result, and records it as evidence. Start the DB/container
  only if the repo documents that workflow; note the deviation.

State the mode and why in one line before dispatching workers.

**Both modes:** never let a *worker* run a full suite (it destroys lane parallelism and
duplicates the owner's run); never pull/build/start a container unless the repo's documented
workflow requires it; prefer deferring over guessing; record every deferral with the exact
command and owner — a deferred gate nobody claims is the failure mode this policy creates.

---

## §D Worktree pool — mechanics, migration, sweep

**Anchor:** `<repo>.wt-pool/` (sibling of the repo, NOT inside `.git`), resolved by
`wt-anchor.sh` from `git rev-parse --path-format=absolute --git-common-dir`. Same repo from
any checkout/worktree → one pool; different repos → isolated. Why not in `.git`: Paseo's
workspace-git-service observes git-common-dir with `MAX_WATCHED_DIRECTORIES = 5000`; a pool
of full checkouts blows through it and degrades git metadata to polling. Cost of the sibling:
deleting the repo no longer deletes the pool — `rm -rf <repo>.wt-pool` by hand.

**Why Paseo needs the pool:** Paseo gives every agent a disposable
`~/.paseo/worktrees/<hash>/<slug>` (path bumped `-1`, `-2`, … on collision, never reused).
A pool anchored at `$PWD/.worktrees/pool` dies with each run — that is why reuse stopped
working before the anchor was moved.

**Reuse is by slot branch** (`pool/lane-a`…). Per-feature one-off branch names defeat it:
the branch dies at squash merge → new path → full ~313 MB bootstrap (checkout + pnpm + uv).
Slot branches are repo-wide refs; namespace per workspace if two workspaces share a repo.

**`pool-take.sh <slot> <task>`** — 0=claimed, 2=busy, 3=dirty (crashed with uncommitted
work; triage), 3 with legacy-pool message = unmigrated old pool exists (run
`wt-migrate-anchor.sh`, see below), 4=that slot is your cwd (never hand a run the slot it
stands in — pick another or work in place). Steal threshold is age-based only
(`POOL_STALE_SEC`, default 6h); PID liveness is meaningless. Release with `pool-release.sh`
after the PR is pushed and the slot is switched back to `pool/<slot>`.

**Reset before PR branch:** `slot=$("$POOL_SCRIPTS/wt-pool.sh" pool/lane-a origin/master)`
(warm, deps preserved; status goes to stderr, path to stdout — capture stdout alone, never
`&& cd "$wt"`). Then `git -C "$slot" checkout -q -b feat/<issue>-<slug>`.

**Lane dispatch on Paseo** — the harness scratch trap: `~/.paseo/worktrees/…` fails the
using-git-worktrees "already isolated" check for EVERY Paseo agent, so following that skill
literally skips lane worktrees entirely. Classify first:

```bash
. "$HOME/.agents/skills/implementer/wt-anchor.sh"
case "$PWD" in
  "$(wt_pool_dir)"/*) echo "POOL SLOT — warm and persistent; reuse as-is" ;;
  ~/.paseo/worktrees/*|*/.claude/worktrees/*) echo "HARNESS SCRATCH — take a pool slot" ;;
  *) echo "genuinely isolated worktree — Step 0 applies" ;;
esac
```

**Migration (one-time per repo).** Historical layouts: `<toplevel>/.worktrees/pool` and
`<git-common-dir>/wt-pool/pool`. `wt-migrate-anchor.sh [--dry-run]` moves slots with their
dependency trees, rewrites each `.git/worktrees/<name>/gitdir`, prunes, verifies. Refuses
(exit 3 in pool-take) while unmigrated, so a forgotten migration surfaces instead of
silently reinstalling. Do not run while an agent works in a slot; do not hand-move pool
directories (`gitdir` rewrite + prune are both required; `git worktree repair` does NOT fix
a moved worktree — it fixes the inverse corruption).

**Sweep rule (Phase 1b retention):** prune a lane worktree only when merged/abandoned AND
older than 7 days. The sweep MUST skip `$SELF`, `$POOL/*`, and harness directories —
`git worktree list` enumerates all of them and an unguarded `--force` destroys the pool.
Prune by lane branch pattern, never "every worktree". A wrongly deleted slot costs a full
reinstall; a stale lane worktree costs a few MB.

---

## §E CI failure triage & Mergeability Preflight

**Preflight — before EVERY CI wait.** A CONFLICTING/DIRTY/BEHIND PR has no buildable merge
ref: GitHub never starts `pull_request` workflows, so polls see "no checks" or pending
forever — that is the conflict signature, not a CI outage, and never a reason to escalate.

```bash
gh pr view <N> --json mergeable,mergeStateStatus,headRefOid,statusCheckRollup
gh run list --branch <headRefName> --limit 1 --json headSha,status,conclusion
```

Rebase immediately (pre-authorized for YOUR PR's head branch) when: `mergeable=CONFLICTING`;
`mergeStateStatus` ∈ {DIRTY, BEHIND}; zero checks AND newest run's headSha ≠ PR head SHA.
`git fetch origin <base> && git rebase origin/<base> && git push --force-with-lease origin
HEAD:<head>` — never `--force`, never master/main, never another agent's checked-out branch.
Conflicts in generated artifacts are re-generated with their owning script. A conflicted PR
is never BLOCKED — you are the author; resolve it.

**Triage a red check before touching code:**

```bash
git fetch origin "$BASE_BRANCH"; git rev-list --count HEAD.."origin/$BASE_BRANCH"
gh run view <RUN_ID> --log-failed
```

| Category | Indicator | Action |
| --- | --- | --- |
| [A] Out-of-sync | behind base; failures in untouched areas | sync (Phase 2.5) → push → re-check. Do NOT "fix" code |
| [B] Merge conflict | conflict markers | resolve per Phase 2.5, or BLOCKED. No fix-worker |
| [C] Your code bug | failures in files you changed; up to date | diagnose from logs, fix (fix-worker ok), push |
| [D] Infrastructure | runner deaths, timeouts, network | `gh run rerun <RUN_ID> --failed` |
| [E] Third-party / dependency | new upstream broke the job | BLOCKED with evidence. Do not code around it |
