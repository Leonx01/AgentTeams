#!/bin/bash
# Unit checks for event-correlated Matrix wait helpers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
set -euo pipefail

sleep() {
    :
}

matrix_read_messages() {
    cat <<'EOF'
{
  "chunk": [
    {
      "sender": "@manager:example",
      "type": "m.room.message",
      "event_id": "$new-match",
      "content": {"body": "task-123 accepted"}
    },
    {
      "sender": "@manager:example",
      "type": "m.room.message",
      "event_id": "$new-generic",
      "content": {"body": "working on it"}
    },
    {
      "sender": "@manager:example",
      "type": "m.room.message",
      "event_id": "$old",
      "content": {"body": "task-123 stale reply"}
    }
  ]
}
EOF
}

result=$(matrix_wait_for_reply_matching_since \
    token room "@manager" '$old' 'task-123' 10)
matched=$(printf '%s\n' "${result}" | tail -n 1)

if [ "${matched}" != "task-123 accepted" ]; then
    printf 'FAIL: expected correlated new reply, got: %s\n' "${result}" >&2
    exit 1
fi

echo "Matrix wait helper checks passed."
