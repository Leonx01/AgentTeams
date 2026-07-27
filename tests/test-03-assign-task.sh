#!/bin/bash
# test-03-assign-task.sh - Case 3: Assign task in Room, Worker completes
# Verifies: Manager relays task to Worker, task brief created in MinIO,
#           Worker completes and writes result

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"
source "${SCRIPT_DIR}/lib/agent-metrics.sh"
source "${SCRIPT_DIR}/lib/finite-task-protocol.sh"

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
ALICE_ROOM=$(get_worker_room_id "alice")
assert_not_empty "${ALICE_ROOM}" "Alice worker room is available"
if [ -z "${ALICE_ROOM}" ]; then
    test_teardown "03-assign-task"
    test_summary
    exit 1
fi
METRICS_BASELINE=$(snapshot_baseline "alice")
TASK_ID="assign-task-$(date +%s)-$$"
TASK_DIR="shared/tasks/${TASK_ID}"
TASK_SPEC="${TASK_DIR}/spec.md"
TASK_RESULT="${TASK_DIR}/result.md"
SPEC_MARKER="TASK_SPEC_${TASK_ID}"
TASK_FIXTURE_DIR=$(mktemp -d)
TEST_WORKER_RUNTIME="${AGENTTEAMS_DEFAULT_WORKER_RUNTIME:-openclaw}"
TASK_ACCEPTANCE=$(finite_task_acceptance_instruction "${TEST_WORKER_RUNTIME}" "${TASK_ID}")
TASK_COMPLETION=$(finite_task_completion_instruction "${TEST_WORKER_RUNTIME}" "${TASK_ID}" \
    "Processed ${SPEC_MARKER}" '[]' "${ALICE_ROOM}" "${MANAGER_USER}")

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
    task_title: "Verify finite task assignment",
    assigned_to: "alice",
    status: "assigned"
}' > "${TASK_FIXTURE_DIR}/meta.json"
cat > "${TASK_FIXTURE_DIR}/spec.md" <<EOF
# Finite task assignment ${TASK_ID}

${SPEC_MARKER}

${TASK_ACCEPTANCE}
${TASK_COMPLETION}
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
read -r -d '' ASSIGN_MESSAGE <<EOF || true
Assign Alice this bounded task with ID ${TASK_ID}.
A structured meta.json and spec.md already exist under '${TASK_DIR}' in shared storage. Do not recreate or replace its task metadata. Sync and inspect the existing files. Register it with manage-state.sh before sending any Matrix message to Alice. Only after the add-finite command succeeds, dispatch the full spec to Alice's worker room, then reply with ${TASK_ID}.
EOF
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "${ASSIGN_MESSAGE}"

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
if wait_for_manager_task_state true 30; then
    log_pass "Manager registered the finite task in state.json"
else
    log_fail "Manager did not register ${TASK_ID} in state.json within 30s"
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
    test_teardown "03-assign-task"
    test_summary
    exit 1
fi

log_section "Verify Worker Completion"

if minio_wait_for_content "${TASK_RESULT}" "STATUS: SUCCESS" 120; then
    RESULT_CONTENT=$(minio_read_file "${TASK_RESULT}")
    assert_contains "${RESULT_CONTENT}" "STATUS: SUCCESS" \
        "Alice submitted a successful result for the correlated task"
    assert_contains "${RESULT_CONTENT}" "SUMMARY:" \
        "Alice submitted a structured terminal result"
else
    log_fail "Alice did not submit a successful result within 120s: ${TASK_RESULT}"
    test_teardown "03-assign-task"
    test_summary
    exit 1
fi
MANAGER_COMPLETION_TIMEOUT=60
if [ "${AGENTTEAMS_MANAGER_RUNTIME:-openclaw}" = "copaw" ]; then
    MANAGER_COMPLETION_TIMEOUT=90
fi
if wait_for_manager_task_state false "${MANAGER_COMPLETION_TIMEOUT}"; then
    log_pass "Manager removed the completed task from state.json"
else
    log_fail "Manager did not clear ${TASK_ID} from state.json within ${MANAGER_COMPLETION_TIMEOUT}s"
    test_teardown "03-assign-task"
    test_summary
    exit 1
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
