#!/bin/zsh
set -eu
exec /usr/bin/osascript -l JavaScript "${0:A:h}/json-workflow.js" format "$ANYWHERE_REQUEST_FILE"
