#!/bin/bash
# test-06-multi-worker.sh - Case 6: Create Bob, assign collaborative task
# Verifies: Second Worker creation, sequential Worker handoff via shared MinIO files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
source "${SCRIPT_DIR}/lib/higress-client.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"
source "${SCRIPT_DIR}/lib/agent-metrics.sh"

test_setup "06-multi-worker"

if ! require_llm_key; then
    test_teardown "06-multi-worker"
    test_summary
    exit 0
fi

ADMIN_LOGIN=$(matrix_login "${TEST_ADMIN_USER}" "${TEST_ADMIN_PASSWORD}")
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | jq -r '.access_token')

MANAGER_USER="@manager:${TEST_MATRIX_DOMAIN}"

log_section "Create Worker Bob"

DM_ROOM=$(matrix_find_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}" 2>/dev/null || true)
assert_not_empty "${DM_ROOM}" "DM room with Manager found"

# Wait for Manager Agent to be fully ready (OpenClaw gateway + joined DM room)
wait_for_manager_agent_ready 300 "${DM_ROOM}" "${ADMIN_TOKEN}" || {
    log_fail "Manager Agent not ready in time"
    test_teardown "06-multi-worker"
    test_summary
    exit 1
}

# test-05 can leave CoPaw Manager finishing heartbeat / pending-worker cleanup
# replies in the admin DM. Let that prior turn go quiet before measuring Bob's
# create-worker ack/provisioning SLA; the post-request waits below stay strict.
if ! matrix_wait_for_sender_quiet "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" 20 180; then
    log_fail "Manager DM did not become quiet before Bob create request"
    test_teardown "06-multi-worker"
    test_summary
    exit 1
fi

# Alice is running from previous tests; bob will be created below (offset=0 is correct for new workers)
wait_for_worker_container "alice" 60
METRICS_BASELINE=$(snapshot_baseline "alice" "bob")
TEST_WORKER_RUNTIME="${AGENTTEAMS_DEFAULT_WORKER_RUNTIME:-openclaw}"
# worker-management/SKILL.md tells Manager to ask admin for FOUR inputs
# (name / runtime / SOUL / skills) before running `agt create worker`
# and not to invent defaults. A vague prompt that only names the worker is
# therefore a coin flip — sometimes Manager replies with a confirmation
# request, never calls the CLI, and the consumer/SOUL.md polls below
# silently time out. Spell out all four inputs and tell Manager to skip
# confirmation so this test exercises actual Worker creation.
#
# The runtime is explicit because the CI matrix runtime is the source of truth;
# rendered Manager workspace text may contain fallback defaults.
MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "Please create a new Worker now using these exact values — do not ask me to confirm any of them:
- name: bob
- runtime: ${TEST_WORKER_RUNTIME} (use this exact runtime; do not reinterpret it as the install default)
- SOUL/role: Backend developer specializing in REST APIs, server-side logic, and data persistence
- skills: github-operations (file-sync / task-progress / project-participation are auto-included, no need to ask)

Proceed immediately and tell me when he is created."

log_info "Waiting for Manager to create Worker Bob..."
REPLY=$(matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" \
    "${MANAGER_BASELINE_EVENT}" "bob.*(accepted|created|creating|pending|running|ready)" 300 \
    "${ADMIN_TOKEN}" "${DM_ROOM}" "Please check if the request to create worker bob has been processed.")

assert_not_empty "${REPLY}" "Manager replied to create bob request"
assert_contains_i "${REPLY}" "bob" "Reply mentions worker name 'bob'"
if [ -z "${REPLY}" ]; then
    dump_manager_dm_messages "${ADMIN_TOKEN}" "${DM_ROOM}" "bob creation reply missing"
    test_teardown "06-multi-worker"
    test_summary
    exit 1
fi

# Verify Bob's infrastructure. Worker creation is asynchronous, so wait on
# persisted provisioning state and gateway side effects instead of sleeping.
BOB_PROVISION_TIMEOUT=60
if echo "${REPLY}" | grep -qiE "bob.*(accepted|creating|pending)" 2>/dev/null; then
    BOB_PROVISION_TIMEOUT=180
fi
if wait_worker_provisioned "bob" "${BOB_PROVISION_TIMEOUT}"; then
    log_pass "Worker Bob provisioned (roomID + matrixUserID populated)"
else
    log_fail "Worker Bob did not reach provisioned state in ${BOB_PROVISION_TIMEOUT}s"
fi

BOB_WORKER_JSON=$(exec_in_agent agt get workers bob -o json 2>/dev/null || echo "{}")
BOB_RUNTIME=$(echo "${BOB_WORKER_JSON}" | jq -r '.runtime // empty')
assert_eq "${TEST_WORKER_RUNTIME}" "${BOB_RUNTIME}" \
    "Worker Bob runtime matches test matrix (got: '${BOB_RUNTIME}', want: '${TEST_WORKER_RUNTIME}')"

higress_login "${TEST_ADMIN_USER}" "${TEST_ADMIN_PASSWORD}" > /dev/null
CONSUMERS=""
DEADLINE=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    if CONSUMERS=$(higress_get_consumers 2>/dev/null) \
        && echo "${CONSUMERS}" | grep -qi "worker-bob"; then
        break
    fi
    sleep 5
done
if ! echo "${CONSUMERS}" | grep -qi "worker-bob"; then
    dump_manager_dm_messages "${ADMIN_TOKEN}" "${DM_ROOM}" "worker-bob consumer missing"
fi
assert_contains_i "${CONSUMERS}" "worker-bob" "Higress consumer 'worker-bob' exists"

minio_setup
minio_wait_for_file "agents/bob/SOUL.md" 60
BOB_EXISTS=$?
assert_eq "0" "${BOB_EXISTS}" "Worker Bob SOUL.md exists in MinIO"

log_section "Assign Collaborative Task"

COLLAB_ID="multi-worker-$(date +%s)-$$"
ALICE_TASK_ID="${COLLAB_ID}-alice"
BOB_TASK_ID="${COLLAB_ID}-bob"
ALICE_FILE="shared/tasks/${ALICE_TASK_ID}/workspace/alice.txt"
BOB_FILE="shared/tasks/${BOB_TASK_ID}/workspace/bob.txt"
ALICE_MARKER="ALICE_READY_${COLLAB_ID}"
BOB_MARKER="BOB_VERIFIED_${COLLAB_ID}"

_cleanup_collaboration_artifacts() {
    exec_in_manager mc rm -r --force \
        "$(minio_storage_prefix)/shared/tasks/${COLLAB_ID}/" >/dev/null 2>&1 || true
    exec_in_manager mc rm -r --force \
        "$(minio_storage_prefix)/shared/tasks/${ALICE_TASK_ID}/" >/dev/null 2>&1 || true
    exec_in_manager mc rm -r --force \
        "$(minio_storage_prefix)/shared/tasks/${BOB_TASK_ID}/" >/dev/null 2>&1 || true
}
trap _cleanup_collaboration_artifacts EXIT

_wait_for_file_with_nudge() {
    local path="$1"
    local timeout="$2"
    local nudge_after="$3"
    local nudge_message="$4"
    local elapsed=0
    local nudged=false

    while [ "${elapsed}" -lt "${timeout}" ]; do
        minio_file_exists "${path}" && return 0
        if [ "${nudged}" = "false" ] && [ "${elapsed}" -ge "${nudge_after}" ]; then
            matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "${nudge_message}" >/dev/null
            nudged=true
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

if ! matrix_wait_for_sender_quiet "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" 15 120; then
    log_fail "Manager DM did not become quiet before collaboration request"
    test_teardown "06-multi-worker"
    test_summary
    exit 1
fi

matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "Assign Alice one finite task now using her existing Worker Room. Do not create a Project Room and do not notify Bob yet.

- exact task ID: ${ALICE_TASK_ID}
- exact output path: ${ALICE_FILE}
- exact file content: ${ALICE_MARKER}
- completion: submit SUCCESS via taskflow

Copy these identifiers and strings verbatim into Alice's task spec. Do not add deliverables or ask for confirmation."

log_section "Verify Shared Coordination"

log_info "Waiting for Alice handoff file (timeout: 150s, one nudge after 60s)..."
if _wait_for_file_with_nudge "${ALICE_FILE}" 150 60 \
    "Continue ${COLLAB_ID} Phase 1 now through Alice's existing Worker Room. Preserve task ID '${ALICE_TASK_ID}', path '${ALICE_FILE}', and marker '${ALICE_MARKER}' verbatim."; then
    ALICE_CONTENT=$(minio_read_file "${ALICE_FILE}")
    assert_contains "${ALICE_CONTENT}" "${ALICE_MARKER}" \
        "Alice wrote the correlated handoff marker"
else
    dump_manager_dm_messages "${ADMIN_TOKEN}" "${DM_ROOM}" "${COLLAB_ID} Alice output missing"
    log_fail "Alice handoff file was not created: ${ALICE_FILE}"
    test_teardown "06-multi-worker"
    test_summary
    exit 1
fi

matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "Alice's ${ALICE_TASK_ID} output now exists in MinIO. Assign Bob one finite task now using his existing Worker Room. Do not create a Project Room.

- exact task ID: ${BOB_TASK_ID}
- first read: ${ALICE_FILE}
- verify it contains: ${ALICE_MARKER}
- exact output path: ${BOB_FILE}
- exact output content, two lines:
${ALICE_MARKER}
${BOB_MARKER}
- completion: submit SUCCESS via taskflow

Copy these identifiers, paths, and strings verbatim into Bob's task spec. Do not add deliverables or ask for confirmation." \
    >/dev/null

log_info "Waiting for Bob verification file (timeout: 150s, one nudge after 60s)..."
if _wait_for_file_with_nudge "${BOB_FILE}" 150 60 \
    "Continue ${COLLAB_ID} Phase 2 now through Bob's existing Worker Room. Preserve task ID '${BOB_TASK_ID}', both paths, and both markers verbatim."; then
    BOB_CONTENT=$(minio_read_file "${BOB_FILE}")
    assert_contains "${BOB_CONTENT}" "${ALICE_MARKER}" \
        "Bob read Alice's handoff marker"
    assert_contains "${BOB_CONTENT}" "${BOB_MARKER}" \
        "Bob wrote the correlated verification marker"
else
    dump_manager_dm_messages "${ADMIN_TOKEN}" "${DM_ROOM}" "${COLLAB_ID} Bob output missing"
    log_fail "Bob verification file was not created: ${BOB_FILE}"
    test_teardown "06-multi-worker"
    test_summary
    exit 1
fi

COMPLETION_MARKER="COLLAB_COMPLETE ${COLLAB_ID}"
MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "Both ${COLLAB_ID} files now exist. Verify them, then reply with exactly '${COMPLETION_MARKER}' as a standalone message and nothing else." \
    >/dev/null
COMPLETION_MSG=""
DEADLINE=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    COMPLETION_MSG=$(matrix_read_messages "${ADMIN_TOKEN}" "${DM_ROOM}" 30 2>/dev/null | \
        jq -r --arg user "@manager" --arg baseline "${MANAGER_BASELINE_EVENT}" \
          --arg marker "${COMPLETION_MARKER}" \
        '[.chunk[] | select(.sender | startswith($user)) |
          select(.event_id != $baseline) |
          select((.content.body // "" |
            gsub("^\\s+|\\s+$"; "") |
            sub("^\\*\\s+"; "")) == $marker) |
          .content.body] | first // empty' 2>/dev/null || true)
    [ -n "${COMPLETION_MSG}" ] && break
    sleep 5
done
if [ -n "${COMPLETION_MSG}" ]; then
    log_pass "Manager posted the exact correlated completion marker"
else
    log_fail "Manager did not post exact marker: ${COMPLETION_MARKER}"
fi

log_section "Collect Metrics"
wait_for_worker_session_stable "alice" 5 120
wait_for_worker_session_stable "bob" 5 120
wait_for_session_stable 5 60
PREV_METRICS=$(cat "${TEST_OUTPUT_DIR}/metrics-06-multi-worker.json" 2>/dev/null || true)
METRICS=$(collect_delta_metrics "06-multi-worker" "$METRICS_BASELINE" "alice" "bob")
print_metrics_report "$METRICS" "$PREV_METRICS"
save_metrics_file "$METRICS" "06-multi-worker"

test_teardown "06-multi-worker"
test_summary
