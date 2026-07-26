#!/bin/bash
# test-03-assign-task.sh - Case 3: Assign task in Room, Worker completes
# Verifies: Manager relays task to Worker, task brief created in MinIO,
#           Worker completes and writes result

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"
source "${SCRIPT_DIR}/lib/agent-metrics.sh"

test_setup "03-assign-task"

if ! require_llm_key; then
    test_teardown "03-assign-task"
    test_summary
    exit 0
fi

ADMIN_LOGIN=$(matrix_login "${TEST_ADMIN_USER}" "${TEST_ADMIN_PASSWORD}")
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | jq -r '.access_token')

MANAGER_USER="@manager:${TEST_MATRIX_DOMAIN}"

log_section "Assign Task"

# Find Alice's Room (3-party room)
DM_ROOM=$(matrix_find_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}" 2>/dev/null || true)
assert_not_empty "${DM_ROOM}" "DM room with Manager found"

# Wait for Manager Agent to be fully ready (OpenClaw gateway + joined DM room)
wait_for_manager_agent_ready 300 "${DM_ROOM}" "${ADMIN_TOKEN}" || {
    log_fail "Manager Agent not ready in time"
    test_teardown "03-assign-task"
    test_summary
    exit 1
}

# Alice container should be running from test-02; wait to ensure it's up before snapshot
wait_for_worker_container "alice" 60
METRICS_BASELINE=$(snapshot_baseline "alice")
TASK_ID="assign-task-$(date +%s)-$$"
TASK_DIR="shared/tasks/${TASK_ID}"
TASK_SPEC="${TASK_DIR}/spec.md"
TASK_RESULT="${TASK_DIR}/result.md"
SPEC_MARKER="TASK_SPEC_${TASK_ID}"
RESULT_MARKER="TASK_RESULT_${TASK_ID}"

minio_setup
_cleanup_task_artifacts() {
    exec_in_manager mc rm -r --force \
        "$(minio_storage_prefix)/${TASK_DIR}/" >/dev/null 2>&1 || true
}
trap _cleanup_task_artifacts EXIT

MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "Assign Alice this bounded task with ID ${TASK_ID}:
1. Create the task brief '${TASK_SPEC}' containing exactly '${SPEC_MARKER}'.
2. Ask Alice to read that brief and write '${TASK_RESULT}' containing exactly '${RESULT_MARKER}'.
3. Reply with the task ID after assignment.

Do not add other deliverables."

log_info "Waiting for Manager to process task..."
REPLY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" \
    "${MANAGER_BASELINE_EVENT}" "${TASK_ID}" 180 \
    "${ADMIN_TOKEN}" "${DM_ROOM}" "Please continue task ${TASK_ID}.")

assert_not_empty "${REPLY}" "Manager acknowledged task assignment"
assert_contains "${REPLY}" "${TASK_ID}" "Manager acknowledgment is correlated to this task"
if [ -z "${REPLY}" ]; then
    dump_manager_dm_messages "${ADMIN_TOKEN}" "${DM_ROOM}" "${TASK_ID} acknowledgment missing"
    test_teardown "03-assign-task"
    test_summary
    exit 1
fi

log_section "Verify Task in MinIO"

if minio_wait_for_file "${TASK_SPEC}" 120; then
    SPEC_CONTENT=$(minio_read_file "${TASK_SPEC}")
    assert_contains "${SPEC_CONTENT}" "${SPEC_MARKER}" \
        "Manager created the correlated task brief"
else
    log_fail "Task brief was not created within 120s: ${TASK_SPEC}"
fi

log_section "Verify Worker Completion"

if minio_wait_for_file "${TASK_RESULT}" 300; then
    RESULT_CONTENT=$(minio_read_file "${TASK_RESULT}")
    assert_contains "${RESULT_CONTENT}" "${RESULT_MARKER}" \
        "Alice completed the correlated task"
else
    log_fail "Alice result was not created within 300s: ${TASK_RESULT}"
fi

log_section "Collect Metrics"
wait_for_worker_session_stable "alice" 5 120
wait_for_session_stable 5 60
PREV_METRICS=$(cat "${TEST_OUTPUT_DIR}/metrics-03-assign-task.json" 2>/dev/null || true)
METRICS=$(collect_delta_metrics "03-assign-task" "$METRICS_BASELINE" "alice")
print_metrics_report "$METRICS" "$PREV_METRICS"
save_metrics_file "$METRICS" "03-assign-task"

test_teardown "03-assign-task"
test_summary
