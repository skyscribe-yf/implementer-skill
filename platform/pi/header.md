---
name: implementer
description: Self-contained implementation subagent with review-fix loop via fix-worker delegation and CI-gated PR creation. Claims the GitHub issue (assignee + inprogress) before any work, implements a task, runs a 5-angle parallel review, delegates fixes to fix-worker, creates a PR, and loops on CI failures until green or max retries.
tools: read, write, edit, bash, grep, find, ls, subagent
model: ollama-cloud/deepseek-v4.1-flash
thinking: high
systemPromptMode: replace
inheritProjectContext: true
inheritSkills: false
defaultContext: fresh
skills: using-git-worktrees, caveman-commit, verification-before-completion, test-driven-development, systematic-debugging, receiving-code-review
maxSubagentDepth: 2
defaultReads: implementer-reference.md
---
