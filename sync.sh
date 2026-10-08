#!/usr/bin/env bash
# sync.sh — install ONE canonical implementer skill to every agent platform.
#
# Source of truth:  SKILL.md (body) + platform/<name>/{header,appendix}.md
# Targets:
#   ~/.agents/skills/implementer/                      generic agents (Claude Code / DimCode / …)
#   ~/.pi/agent/agents/implementer.md                  pi agent spec (+ implementer-reference.md)
#   ~/.codex/skills/codex-implementation-loop/SKILL.md Codex skill
#   ~/.agents/skills/implementer-pasee/SKILL.md         Paseo runtime (workspace/agent model)
#
# The canonical body is delimited by BEGIN/END markers in every assembled copy, so --check can
# prove all installs carry byte-identical logic. Edit SKILL.md or the platform files, then
# re-run this script — never edit an installed copy.
#
# Usage: ./sync.sh [--check] [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/SKILL.md"
BEGIN_MARK="<!-- BEGIN canonical body"
END_MARK="<!-- END canonical body -->"

GENERIC_DIR="${GENERIC_DIR:-$HOME/.agents/skills/implementer}"
PI_DIR="${PI_DIR:-$HOME/.pi/agent/agents}"
PI_AGENT="$PI_DIR/implementer.md"
PI_REF="$PI_DIR/implementer-reference.md"
CODEX_SKILL="${CODEX_SKILL:-$HOME/.codex/skills/codex-implementation-loop/SKILL.md}"
PASEO_DIR="${PASEO_DIR:-$HOME/.agents/skills/implementer-pasee}"
PASEO_SKILL="$PASEO_DIR/SKILL.md"

die() { echo "error: $*" >&2; exit 1; }
[ -f "$SRC" ] || die "SKILL.md not found in $ROOT"

# Body of the canonical skill: everything after its YAML frontmatter.
body() {
  awk 'NR==1 && $0=="---" {fm=1; next} fm==1 {if ($0=="---") fm=2; next} {print}' "$SRC"
}

# Canonical body as installed: between markers when assembled, after frontmatter when plain.
installed_body() {
  if grep -qF "$BEGIN_MARK" "$1" 2>/dev/null; then
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" 'index($0,b){f=1;next} index($0,e){f=0} f{print}' "$1"
  else
    awk 'NR==1 && $0=="---" {fm=1; next} fm==1 {if ($0=="---") fm=2; next} {print}' "$1"
  fi
}

hash_body() { sha256sum | cut -d' ' -f1; }

assemble() { # header.md appendix.md -> stdout  (body must round-trip byte-identically)
  cat "$1"
  printf '%s (synced from implementer-skill/SKILL.md — edit that file, not this copy) -->\n' "$BEGIN_MARK"
  body
  printf '%s\n' "$END_MARK"
  cat "$2"
}

install_generic() {
  mkdir -p "$GENERIC_DIR"
  cp "$SRC" "$GENERIC_DIR/SKILL.md"
  cp "$ROOT"/REFERENCE.md "$GENERIC_DIR/REFERENCE.md"
  cp "$ROOT"/pool-take.sh "$ROOT"/pool-release.sh \
     "$ROOT"/wt-anchor.sh "$ROOT"/wt-pool.sh "$ROOT"/wt-migrate-anchor.sh "$GENERIC_DIR/"
  chmod +x "$GENERIC_DIR"/*.sh
  echo "→ $GENERIC_DIR/ (SKILL.md + 5 scripts)"
}

install_pi() {
  mkdir -p "$PI_DIR"
  assemble "$ROOT/platform/pi/header.md" "$ROOT/platform/pi/appendix.md" > "$PI_AGENT"
  cp "$ROOT/platform/pi/implementer-reference.md" "$PI_REF"
  echo "→ $PI_AGENT (+ implementer-reference.md)"
}

install_codex() {
  mkdir -p "$(dirname "$CODEX_SKILL")"
  assemble "$ROOT/platform/codex/header.md" "$ROOT/platform/codex/appendix.md" > "$CODEX_SKILL"
  echo "→ $CODEX_SKILL"
}

# Paseo 装成独立 skill 而非 pi agent spec：它的 frontmatter 语义是 user-invocable
# skill，不是 agent 定义。池脚本仍从 generic 目录取，不重复安装一份。
install_paseo() {
  mkdir -p "$PASEO_DIR"
  assemble "$ROOT/platform/paseo/header.md" "$ROOT/platform/paseo/appendix.md" > "$PASEO_SKILL"
  echo "→ $PASEO_SKILL"
}

check_one() { # label file
  local label="$1" file="$2" want got
  want="$(body | hash_body)"
  if [ ! -f "$file" ]; then
    echo "✗ $label — missing: $file"
    return 1
  fi
  got="$(installed_body "$file" | hash_body)"
  if [ "$got" = "$want" ]; then
    echo "✓ $label — canonical body in sync"
  else
    echo "✗ $label — canonical body DIFFERS: $file"
    return 1
  fi
}

check_all() {
  local rc=0
  check_one "generic" "$GENERIC_DIR/SKILL.md" || rc=1
  check_one "pi" "$PI_AGENT" || rc=1
  check_one "codex" "$CODEX_SKILL" || rc=1
  check_one "paseo" "$PASEO_SKILL" || rc=1
  [ -f "$PI_REF" ] && echo "✓ pi reference present" || { echo "✗ pi reference missing: $PI_REF"; rc=1; }
  check_model_policy || rc=1
  return $rc
}

CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
CODEX_AGENTS_DIR="${CODEX_AGENTS_DIR:-$HOME/.codex/agents}"

# Banned tiers: gpt-6-astra / gpt-5.6-sol cost 5x+ the luna/terra tier and leaked into every
# implementer lane, because unnamed spawns inherit [agents] default_subagent_model while named
# agents pin model in ~/.codex/agents/*.toml. Both places are checked so a one-line edit can't
# silently re-arm the expensive fallback.
check_model_policy() {
  local rc=0 hits f
  local re='^[[:space:]]*(default_subagent_)?model[[:space:]]*=.*(gpt-6-astra|gpt-5\.6-sol)'
  if [ -f "$CODEX_CONFIG" ]; then
    hits="$(grep -nE "$re" "$CODEX_CONFIG" || true)"
    if [ -n "$hits" ]; then
      echo "✗ codex model policy — banned model in $CODEX_CONFIG:"
      printf '%s\n' "$hits"
      rc=1
    else
      echo "✓ codex default_subagent_model off the banned tiers"
    fi
  else
    echo "• codex model policy — skipped: no $CODEX_CONFIG"
  fi
  for f in "$CODEX_AGENTS_DIR"/*.toml; do
    [ -f "$f" ] || continue
    hits="$(grep -nE "$re" "$f" || true)"
    if [ -n "$hits" ]; then
      echo "✗ codex model policy — banned model in $f:"
      printf '%s\n' "$hits"
      rc=1
    fi
  done
  return $rc
}

case "${1:-}" in
  "")
    install_generic; install_pi; install_codex; install_paseo
    echo
    check_all
    ;;
  --dry-run)
    echo "would install: $GENERIC_DIR/, $PI_AGENT, $PI_REF, $CODEX_SKILL, $PASEO_SKILL"
    ;;
  --check)
    check_all
    ;;
  *)
    echo "usage: $0 [--check|--dry-run]" >&2
    exit 2
    ;;
esac
