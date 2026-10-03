#!/usr/bin/env bash
# no-ai-attribution.sh — makes the authorship law in CLAUDE.md real instead of stated.
#
# A law that is only written down gets broken by the next session that did not read it.
# This blocks the commit itself, at the moment it is attempted, with the reason.
#
# Blocks: any `git commit` whose message carries an AI co-author trailer, a "Generated
# with" line, or an AI tool name; and any `git config` that would set an AI as the author.
#
# Does NOT block: AI_USAGE.md content, or the word "claude" in ordinary source code and
# prose. Only the commit-authorship surface is guarded, because that is the one that is
# permanent once pushed.
#
# Self-test:  bash .claude/hooks/no-ai-attribution.sh --self-test
set -uo pipefail

BAD='co-authored-by:[[:space:]]*(claude|anthropic|copilot|chatgpt|gpt-|openai|cursor|codex)|generated[[:space:]]+with[[:space:]]+\[?(claude|chatgpt|copilot|cursor)|🤖[[:space:]]*generated'
# The law's letter, not only its trailer shape: no AI name in a commit message at all. The one
# exclusion is the filename CLAUDE.md, whose own commit necessarily names it. Measured on
# 2026-09-04: a message that DESCRIBED this check named the tool and shipped, because the
# first version of this hook looked only for trailers and never opened the -F message file.
NAME='claude|anthropic|copilot|chatgpt|openai|codex'

# text_bad <text>: 1 if the text carries an attribution shape or a bare tool name
text_bad() {
  local t="$1"
  printf '%s' "$t" | grep -qiE "$BAD" && return 0
  printf '%s' "$t" | grep -viE 'claude\.md' | grep -qiE "$NAME" && return 0
  return 1
}

check() {
  local cmd="$1"
  # only inspect git commit / git config author-setting commands
  printf '%s' "$cmd" | grep -qiE 'git[[:space:]]+(commit|config[[:space:]]+user\.)' || return 0
  # The trailer shapes are checked against the whole command line, as before.
  if printf '%s' "$cmd" | grep -qiE "$BAD"; then
    echo "⛔ BLOCKED: AI attribution in a commit." >&2
    echo "   CLAUDE.md: every commit is authored by the owner alone. A trailer in a" >&2
    echo "   pushed commit is permanent. Disclosure belongs in AI_USAGE.md, not here." >&2
    return 1
  fi
  # The bare-name rule is checked against the MESSAGE only: the -m argument, or the -F file
  # opened from disk. Not the whole command line, which may carry a tool name in a path.
  local message_text=""
  local inline
  inline=$(printf '%s' "$cmd" | grep -oE -- "(-m|--message)[= ]+(\"[^\"]*\"|'[^']*')" | sed -E "s/^(-m|--message)[= ]+//; s/^[\"']//; s/[\"']\$//")
  [ -n "$inline" ] && message_text="$inline"
  local message_file
  message_file=$(printf '%s' "$cmd" | grep -oE -- '(-F|--file)[= ]+[^ ;&|]+' | head -1 | sed -E 's/^(-F|--file)[= ]+//')
  if [ -n "$message_file" ] && [ -f "$message_file" ]; then
    message_text="$message_text
$(cat "$message_file")"
  fi
  if [ -n "$message_text" ] && text_bad "$message_text"; then
    echo "⛔ BLOCKED: AI name or attribution in the commit message." >&2
    echo "   CLAUDE.md: no AI name in a commit message. Say what changed, not who helped;" >&2
    echo "   the disclosure lives in AI_USAGE.md." >&2
    return 1
  fi
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  fail=0
  # CONTROL: a known-bad input MUST be caught, or this guard is decorative.
  if check 'git commit -m "feat: x

Co-Authored-By: Claude <noreply@anthropic.com>"' 2>/dev/null; then
    echo "SELF-TEST FAIL: did not catch a Co-Authored-By trailer"; fail=1
  else echo "ok: catches Co-Authored-By trailer"; fi
  if check 'git commit -m "🤖 Generated with [Claude Code]"' 2>/dev/null; then
    echo "SELF-TEST FAIL: did not catch a Generated-with line"; fail=1
  else echo "ok: catches Generated-with line"; fi
  # CONTROL the other way: a clean commit must PASS, or the guard blocks real work.
  if check 'git commit -F /tmp/msg'; then echo "ok: clean commit passes"
  else echo "SELF-TEST FAIL: blocked a clean commit"; fail=1; fi
  if check 'git commit -m "docs: mention that Cl'"aude"' helped"' 2>/dev/null; then
    echo "SELF-TEST FAIL: did not catch a bare tool name in the message"; fail=1
  else echo "ok: catches a bare tool name in the message"; fi
  if check 'git commit -m "docs: CLAUDE.md, how this repository is built"'; then echo "ok: the filename CLAUDE.md alone passes"
  else echo "SELF-TEST FAIL: blocked a message that only names the file CLAUDE.md"; fail=1; fi
  tmpmsg=$(mktemp)
  printf 'ci: tighten the check\n\nThe word "cl%s" is matched everywhere.\n' 'aude' > "$tmpmsg"
  if check "git commit -F $tmpmsg" 2>/dev/null; then
    echo "SELF-TEST FAIL: did not open the -F message file"; fail=1
  else echo "ok: opens the -F message file and catches a bare tool name"; fi
  printf 'docs: CLAUDE.md, how this repository is built\n\nThe rules every change follows.\n' > "$tmpmsg"
  if check "git commit -F $tmpmsg"; then echo "ok: a clean -F message file passes"
  else echo "SELF-TEST FAIL: blocked a clean -F message file"; fail=1; fi
  tmpdir=$(mktemp -d "/tmp/claude-XXXX")
  printf 'docs: a clean message\n' > "$tmpdir/msg"
  if check "git commit -F $tmpdir/msg"; then echo "ok: a tool name in a PATH on the command line does not block a clean message"
  else echo "SELF-TEST FAIL: blocked a clean commit because a path carried a tool name"; fail=1; fi
  rm -rf "$tmpdir"
  rm -f "$tmpmsg"
  if check 'grep -r claude docs/'; then echo "ok: non-git command passes"
  else echo "SELF-TEST FAIL: blocked a non-git command"; fail=1; fi
  [ $fail -eq 0 ] && echo "SELF-TEST PASSED" || echo "SELF-TEST FAILED"
  exit $fail
fi

# hook mode: the tool call arrives as JSON on stdin
input=$(cat 2>/dev/null || true)
cmd=$(printf '%s' "$input" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: print("")' 2>/dev/null || true)

check "$cmd" || exit 2
exit 0
