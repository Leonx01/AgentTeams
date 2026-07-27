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
ALICE_ROOM=$(exec_in_agent agt get workers alice -o json 2>/dev/null | jq -r '.roomID // empty')
assert_not_empty "${ALICE_ROOM}" "Alice worker room is available"
if [ -z "${ALICE_ROOM}" ]; then
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi
ALICE_MATRIX_ID="@alice:${TEST_MATRIX_DOMAIN}"
METRICS_BASELINE=$(snapshot_baseline "alice")
TASK_ID="human-intervene-$(date +%s)-$$"
TASK_DIR="shared/tasks/${TASK_ID}"
TASK_SPEC="${TASK_DIR}/spec.md"
START_FILE="${TASK_DIR}/started.txt"
RESULT_FILE="${TASK_DIR}/workspace/hello.py"
TASKFLOW_RESULT="${TASK_DIR}/result.md"
ORIGINAL_MARKER="ORIGINAL_REQUIREMENT_${TASK_ID}"
SUPPLEMENT_MARKER="SUPPLEMENT_REQUIREMENT_${TASK_ID}"
TASK_FIXTURE_DIR=$(mktemp -d)

minio_setup
_cleanup_task_artifacts() {
    exec_in_manager mc rm -r --force \
        "$(minio_storage_prefix)/${TASK_DIR}/" >/dev/null 2>&1 || true
    rm -rf "${TASK_FIXTURE_DIR}"
}
wait_for_manager_task_state() {
    local expected_active="$1"
    local timeout="$2"
    local elapsed=0
    local count

    while [ "${elapsed}" -lt "${timeout}" ]; do
        count=$(exec_in_agent jq -r --arg id "${TASK_ID}" \
            '[.active_tasks[]? | select(.task_id == $id)] | length' \
            /root/manager-workspace/state.json 2>/dev/null) || count=""
        if [ "${expected_active}" = "true" ] && [ "${count}" = "1" ]; then
            return 0
        fi
        if [ "${expected_active}" = "false" ] && [ "${count}" = "0" ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}
trap _cleanup_task_artifacts EXIT

jq -n --arg task_id "${TASK_ID}" '{
    task_id: $task_id,
    project_id: "standalone",
    task_title: "Verify human intervention during a finite task",
    assigned_to: "alice",
    status: "assigned"
}' > "${TASK_FIXTURE_DIR}/meta.json"
cat > "${TASK_FIXTURE_DIR}/spec.md" <<EOF
# Human intervention task ${TASK_ID}

1. Accept this task with taskflow action ack_task and payload {"taskId":"${TASK_ID}"}.
2. Write exactly '${ORIGINAL_MARKER}' to '${START_FILE}' when starting.
3. Immediately sync '${START_FILE}' to MinIO with filesync push.
4. Prepare a Python hello-world script, but do not finalize or submit the task until the Manager relays a supplementary requirement.
EOF
docker cp "${TASK_FIXTURE_DIR}/meta.json" \
    "${TEST_CONTROLLER_CONTAINER:-agentteams-controller}:/tmp/${TASK_ID}-meta.json" >/dev/null
docker cp "${TASK_FIXTURE_DIR}/spec.md" \
    "${TEST_CONTROLLER_CONTAINER:-agentteams-controller}:/tmp/${TASK_ID}-spec.md" >/dev/null
exec_in_manager mc cp "/tmp/${TASK_ID}-meta.json" \
    "$(minio_storage_prefix)/${TASK_DIR}/meta.json" >/dev/null
exec_in_manager mc cp "/tmp/${TASK_ID}-spec.md" \
    "$(minio_storage_prefix)/${TASK_SPEC}" >/dev/null
exec_in_manager rm -f "/tmp/${TASK_ID}-meta.json" "/tmp/${TASK_ID}-spec.md"

MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
WORKER_ROOM_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@manager")
read -r -d '' ORIGINAL_MESSAGE <<EOF || true
Assign Alice one finite task through taskflow with exact ID ${TASK_ID}.
A taskflow-compatible meta.json and spec.md already exist under '${TASK_DIR}' in shared storage. Do not recreate or replace its task metadata. Sync and inspect the existing files, register the finite task in state.json, and dispatch the full spec to Alice's worker room. Reply with ${TASK_ID} only after the worker-room message has been sent.
EOF
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "${ORIGINAL_MESSAGE}"

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

WORKER_ROOM_DISPATCH=$(matrix_wait_for_reply_matching_since \
    "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@manager" \
    "${WORKER_ROOM_BASELINE_EVENT}" "${TASK_ID}" 60)
assert_not_empty "${WORKER_ROOM_DISPATCH}" \
    "Manager dispatched the original task to Alice's worker room"
if [ -z "${WORKER_ROOM_DISPATCH}" ]; then
    log_fail "Manager acknowledged ${TASK_ID} without dispatching it to Alice's room within 60s"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi
if wait_for_manager_task_state true 30; then
    log_pass "Manager registered the finite task in state.json"
else
    log_fail "Manager did not register ${TASK_ID} in state.json within 30s"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi

if minio_wait_for_content "${START_FILE}" "${ORIGINAL_MARKER}" 120; then
    START_CONTENT=$(minio_read_file "${START_FILE}")
    assert_contains "${START_CONTENT}" "${ORIGINAL_MARKER}" \
        "Alice started the original task before human intervention"
else
    log_fail "Alice did not sync the start marker within 120s: ${START_FILE}"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi

log_section "Send Supplementary Instruction"

MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
WORKER_ROOM_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@manager")
read -r -d '' SUPPLEMENT_MESSAGE <<EOF || true
Supplement for task ${TASK_ID}: Alice must now finalize '${RESULT_FILE}' so it accepts an optional command-line name and prints 'Hello, <name>!'. The file must contain both marker comments '${ORIGINAL_MARKER}' and '${SUPPLEMENT_MARKER}', then she must sync '${RESULT_FILE}' to MinIO with filesync push and submit SUCCESS via taskflow.

She must invoke taskflow action submit_task with this inline result payload:
{"taskId":"${TASK_ID}","status":"SUCCESS","summary":"Implemented the original and supplementary requirements","deliverables":["${RESULT_FILE}"],"notes":[]}
Do not edit result.md directly; taskflow owns and renders that file.

Relay this update to Alice's worker room and visibly @mention exact Matrix ID ${ALICE_MATRIX_ID}. Do not invent or reuse another Matrix domain or port. Reply with ${TASK_ID} only after the worker-room message has been sent.
EOF
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "${SUPPLEMENT_MESSAGE}"

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

WORKER_ROOM_SUPPLEMENT=$(matrix_wait_for_mentioned_reply_matching_since \
    "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@manager" \
    "${WORKER_ROOM_BASELINE_EVENT}" "${TASK_ID}" "${ALICE_MATRIX_ID}" 60)
assert_not_empty "${WORKER_ROOM_SUPPLEMENT}" \
    "Manager relayed the supplement to Alice's exact Matrix ID"
if [ -z "${WORKER_ROOM_SUPPLEMENT}" ]; then
    log_fail "Manager acknowledged the supplement without correctly mentioning ${ALICE_MATRIX_ID} within 60s"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi

log_section "Verify Incorporation"

if minio_wait_for_content "${RESULT_FILE}" "${SUPPLEMENT_MARKER}" 120; then
    RESULT_CONTENT=$(minio_read_file "${RESULT_FILE}")
    assert_contains "${RESULT_CONTENT}" "${ORIGINAL_MARKER}" \
        "Final result preserves the original requirement"
    assert_contains "${RESULT_CONTENT}" "${SUPPLEMENT_MARKER}" \
        "Final result incorporates the human supplement"
else
    log_fail "Final result did not contain the supplementary marker within 120s: ${RESULT_FILE}"
    log_info "Supplement result missing; stopping without another blind wait"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi
if minio_wait_for_content "${TASKFLOW_RESULT}" "STATUS: SUCCESS" 120; then
    log_pass "Alice closed the finite task through taskflow"
else
    log_fail "Alice did not submit a successful taskflow result within 120s: ${TASKFLOW_RESULT}"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
fi
if wait_for_manager_task_state false 60; then
    log_pass "Manager removed the completed task from state.json"
else
    log_fail "Manager did not clear ${TASK_ID} from state.json within 60s"
    test_teardown "04-human-intervene"
    test_summary
    exit 1
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
