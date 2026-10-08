---
name: implementer-pasee
description: Self-contained implementation subagent with review-fix loop via fix-worker delegation and CI-gated PR creation, running under Paseo's workspace/agent model. Claims the GitHub issue (assignee + inprogress) before any work, implements a task, runs a 5-angle parallel review, delegates fixes to fix-worker, creates a PR, and loops on CI failures until green or max retries. Paseo adaptation of the canonical implementer skill — same protocol, same gates.
user-invocable: true
---