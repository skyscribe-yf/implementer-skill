# Implementer Reference Data (pi)

Static, pi-specific reference tables for the implementer agent. Everything protocol-shaped lives
in the shared body of `implementer.md` — do not duplicate protocol here, so the three platform
copies cannot drift.

## Review Models

| Provider/Model | Strength | Cost | Good for |
|---|---|---|---|
| `ollama-cloud/deepseek-v4.1-flash` | Fast reasoning | $ | All review roles (spec compliance, architecture, code quality, re-reviews, round rotation) |

### Default Reviewer Assignments

The 5 review angles (`correctness`, `tests`, `simplicity`, `security`, `contracts`) all run on
`ollama-cloud/deepseek-v4.1-flash`, or on the model from the user's `subagents.agentOverrides`
when one is configured:

- **correctness / tests / simplicity / contracts** (`reviewer`)
- **security** (`reviewer`; `reviewers.security-reviewer` for auth/PIPL-heavy diffs)

### Round Rotation Schedule

- **Rounds 1-2**: the 5-angle fan-out (default or task-specified model)
- **Rounds 3-4**: the same 5 angles, moved to the alternate model when one is configured
- **Rounds 5+**: rotate back, or move one angle per round

Example:
- Round 1: correctness, tests, simplicity, security, contracts
- Round 2: same (verify fixes)
- Round 3: the same 5 angles on the alternate model (rotated)
- Round 4: same (verify round 3 fixes)
- Round 5+: back to the round 1 set

## PR Title Prefixes (Conventional Commits)

- `feat:` new feature
- `fix:` bug fix
- `refactor:` code restructuring
- `test:` adding/updating tests
- `chore:` maintenance, config, CI
