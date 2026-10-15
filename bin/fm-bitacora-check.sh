#!/usr/bin/env bash
# Print the captain's bitacora connection checklist for one project.
# Usage: fm-bitacora-check.sh [project]
#   project  A name under $FM_HOME/projects/ or an absolute project root.
#            Omitted: checks every project under $FM_HOME/projects/ in turn;
#            with none present, prints a "pendiente" checklist and exits 2.
#
# Connected means all three hold: the bitacorad daemon is running, the project
# root is in `bitacorad project list`, and `bitacorad hook session-start` for
# that root returns live notes. Read-only: it never registers a project or
# starts the daemon, because connecting is the captain's decision (standing
# preference note "bitacora-connect-and-subagent-model-ask").
#
# Exit: 0 connected (all, when checking every project), 1 not connected (fix
# hints printed), 2 no project yet.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

PROJECT="${1:-}"
if [ -z "$PROJECT" ]; then
  found=0 rc=0
  for dir in "$FM_HOME"/projects/*/; do
    [ -d "$dir" ] || continue
    found=1
    "$0" "$(basename "$dir")" || rc=1
  done
  if [ "$found" = 0 ]; then
    printf '┌ Bitácora · pendiente ┐\n'
    printf ' ⏳ proyecto: pendiente (se evalúa al empezar a trabajar en uno)\n'
    exit 2
  fi
  exit "$rc"
fi

case "$PROJECT" in
  /*) ROOT=$PROJECT ;;
  *) ROOT="$FM_HOME/projects/$PROJECT" ;;
esac
NAME=$(basename "$ROOT")

mark() { if [ "$1" = 1 ]; then printf '✅'; else printf '❌'; fi; }

have_bin=0 daemon=0 registered=0 notes=0
if command -v bitacorad >/dev/null 2>&1; then
  have_bin=1
  pgrep -f 'bitacorad.*serve' >/dev/null 2>&1 && daemon=1
  bitacorad project list 2>/dev/null | grep -qF -- "$ROOT" && registered=1
  if [ -d "$ROOT" ]; then
    notes=$(bitacorad hook session-start --root "$ROOT" 2>/dev/null | grep -c '^note ')
  fi
fi
has_notes=0
[ "${notes:-0}" -gt 0 ] && has_notes=1

printf '┌ Bitácora · %s ┐\n' "$NAME"
printf ' %s bitacorad instalado\n' "$(mark "$have_bin")"
printf ' %s daemon activo\n' "$(mark "$daemon")"
printf ' %s proyecto registrado\n' "$(mark "$registered")"
printf ' %s notas cargadas (%s)\n' "$(mark "$has_notes")" "${notes:-0}"

if [ "$have_bin" = 1 ] && [ "$daemon" = 1 ] && [ "$registered" = 1 ] && [ "$has_notes" = 1 ]; then
  exit 0
fi

printf 'No conectado. Para conectar (requiere tu OK):\n'
[ "$have_bin" = 1 ] || printf '  - instalar bitacorad\n'
[ "$registered" = 1 ] || printf '  - bitacorad project add %s\n' "$ROOT"
[ "$daemon" = 1 ] || printf '  - bitacorad install   # o: bitacorad serve\n'
exit 1
