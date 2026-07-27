#!/bin/bash
# test-05-heartbeat.sh - Case 5: Heartbeat triggers Manager inquiry
# Verifies: Manager sends status inquiry to Worker during heartbeat,
#           Worker responds with progress

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"
source "${SCRIPT_DIR}/lib/agent-metrics.sh"

test_setup "05-heartbeat"

if ! require_llm_key; then
    test_teardown "05-heartbeat"
    test_summary
    exit 0
fi

ADMIN_LOGIN=$(matrix_login "${TEST_ADMIN_USER}" "${TEST_ADMIN_PASSWORD}")
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | jq -r '.access_token')

MANAGER_USER="@manager:${TEST_MATRIX_DOMAIN}"

log_section "Assign Long Task"

DM_ROOM=$(matrix_find_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}" 2>/dev/null || true)
assert_not_empty "${DM_ROOM}" "DM room with Manager found"

# Wait for Manager Agent to be fully ready (OpenClaw gateway + joined DM room)
wait_for_manager_agent_ready 300 "${DM_ROOM}" "${ADMIN_TOKEN}" || {
    log_fail "Manager Agent not ready in time"
    test_teardown "05-heartbeat"
    test_summary
    exit 1
}

# Alice container should be running from test-02/03/04; wait to ensure it's up before snapshot
wait_for_worker_container "alice" 60
METRICS_BASELINE=$(snapshot_baseline "alice")
ALICE_ROOM=$(exec_in_agent agt get workers alice -o json 2>/dev/null | jq -r '.roomID // empty')
if [ -z "${ALICE_ROOM}" ]; then
    log_fail "Alice room ID is unavailable"
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi
ALICE_USER="@alice:${TEST_MATRIX_DOMAIN}"

TASK_ID="heartbeat-$(date +%s)-$$"
TASK_DIR="shared/tasks/${TASK_ID}"
TASK_SPEC="${TASK_DIR}/spec.md"
TASK_RESULT="${TASK_DIR}/result.md"
OUTLINE_FILE="${TASK_DIR}/workspace/webassembly-outline.md"
TASK_FIXTURE_DIR=$(mktemp -d)

minio_setup
_cleanup_heartbeat_test() {
    if declare -F _restore_copaw_heartbeat >/dev/null 2>&1; then
        _restore_copaw_heartbeat
    fi
    exec_in_agent bash \
        /opt/agentteams/agent/skills/task-management/scripts/manage-state.sh \
        --action complete --task-id "${TASK_ID}" >/dev/null 2>&1 || true
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
trap _cleanup_heartbeat_test EXIT

jq -n --arg task_id "${TASK_ID}" '{
    task_id: $task_id,
    project_id: "standalone",
    task_title: "Prepare a short WebAssembly outline",
    assigned_to: "alice",
    status: "assigned"
}' > "${TASK_FIXTURE_DIR}/meta.json"
cat > "${TASK_FIXTURE_DIR}/spec.md" <<EOF
# Heartbeat progress task ${TASK_ID}

1. Accept this task with taskflow action ack_task and payload {"taskId":"${TASK_ID}"}.
2. Write a short WebAssembly outline to '${OUTLINE_FILE}' and sync it to MinIO with filesync push.
3. Keep the task in progress. Do not submit it until the Manager explicitly asks you to close it.
4. When the Manager asks for status or progress on this task, reply exactly 'HEARTBEAT_PROGRESS ${TASK_ID}'.
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
Assign Alice one finite task through taskflow with exact ID ${TASK_ID}.
A taskflow-compatible meta.json and spec.md already exist under '${TASK_DIR}' in shared storage. Do not recreate or replace its task metadata. Sync and inspect the existing files, register the finite task in state.json, dispatch the full spec to Alice's worker room, then reply with ${TASK_ID}.
EOF
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "${ASSIGN_MESSAGE}"

log_info "Waiting for Manager to assign task..."
ASSIGN_REPLY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" \
    "${MANAGER_BASELINE_EVENT}" "${TASK_ID}" 180 \
    "${ADMIN_TOKEN}" "${DM_ROOM}" "Please continue heartbeat test ${TASK_ID}.")
assert_not_empty "${ASSIGN_REPLY}" "Manager acknowledged the heartbeat test task"
assert_contains "${ASSIGN_REPLY}" "${TASK_ID}" "Task acknowledgment is correlated"
if [ -z "${ASSIGN_REPLY}" ]; then
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi
if wait_for_manager_task_state true 30; then
    log_pass "Manager registered the heartbeat task in state.json"
else
    log_fail "Manager did not register ${TASK_ID} in state.json within 30s"
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi
if minio_wait_for_file "${OUTLINE_FILE}" 120; then
    log_pass "Alice started the current heartbeat task"
else
    log_fail "Alice did not sync ${OUTLINE_FILE} within 120s"
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi

# Drain assignment messages before taking the heartbeat baseline.
matrix_wait_for_sender_quiet "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@manager" 10 60 || true
matrix_wait_for_sender_quiet "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@alice" 10 60 || true
MANAGER_ROOM_BASELINE=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@manager")
ALICE_ROOM_BASELINE=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@alice")

log_section "Trigger Heartbeat"

MANAGER_CONTAINER="${TEST_AGENT_CONTAINER:-agentteams-manager}"
MANAGER_RUNTIME=$(docker exec "${MANAGER_CONTAINER}" printenv AGENTTEAMS_MANAGER_RUNTIME 2>/dev/null || \
                  echo "openclaw")
log_info "Triggering heartbeat (runtime=${MANAGER_RUNTIME})..."

case "${MANAGER_RUNTIME}" in
    copaw)
        COPAW_HEARTBEAT_URL="http://127.0.0.1:18799/api/agents/default/config/heartbeat"
        COPAW_HEARTBEAT_ORIGINAL=$(docker exec "${MANAGER_CONTAINER}" \
            curl --max-time 5 -sf "${COPAW_HEARTBEAT_URL}" 2>/dev/null || true)
        _restore_copaw_heartbeat() {
            [ -n "${COPAW_HEARTBEAT_ORIGINAL:-}" ] || return 0
            docker exec "${MANAGER_CONTAINER}" \
                curl --max-time 5 -sf -X PUT "${COPAW_HEARTBEAT_URL}" \
                -H 'Content-Type: application/json' \
                -d "${COPAW_HEARTBEAT_ORIGINAL}" >/dev/null 2>&1 || true
            COPAW_HEARTBEAT_ORIGINAL=""
        }
        if [ -z "${COPAW_HEARTBEAT_ORIGINAL}" ]; then
            log_fail "Could not read CoPaw heartbeat configuration"
            test_teardown "05-heartbeat"
            test_summary
            exit 1
        fi
        COPAW_HEARTBEAT_TRIGGER=$(printf '%s' "${COPAW_HEARTBEAT_ORIGINAL}" |
            jq -c '.enabled = true | .every = "1s" | .target = "main"')
        if ! docker exec "${MANAGER_CONTAINER}" \
            curl --max-time 5 -sf -X PUT "${COPAW_HEARTBEAT_URL}" \
            -H 'Content-Type: application/json' \
            -d "${COPAW_HEARTBEAT_TRIGGER}" >/dev/null; then
            log_fail "Could not schedule an immediate CoPaw heartbeat"
            test_teardown "05-heartbeat"
            test_summary
            exit 1
        fi
        sleep 3
        log_pass "CoPaw scheduled heartbeat triggered"
        ;;
    *)
        # OpenClaw: trigger via system event
        if docker exec "${MANAGER_CONTAINER}" bash -c \
            "cd ~/agentteams-fs/agents/manager && openclaw system event --mode now" 2>/dev/null; then
            log_pass "OpenClaw heartbeat event triggered"
        else
            log_fail "Could not trigger OpenClaw heartbeat via system event"
            test_teardown "05-heartbeat"
            test_summary
            exit 1
        fi
        ;;
esac

log_section "Verify Heartbeat Inquiry"

log_info "Waiting for Manager heartbeat inquiry in Alice's room..."
INQUIRY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@manager" \
    "${MANAGER_ROOM_BASELINE}" "${TASK_ID}" 120)
if declare -F _restore_copaw_heartbeat >/dev/null 2>&1; then
    _restore_copaw_heartbeat
fi
INQUIRY_HAS_MENTION=$(matrix_read_messages "${ADMIN_TOKEN}" "${ALICE_ROOM}" 30 2>/dev/null |
    jq -r --arg task "${TASK_ID}" --arg alice "${ALICE_USER}" '
        [.chunk[]
         | select(.sender | startswith("@manager:"))
         | select((.content.body // "") | contains($task))
         | select((.content["m.mentions"].user_ids // []) | index($alice) != null)]
        | length > 0
    ' 2>/dev/null)

if echo "${INQUIRY}" | grep -qiE "status|progress|heartbeat|how|update" &&
    [ "${INQUIRY_HAS_MENTION}" = "true" ]; then
    log_pass "Manager sent heartbeat inquiry"
else
    log_fail "Manager did not send a recognizable heartbeat inquiry with an Alice mention (got: ${INQUIRY})"
    log_info "Recent Alice-room messages:"
    matrix_read_messages "${ADMIN_TOKEN}" "${ALICE_ROOM}" 30 2>/dev/null || true
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi

log_info "Waiting for Alice to respond to the heartbeat inquiry..."
ALICE_REPLY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@alice" \
    "${ALICE_ROOM_BASELINE}" "HEARTBEAT_PROGRESS ${TASK_ID}" 60)
if [ -z "${ALICE_REPLY}" ]; then
    log_info "Alice did not respond within 60s; sending one correlated progress nudge..."
    PROGRESS_NUDGE_BASELINE=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@alice")
    PROGRESS_NUDGE="Heartbeat follow-up for ${TASK_ID}: reply exactly HEARTBEAT_PROGRESS ${TASK_ID}, followed by a short status."
    matrix_send_mention_message "${ADMIN_TOKEN}" "${ALICE_ROOM}" "${ALICE_USER}" "${PROGRESS_NUDGE}"
    ALICE_REPLY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@alice" \
        "${PROGRESS_NUDGE_BASELINE}" "HEARTBEAT_PROGRESS ${TASK_ID}" 60)
fi
assert_not_empty "${ALICE_REPLY}" "Alice responded with progress after the heartbeat inquiry"
if [ -z "${ALICE_REPLY}" ]; then
    log_info "Recent Alice-room messages:"
    matrix_read_messages "${ADMIN_TOKEN}" "${ALICE_ROOM}" 30 2>/dev/null || true
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi

# Close the bounded task directly; Manager completion handling is covered by
# tests 03/04, while this test is specifically about heartbeat inquiry.
read -r -d '' CLOSE_MESSAGE <<EOF || true
Heartbeat test ${TASK_ID} is complete.
Submit the task with taskflow action submit_task and this inline result payload:
{"taskId":"${TASK_ID}","status":"SUCCESS","summary":"Reported heartbeat progress for the active task","deliverables":["${OUTLINE_FILE}"],"notes":[]}
Do not edit result.md directly. @mention Manager after taskflow confirms success.
EOF
matrix_send_mention_message "${ADMIN_TOKEN}" "${ALICE_ROOM}" "${ALICE_USER}" "${CLOSE_MESSAGE}"
if minio_wait_for_content "${TASK_RESULT}" "STATUS: SUCCESS" 120; then
    log_pass "Alice closed the heartbeat task through taskflow"
else
    log_fail "Alice did not submit ${TASK_RESULT} within 120s"
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi
if exec_in_agent bash \
    /opt/agentteams/agent/skills/task-management/scripts/manage-state.sh \
    --action complete --task-id "${TASK_ID}" >/dev/null &&
    wait_for_manager_task_state false 10; then
    log_pass "Heartbeat test fixture state was cleaned"
else
    log_fail "Could not clean ${TASK_ID} from state.json"
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi

log_section "Collect Metrics"
wait_for_worker_session_stable "alice" 5 120
wait_for_session_stable 5 60
PREV_METRICS=$(cat "${TEST_OUTPUT_DIR}/metrics-05-heartbeat.json" 2>/dev/null || true)
METRICS=$(collect_delta_metrics "05-heartbeat" "$METRICS_BASELINE" "alice")
print_metrics_report "$METRICS" "$PREV_METRICS"
save_metrics_file "$METRICS" "05-heartbeat"

test_teardown "05-heartbeat"
test_summary
