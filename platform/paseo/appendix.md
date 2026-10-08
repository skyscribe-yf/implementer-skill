---

## Platform notes — Paseo runtime

Everything above is the shared protocol. This section only translates it to Paseo's
workspace/agent model. Read the two subsections below before dispatching any lane — the
one-workspace-per-directory constraint is not optional and it is what makes lanes safe.

### The one rule that governs everything else

**In Paseo a workspace *is* a directory.** An agent's working directory is decided entirely by
the workspace it belongs to:

- `paseo_create_agent` (agent-scoped) accepts `workspaceId`. It does **not** accept `cwd`.
- Omit `workspaceId` → the child inherits the **caller's** workspace, and therefore the
  caller's directory.
- Supply a different `workspaceId` → the child gets that workspace's directory.

So "all lanes share one workspace" literally means "all lanes write to one directory".
There is no configuration that gives several agents different directories inside a single
workspace. Plan lane directories at dispatch time; they cannot be changed afterwards.

### Dispatch

```typescript
// 1. Independent lane → its own pooled worktree slot, hence its own workspace.
//    Shell: POOL="$HOME/.agents/skills/implementer"; wt=$("$POOL/pool-take.sh" lane-a "issue 3883")
//    then: paseo_create_workspace({ isolation: "worktree", worktreeSlug: "lane-a", ... })
//          paseo_create_agent({ workspaceId: <that>, provider, model, ... })

// 2. Read-only reviewer, or a second lane that must NOT write → inherit the caller's
//    workspace by omitting workspaceId entirely.
paseo_create_agent({ provider, model, initialPrompt })   // no workspaceId
```

- Always pass `background: true` + `notifyOnFinish: true`; converge on the notification.
  Do not poll `list_agents` / `get_agent_status`.
- `cwd` appears on the legacy `create_agent` shape but that shape is marked
  `COMPAT(nestedCreateAgentPlacement)` and is slated for removal — do not use it. Route
  every directory decision through a workspace.
- Do **not** use the built-in `workflow` tool to dispatch lanes that write files. Its
  children are invisible to Paseo: no tab, no state, no completion notification, and a
  failed parent leaves orphans still writing to the worktree.

### Grouping lanes into shared workspaces

Lanes are grouped by **write-set overlap**, not by issue count:

| Lanes touch | Strategy | Result |
|---|---|---|
| Disjoint files / disjoint directories | one workspace + one pooled slot **each** | full isolation |
| Provably the same files, forced serial | one workspace, lanes run **one at a time** | shared deps, no concurrent writer |
| Same files, must run parallel | **do not share** — give each its own slot | isolation wins; serialise instead |

A shared workspace is only safe when at most one agent writes at a time. Two agents in one
directory is the double-writer failure that produces orphaned worktrees and lost commits.

### Worktree pool

`pool-take.sh` / `pool-release.sh` / `wt-pool.sh` / `wt-anchor.sh` / `wt-migrate-anchor.sh`
live next to the installed skill:

```
POOL_SCRIPTS="$HOME/.agents/skills/implementer"
```

The pool anchor is `<repo-root>.wt-pool` — a **sibling** of the repo, deliberately outside
`.git`. Do not move it back under `.git`: Paseo's `workspace-git-service` observes
`git-common-dir` as its file-observer root and `linux.js` caps that at
`MAX_WATCHED_DIRECTORIES = 5000`, which a pool of full checkouts blows through, degrading
git metadata to polling. If you find slots under `<repo>/.git/wt-pool/pool`, run
`wt-migrate-anchor.sh` (dependency trees move with the directory; nothing reinstalls).

`pool-take.sh` refuses to run while an unmigrated legacy pool exists — that is deliberate.
It prevents silently creating an empty pool at the new anchor and triggering a full
dependency reinstall. Read the exit-3 message; it names the fix.

### Reading lane state

- `paseo_list_agents({ cwd })` finds agents by directory; lanes on separate slots appear
  separately.
- `paseo_get_agent_activity({ agentId })` gives a curated timeline; prefer it over reading
  raw session files.
- An agent card's click target is **not** a reliable signal of which workspace it runs in —
  clicking always routes to the agent's own workspace. Read `workspaceId` from
  `paseo_get_agent_status` instead.

### Session notes

- Paseo assigns a workspace per agent by default. Do not fight it: create the workspace
  deliberately with `paseo_create_workspace`, then pass its id to `create_agent`.
- Archiving a parent agent detaches children that carry a `paseo.open-agent-tab.*` label
  instead of archiving them with the parent. This label is internal bookkeeping — do not
  set or clear it by hand, and do not read card behaviour as a function of it.