#!/usr/bin/env bash
# fm-dnp-init-hook.sh - Claude Code UserPromptSubmit hook that routes the
# captain's `.init dev` command to the dnp-flow skill
# (.agents/skills/dnp-flow/SKILL.md owns the procedure).
#
# Usage: registered in .claude/settings.json; reads the hook payload JSON on
# stdin.
#
# When the submitted prompt, after leading whitespace, starts with `.init dev`
# followed by whitespace or the end of the prompt, it prints one
# hookSpecificOutput JSON object whose additionalContext tells the session to
# load the dnp-flow skill with the rest of that first line as its arguments.
# Every other prompt is a silent no-op.
# The fast path is a substring test on the raw payload, so an ordinary prompt
# never starts jq.
# It never blocks or alters a prompt: a missing jq, an unreadable payload, or
# any other failure exits 0 with no output.
# Harnesses without a prompt-submit hook rely on the skill's own description,
# which names the same trigger.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
case "$PAYLOAD" in
  *.init*) ;;
  *) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty | strings' 2>/dev/null) || exit 0
PROMPT=${PROMPT#"${PROMPT%%[![:space:]]*}"}
LINE=${PROMPT%%$'\n'*}
LINE=${LINE%$'\r'}
[[ $LINE =~ ^\.init[[:blank:]]+dev([[:blank:]]+(.*))?$ ]] || exit 0
ARGS=${BASH_REMATCH[2]:-}
ARGS=${ARGS%"${ARGS##*[![:space:]]}"}

if [ -n "$ARGS" ]; then
  DESC="with arguments: $ARGS"
else
  DESC="with no arguments"
fi
CONTEXT="Firstmate dnp-flow trigger: the captain's prompt starts with \`.init dev\`. Load the \`dnp-flow\` skill now and run its \`.init dev\` procedure $DESC. Treat any further lines of the prompt as the captain's request for the chain."
jq -cn --arg ctx "$CONTEXT" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}' 2>/dev/null || true
exit 0
