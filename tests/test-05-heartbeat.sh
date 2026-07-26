#!/bin/bash
# test-05-heartbeat.sh - Case 5: Heartbeat triggers Manager inquiry
# Verifies: Manager sends status inquiry to Worker during heartbeat,
#           Worker responds with progress

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
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
TASK_ID="heartbeat-$(date +%s)-$$"
MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "For heartbeat test ${TASK_ID}, ask Alice to begin a short WebAssembly outline and keep the task in progress until she receives a status inquiry. When she receives that inquiry, she must reply exactly 'HEARTBEAT_PROGRESS ${TASK_ID}'. Reply with ${TASK_ID} after assigning it."

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

ALICE_ROOM=$(exec_in_agent agt get workers alice -o json 2>/dev/null | jq -r '.roomID // empty')
if [ -z "${ALICE_ROOM}" ]; then
    log_fail "Alice room ID is unavailable"
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
        # CoPaw: the internal _heartbeat APScheduler job has no manual trigger API.
        # Send a heartbeat instruction via Matrix DM to make the Agent execute HEARTBEAT.md.
        matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
            "Please execute your heartbeat check now. Read ~/HEARTBEAT.md and follow the full checklist. Report findings here."
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
INQUIRY=$(matrix_wait_for_reply_since "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@manager" \
    "${MANAGER_ROOM_BASELINE}" 180)

if echo "${INQUIRY}" | grep -qiE "status|progress|heartbeat|how|update"; then
    log_pass "Manager sent heartbeat inquiry"
else
    log_fail "Manager did not send a recognizable heartbeat inquiry (got: ${INQUIRY})"
    log_info "Recent Alice-room messages:"
    matrix_read_messages "${ADMIN_TOKEN}" "${ALICE_ROOM}" 30 2>/dev/null || true
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi

log_info "Waiting for Alice to respond to the heartbeat inquiry..."
ALICE_REPLY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@alice" \
    "${ALICE_ROOM_BASELINE}" "HEARTBEAT_PROGRESS ${TASK_ID}" 180)
assert_not_empty "${ALICE_REPLY}" "Alice responded with progress after the heartbeat inquiry"
if [ -z "${ALICE_REPLY}" ]; then
    test_teardown "05-heartbeat"
    test_summary
    exit 1
fi

# Close the bounded task so it cannot leak into the following multi-worker test.
MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "Heartbeat test ${TASK_ID} is complete. Tell Alice to stop this task and mark it done, then reply with ${TASK_ID}."
CLOSE_REPLY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" \
    "${MANAGER_BASELINE_EVENT}" "${TASK_ID}" 120)
assert_not_empty "${CLOSE_REPLY}" "Manager acknowledged heartbeat test completion"
assert_contains "${CLOSE_REPLY}" "${TASK_ID}" "Completion acknowledgment is correlated"

log_section "Collect Metrics"
wait_for_worker_session_stable "alice" 5 120
wait_for_session_stable 5 60
PREV_METRICS=$(cat "${TEST_OUTPUT_DIR}/metrics-05-heartbeat.json" 2>/dev/null || true)
METRICS=$(collect_delta_metrics "05-heartbeat" "$METRICS_BASELINE" "alice")
print_metrics_report "$METRICS" "$PREV_METRICS"
save_metrics_file "$METRICS" "05-heartbeat"

test_teardown "05-heartbeat"
test_summary
