
---

## Platform notes — pi runtime

Everything above is the shared protocol. This section only translates it to pi's execution
surface.

### Child execution

All child execution goes through the `subagent(...)` tool with a `workflowScript` — direct
execution (`subagent({ agent, task, ... })`) is removed and hard-errors.

```typescript
// One child
subagent({ workflowScript: `return runs.run("scout", { agent: "scout-override.scout", context: "fresh", task: "Explore ..." })` })

// Parallel lanes / parallel review angles
subagent({
  async: true,
  workflowScript: `
    const results = await runs.all([
      { key: "lane-a", agent: "worker-override.worker", task: "..." },
      { key: "lane-b", agent: "worker-override.worker", task: "..." }
    ]);
    return results.map(r => ({ key: r.key, output: r.output }));
  `
})
```

- `async: true` is a top-level field; an async workflow wakes this session when done — never poll
  with `subagent_wait` or sleep loops. One status check after the expected duration is fine.
- Child fields on `runs.run`/`runs.all` items: `agent`, `task`, `context` (`fresh`/`fork`),
  `model`, `worktree`, `maxRuntimeMs`, `toolBudget`, `control: { needsAttentionAfterMs,
  notifyOn: ["needs_attention"] }`, `output`, `outputMode`, `gate`.
- Never pass hard `turnBudget`/`toolBudget` to mutation-capable workers; use a narrow task plus a
  generous `maxRuntimeMs` and `control.notifyOn` instead.
- Agent names must resolve: run `subagent({ action: "list" })` first. When a
  `subagents.agentOverrides` entry exists, the shadow agent is named `{name}-override.{name}`
  (e.g. `scout-override.scout`, `worker-override.worker`, `reviewer-override.reviewer`) and the
  short name is AMBIGUOUS.

### Roles

- Lanes and fix-workers → `worker-override.worker` (or `worker` when no override is configured).
- Reviewers → `reviewer-override.reviewer` (or `reviewer`); `reviewers.security-reviewer` for
  auth/PIPL-heavy diffs.
- Context gathering → `scout-override.scout`.

### Model policy and round rotation

See `implementer-reference.md` (loaded via `defaultReads`). Rounds 3–4 rotate the five angles to
the alternate model when one is configured.

### Session notes

- The platform's `ask_user_question` is the `AskUserQuestion` referenced in Step 1's stale-lock
  path.
- Skill scripts live next to the installed skill: `POOL_SCRIPTS="$HOME/.agents/skills/implementer"`.
- `worktree: true` is the platform-native isolation; prefer a warm pool slot (Phase 1) when one
  exists — it preserves `node_modules`/`.venv` across runs.
