#!/bin/zsh
set -eu
print -r -- "${ANYWHERE_CONFIG_PREFIX:-Demo}: request received"
# JSON is data. A Go/Rust backend can open this path and decode input + invocation.
/bin/cat "$ANYWHERE_REQUEST_FILE"
print
for step in {1..5}; do
  print -r -- "step $step / 5"
  /bin/sleep 1
done
