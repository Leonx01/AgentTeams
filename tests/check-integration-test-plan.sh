#!/bin/bash
# Verify that the integration orchestrator selects tests deterministically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run-all-tests.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "${actual}" != "${expected}" ]; then
        printf 'FAIL: %s\nExpected:\n%s\nActual:\n%s\n' \
            "${message}" "${expected}" "${actual}" >&2
        exit 1
    fi
}

controller_plan=$(bash "${RUNNER}" \
    --test-filter "15 17 18 19 20 22 23 24 25 100" \
    --list-tests)

expected_controller_plan=$(cat <<'EOF'
test-15-import-worker-zip.sh
test-17-worker-config-verify.sh
test-18-team-config-verify.sh
test-19-human-and-team-admin.sh
test-20-inline-worker-config.sh
test-22-delete-worker-cleanup.sh
test-23-runtime-switch.sh
test-24-skills-management.sh
test-25-name-validation.sh
test-100-cleanup.sh
EOF
)

assert_eq "${expected_controller_plan}" "${controller_plan}" \
    "controller shard must use natural numeric order with cleanup last"

llm_plan=$(bash "${RUNNER}" --test-filter "01 02 03 04 05 06" --list-tests)
if echo "${llm_plan}" | grep -q 'test-100-cleanup.sh'; then
    fail "cleanup must not be injected into a shard that did not select it"
fi

if bash "${RUNNER}" --test-filter "999" --list-tests >/dev/null 2>&1; then
    fail "an empty test selection must fail"
fi

if ! grep -Fq 'minio_wait_for_content "${TASK_RESULT}" "${RESULT_MARKER}" 300' \
    "${SCRIPT_DIR}/test-03-assign-task.sh"; then
    fail "test 03 must wait for correlated result content, not only file existence"
fi

if ! grep -A5 -F 'Task brief was not created within 120s' \
    "${SCRIPT_DIR}/test-03-assign-task.sh" | grep -Fq 'exit 1'; then
    fail "test 03 must fail fast when the task brief dependency is missing"
fi

echo "Integration test plan checks passed."
