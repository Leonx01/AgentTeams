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
if ! grep -Fq 'grep -Fq "**Name:** Manager" /root/manager-workspace/SOUL.md' "${RUNNER}" ||
    ! grep -Fq 'grep -Fq "**Language:** Always respond in English" /root/manager-workspace/SOUL.md' "${RUNNER}"; then
    fail "Manager identity setup must accept the validated SOUL state without a marker file"
fi

git_collab_test="${SCRIPT_DIR}/test-14-git-collab.sh"
if ! grep -Fq 'WORKER_CREATE_PIDS+=("$!")' "${git_collab_test}"; then
    fail "test 14 must provision missing collaboration Workers concurrently"
fi
if ! grep -Fq 'wait_worker_provisioned "${w}" 120' "${git_collab_test}"; then
    fail "test 14 must wait for deterministic Worker provisioning before prompting Manager"
fi
if ! grep -Fq 'Workers with usernames exactly' "${git_collab_test}" ||
    ! grep -Fq 'are already provisioned' "${git_collab_test}"; then
    fail "test 14 must tell Manager to reuse the pre-provisioned collaboration Workers"
fi
if ! grep -Fq 'matrix_wait_for_user_joined "${MANAGER_TOKEN}" "${PROJECT_ROOM}"' "${git_collab_test}"; then
    fail "test 14 must verify project-room membership before waiting for git progress"
fi
if ! grep -Fq 'MEMBERSHIP_PIDS+=("$!")' "${git_collab_test}"; then
    fail "test 14 must verify project-room memberships concurrently"
fi
if ! grep -Fq 'overall timeout: 300s, no-activity timeout: 90s' "${git_collab_test}" ||
    ! grep -Fq 'PROJECT_ACTIVITY=$(matrix_read_messages' "${git_collab_test}"; then
    fail "test 14 must use a bounded activity-aware collaboration deadline"
fi
if ! grep -Fq 'matrix_send_message "${MANAGER_TOKEN}" "${PROJECT_ROOM}" "${PHASE1_MESSAGE}"' "${git_collab_test}" ||
    ! grep -Fq 'PHASE2_SENT=1' "${git_collab_test}" ||
    ! grep -Fq 'PHASE3_SENT=1' "${git_collab_test}" ||
    ! grep -Fq 'PHASE4_SENT=1' "${git_collab_test}"; then
    fail "test 14 must schedule all four phases deterministically from observed git progress"
fi

team_dag_test="${SCRIPT_DIR}/test-21-team-project-dag.sh"
if ! grep -Fq 'requesting one immediate message-tool retry' "${team_dag_test}" ||
    ! grep -Fq 'CORRECTION_SENT=true' "${team_dag_test}"; then
    fail "test 21 must retry one intent-only Leader response before failing fast"
fi
if ! grep -Fq 'COORDINATION_POLL_SECONDS="${COORDINATION_POLL_SECONDS:-10}"' "${team_dag_test}" ||
    ! grep -Fq 'MAX_COORDINATION_POLLS="${MAX_COORDINATION_POLLS:-12}"' "${team_dag_test}"; then
    fail "test 21 must poll frequently without reducing its 120-second ceiling"
fi

multi_worker_test="${SCRIPT_DIR}/test-06-multi-worker.sh"
if grep -Fq '"${MANAGER_BASELINE_EVENT}" "${COLLAB_ID}" 180' "${multi_worker_test}"; then
    fail "test 06 must not wait for an optional correlation echo after the project action has started"
fi
if ! grep -Fq 'Manager created the correlated project room' "${multi_worker_test}"; then
    fail "test 06 must use the uniquely named project room as its correlated acknowledgement"
fi

skills_test="${SCRIPT_DIR}/test-24-skills-management.sh"
if ! grep -Fq 'copaw) BUILTIN_SKILL="file-sharing"' "${skills_test}" ||
    ! grep -Fq 'minio_wait_for_file "agents/${TEST_WORKER}/skills/${BUILTIN_SKILL}/SKILL.md" 30' "${skills_test}"; then
    fail "test 24 must bound the eventual-consistency wait for built-in skill mirroring"
fi

echo "Integration test plan checks passed."
