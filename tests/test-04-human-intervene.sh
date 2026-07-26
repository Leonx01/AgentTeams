#!/bin/bash
# test-04-human-intervene.sh - Case 4: Human sends supplementary instructions mid-task
# Verifies: Human can send additional instructions while Worker is processing,
#           and the final result incorporates both original and supplementary requirements

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"
source "${SCRIPT_DIR}/lib/agent-metrics.sh"

test_setup "04-human-intervene"

if ! require_llm_key; then
    test_teardown "04-human-intervene"
    test_summary
    exit 0
fi

ADMIN_LOGIN=$(matrix_login "${TEST_ADMIN_USER}" "${TEST_ADMIN_PASSWORD}")
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | jq -r '.access_token')

MANAGER_USER="@manager:${TEST_MATRIX_DOMAIN}"

log_section "Assign Task"

DM_ROOM=$(matrix_find_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}" 2>/dev/null || true)
assert_not_empty "${DM_ROOM}" "DM room with Manager found"

# Wait for Manager Agent to be fully ready (OpenClaw gateway + joined DM room)
wait_for_manager_agent_ready 300 "${DM_ROOM}" "${ADMIN_TOKEN}" || {
    log_fail "Manager Agent not ready in time"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
}

# Alice container should be running from test-02/03; wait to ensure it's up before snapshot
wait_for_worker_container "alice" 60
METRICS_BASELINE=$(snapshot_baseline "alice")
TASK_ID="human-intervene-$(date +%s)-$$"
TASK_DIR="shared/tasks/${TASK_ID}"
START_FILE="${TASK_DIR}/started.txt"
RESULT_FILE="${TASK_DIR}/hello.py"
ORIGINAL_MARKER="ORIGINAL_REQUIREMENT_${TASK_ID}"
SUPPLEMENT_MARKER="SUPPLEMENT_REQUIREMENT_${TASK_ID}"

minio_setup
_cleanup_task_artifacts() {
    exec_in_manager mc rm -r --force \
        "$(minio_storage_prefix)/${TASK_DIR}/" >/dev/null 2>&1 || true
}
trap _cleanup_task_artifacts EXIT

MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "Start task ${TASK_ID} with Alice. Ask her to:
1. Write exactly '${ORIGINAL_MARKER}' to '${START_FILE}' when she starts.
2. Prepare a Python hello-world script, but do not finalize it until I send a supplementary requirement.
Reply with ${TASK_ID} after Alice has been assigned."

log_info "Waiting for Manager to relay the original task..."
ORIGINAL_REPLY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" \
    "${MANAGER_BASELINE_EVENT}" "${TASK_ID}" 180 \
    "${ADMIN_TOKEN}" "${DM_ROOM}" "Please continue task ${TASK_ID}.")
assert_not_empty "${ORIGINAL_REPLY}" "Manager acknowledged the original task"
assert_contains "${ORIGINAL_REPLY}" "${TASK_ID}" \
    "Original-task acknowledgment is correlated"
if [ -z "${ORIGINAL_REPLY}" ]; then
    dump_manager_dm_messages "${ADMIN_TOKEN}" "${DM_ROOM}" "${TASK_ID} original-task acknowledgment missing"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi

if minio_wait_for_content "${START_FILE}" "${ORIGINAL_MARKER}" 240; then
    START_CONTENT=$(minio_read_file "${START_FILE}")
    assert_contains "${START_CONTENT}" "${ORIGINAL_MARKER}" \
        "Alice started the original task before human intervention"
else
    log_fail "Alice did not create the start marker within 240s: ${START_FILE}"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi

log_section "Send Supplementary Instruction"

MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "Supplement for task ${TASK_ID}: Alice must now finalize '${RESULT_FILE}' so it accepts an optional command-line name and prints 'Hello, <name>!'. The file must contain both marker comments '${ORIGINAL_MARKER}' and '${SUPPLEMENT_MARKER}'. Reply with ${TASK_ID} after relaying this update."

log_info "Waiting for Manager to relay supplement..."
REPLY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" \
    "${MANAGER_BASELINE_EVENT}" "${TASK_ID}" 180 \
    "${ADMIN_TOKEN}" "${DM_ROOM}" "Please continue the supplement for ${TASK_ID}.")

assert_not_empty "${REPLY}" "Manager acknowledged supplementary instruction"
assert_contains "${REPLY}" "${TASK_ID}" \
    "Supplement acknowledgment is correlated"
if [ -z "${REPLY}" ]; then
    dump_manager_dm_messages "${ADMIN_TOKEN}" "${DM_ROOM}" "${TASK_ID} supplement acknowledgment missing"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi

log_section "Verify Incorporation"

if minio_wait_for_content "${RESULT_FILE}" "${SUPPLEMENT_MARKER}" 180; then
    RESULT_CONTENT=$(minio_read_file "${RESULT_FILE}")
    assert_contains "${RESULT_CONTENT}" "${ORIGINAL_MARKER}" \
        "Final result preserves the original requirement"
    assert_contains "${RESULT_CONTENT}" "${SUPPLEMENT_MARKER}" \
        "Final result incorporates the human supplement"
else
    log_fail "Final result did not contain the supplementary marker within 180s: ${RESULT_FILE}"
fi

log_section "Collect Metrics"
wait_for_worker_session_stable "alice" 5 120
wait_for_session_stable 5 60
PREV_METRICS=$(cat "${TEST_OUTPUT_DIR}/metrics-04-human-intervene.json" 2>/dev/null || true)
METRICS=$(collect_delta_metrics "04-human-intervene" "$METRICS_BASELINE" "alice")
print_metrics_report "$METRICS" "$PREV_METRICS"
save_metrics_file "$METRICS" "04-human-intervene"

test_teardown "04-human-intervene"
test_summary
