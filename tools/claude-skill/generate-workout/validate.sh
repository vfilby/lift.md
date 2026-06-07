#!/usr/bin/env sh
# Validate LMWF markdown against the live LiftMark validator.
#
# Usage:
#   validate.sh <file.md>
#   validate.sh < file.md
#   echo "..." | validate.sh
#
# Exits non-zero on HTTP failure; prints the JSON response on stdout.
set -eu

ENDPOINT='https://getlift.md/validate'

if [ $# -ge 1 ]; then
  if [ ! -r "$1" ]; then
    echo "validate.sh: cannot read '$1'" >&2
    exit 2
  fi
  exec curl -fsSL -X POST "$ENDPOINT" \
    -H 'Content-Type: text/markdown' \
    --data-binary "@$1"
fi

exec curl -fsSL -X POST "$ENDPOINT" \
  -H 'Content-Type: text/markdown' \
  --data-binary @-
