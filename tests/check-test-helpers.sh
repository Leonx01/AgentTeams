#!/bin/bash
# Verify assertion helpers remain reliable for large captured content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TEST_CONTROLLER_CONTAINER="test-controller"
export TEST_AGENT_CONTAINER="test-agent"
# shellcheck source=lib/test-helpers.sh
source "${SCRIPT_DIR}/lib/test-helpers.sh"

large_haystack="needle"
printf -v large_haystack 'needle%*s' 1048576 ''

assert_contains "${large_haystack}" "needle" "large exact assertion"
assert_contains_i "${large_haystack}" "NEEDLE" "large case-insensitive assertion"

if [ "${TESTS_FAILED}" -ne 0 ]; then
    echo "FAIL: large assertions were misclassified under pipefail" >&2
    exit 1
fi

if sed -n '/^assert_contains()/,/^}/p' "${SCRIPT_DIR}/lib/test-helpers.sh" |
    grep -Fq '| grep -q'; then
    echo "FAIL: assert_contains must not use an early-exit pipeline under pipefail" >&2
    exit 1
fi
if sed -n '/^assert_contains_i()/,/^}/p' "${SCRIPT_DIR}/lib/test-helpers.sh" |
    grep -Fq '| grep -qi'; then
    echo "FAIL: assert_contains_i must not use an early-exit pipeline under pipefail" >&2
    exit 1
fi

helper_calls="$(mktemp)"
trap 'rm -f "${helper_calls}"' EXIT
exec_in_manager() {
    printf '%s\n' "$*" >> "${helper_calls}"
    case "$*" in
        *"/manager/openclaw.json"|*"/agents/alice/openclaw.json")
            printf '%s\n' \
                '{"channels":{"matrix":{"groupAllowFrom":["@team-lead:hs.local"]}}}'
            ;;
        *) printf '%s\n' '{}' ;;
    esac
}
export STORAGE_PREFIX="agentteams/test-storage"

wait_agent_matrix_allow_contains \
    "manager" ".channels.matrix.groupAllowFrom" "@team-lead:" 1
wait_agent_matrix_allow_contains \
    "alice" ".channels.matrix.groupAllowFrom" "@team-lead:" 1

grep -Fq "agentteams/test-storage/manager/openclaw.json" "${helper_calls}"
grep -Fq "agentteams/test-storage/agents/alice/openclaw.json" "${helper_calls}"

worker_container_name() {
    printf '%s\n' "agentteams-worker-fast-fail"
}
docker() {
    return 1
}
exec_in_agent() {
    printf '%s\n' \
        '{"containerState":"create_failed","message":"failed to pull image example.invalid/worker:test"}'
}
dump_diagnostics() {
    return 0
}
sleep() {
    return 0
}

if terminal_output="$(wait_for_worker_container "fast-fail" 30 2>&1)"; then
    echo "FAIL: wait_for_worker_container accepted terminal controller state" >&2
    exit 1
fi
if ! grep -Fq "create_failed" <<<"${terminal_output}"; then
    echo "FAIL: wait_for_worker_container did not report terminal controller state" >&2
    exit 1
fi

echo "Test helper checks passed."
