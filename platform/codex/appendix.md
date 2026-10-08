
---

## Platform notes — Codex runtime

Everything above is the shared protocol. This section only translates it to Codex's native
controls.

Earlier revisions of `codex-implementation-loop` described a different, Codex-only loop and told
runs to ignore the skill's lock conventions. That is superseded: the protocol above — Step 0
issue claim, Step 1 lock, verification scope contracts, five-angle review, Phase 2.5 sync,
CI gates — is the single logic on every platform.

### Native controls

- Refer to a custom agent by its exact `name` in every spawn request, and repeat its scope in
  `message`.
- Call `multi_agent_v1__spawn_agent` with `message` and `fork_context`; use
  `multi_agent_v1__wait_agent` for requested results, `multi_agent_v1__send_input` to steer an
  existing agent, and `multi_agent_v1__close_agent` after integration.
- If a Codex surface cannot select a named custom agent, treat the TOML as non-binding and put the
  role instructions directly in `message`.
- Child results are the `Checks run:` / `Deferred gates:` report described above; audit them the
  same way (Phase 1c).

### Roles and model policy

- Read-only mapping / context → `lean-explorer`.
- Lanes and fix-workers → `lean-worker`.
- Reviewers → `lean-reviewer`.

The model lives in the agent TOML (`~/.codex/agents/*.toml`), not in this file — current pins are
`ollama-cloud/deepseek-v4-flash:0731` at reasoning `max`. The dangerous path is **unnamed spawns**
(`agent_type: "default"`/`"worker"`): they ignore the TOMLs and inherit `[agents]
default_subagent_model` from `~/.codex/config.toml`, which is how `gpt-6-astra` got billed for every
lane. Keep that key on `gpt-6.1-sol` (cheaper tiers like luna are too weak for lanes);
`./sync.sh --check` fails if it or any agent TOML pins `gpt-6-astra` or `gpt-5.6-sol`.

`lean-explorer` and `lean-reviewer` always use `fork_context = false`; give them a focused scope
plus acceptance criteria and a diff reference. `lean-worker` starts with `fork_context = false`;
set it to `true` only when implementation depends on parent-thread decisions that cannot be passed
as a concise task brief.

### Shell protocol

The lock, worktree pool, and `gh` steps above are plain shell — run them through the Codex shell
tool. The scripts live next to the installed skill:
`POOL_SCRIPTS="$HOME/.agents/skills/implementer"`.
