#!/bin/bash
# Verify project room Worker joins are bounded, concurrent, and fail fast.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_PROJECT="${SCRIPT_DIR}/../manager/agent/skills/project-management/scripts/create-project.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -Fq 'local deadline=$((SECONDS + 30))' "${CREATE_PROJECT}" || \
    fail "Worker auto-join must use a bounded retry deadline"
grep -Fq 'sleep 2' "${CREATE_PROJECT}" || \
    fail "Worker auto-join must retry without busy waiting"
grep -Fq '.content.membership == "join"' "${CREATE_PROJECT}" || \
    fail "Worker auto-join must accept runtime-driven room joins"
grep -Fq '_worker_auto_join "${worker}" "${ROOM_ID}" &' "${CREATE_PROJECT}" || \
    fail "Worker auto-joins must run concurrently"
grep -Fq 'wait "${WORKER_JOIN_PIDS[$index]}"' "${CREATE_PROJECT}" || \
    fail "project creation must collect every Worker auto-join result"
grep -Fq '_fail "Failed to auto-join Workers to project room:' "${CREATE_PROJECT}" || \
    fail "project creation must fail fast when a required Worker cannot join"

echo "Project room auto-join checks passed."
