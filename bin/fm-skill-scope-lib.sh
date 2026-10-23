#!/usr/bin/env bash
# fm-skill-scope-lib.sh - parsing for a task's optional data/<id>/skills-off
# list, sourced by bin/fm-spawn.sh.
#
# The file names skills one per line that a ship or scout worker must not load
# (blank lines and # comment lines are allowed). bin/fm-spawn.sh's header owns
# how each runtime honors it: Claude receives the names as "off" entries in its
# skillOverrides launch setting, and every other runtime has no enforced
# skill scoping, so the list is reported and the brief's instructions are the
# only limit. .agents/skills/dnp-flow/SKILL.md is the writer.

# fm_skill_scope_names <task-data-dir>: print the newline-separated names,
# empty when the file is absent or lists nothing. Non-zero with the reason on
# stderr when the file or an entry is invalid.
fm_skill_scope_names() {
  local file=$1/skills-off line names='' present
  present=$(perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect skills-off: $!\n" }
  ' -- "$file") || return 1
  [ "$present" = 1 ] || return 0
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if [ -n "${line//[A-Za-z0-9_.:-]/}" ]; then
      echo "error: $file has a malformed entry '$line'; expected one skill name per line using only letters, digits, _ . : and - (blank lines and # comment lines are allowed)" >&2
      return 1
    fi
    names="$names$line"$'\n'
  done <"$file" || {
    echo "error: cannot read $file" >&2
    return 1
  }
  printf '%s' "$names"
}

# fm_skill_scope_claude_settings <names>: print the JSON members, with a
# leading comma, that turn each name off in Claude's skillOverrides setting;
# empty when <names> is empty.
fm_skill_scope_claude_settings() {
  local names=$1 name members=''
  [ -n "$names" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    members="${members:+$members,}\"$name\":\"off\""
  done <<<"$names"
  printf ',"skillOverrides":{%s}' "$members"
}
