#!/bin/bash
# Verify that the integration orchestrator selects tests deterministically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run-all-tests.sh"
MAKEFILE="${SCRIPT_DIR}/../Makefile"
# shellcheck source=lib/gateway-auth.sh
source "${SCRIPT_DIR}/lib/gateway-auth.sh"

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

runtime_specific_controller_plan=$(GITHUB_ACTIONS=true bash "${RUNNER}" \
    --test-filter "15 17 18 19 20 22 24 25 100" \
    --list-tests)

expected_runtime_specific_controller_plan=$(cat <<'EOF'
test-15-import-worker-zip.sh
test-17-worker-config-verify.sh
test-18-team-config-verify.sh
test-19-human-and-team-admin.sh
test-20-inline-worker-config.sh
test-22-delete-worker-cleanup.sh
test-24-skills-management.sh
test-25-name-validation.sh
test-100-cleanup.sh
EOF
)

assert_eq "${expected_runtime_specific_controller_plan}" "${runtime_specific_controller_plan}" \
    "CI must preserve the declarative shard filter instead of injecting runtime-switch coverage"

llm_plan=$(bash "${RUNNER}" --test-filter "01 02 03 04 05 06" --list-tests)
if echo "${llm_plan}" | grep -q 'test-100-cleanup.sh'; then
    fail "cleanup must not be injected into a shard that did not select it"
fi

if bash "${RUNNER}" --test-filter "999" --list-tests >/dev/null 2>&1; then
    fail "an empty test selection must fail"
fi
if ! grep -Fq 'AGENTTEAMS_MANAGER_RUNTIME)        export AGENTTEAMS_MANAGER_RUNTIME="${value}"' "${RUNNER}" ||
    ! grep -Fq 'AGENTTEAMS_DEFAULT_WORKER_RUNTIME) export AGENTTEAMS_DEFAULT_WORKER_RUNTIME="${value}"' "${RUNNER}"; then
    fail "--use-existing must preserve the Manager and Worker runtime matrix from the env file"
fi
if ! grep -Fq 'make -C "${PROJECT_ROOT}" install SKIP_BUILD=1 VERSION="${AGENTTEAMS_VERSION}"' "${RUNNER}"; then
    fail "fresh installs must pass AGENTTEAMS_VERSION to Make so image env compatibility matches the tested version"
fi
if grep -Fq 'make -C "${PROJECT_ROOT}" wait-ready' "${RUNNER}"; then
    fail "fresh integration installs must not add the fixed 60-second wait after the installer readiness checks"
fi
if ! grep -Fq '_test_requires_manager_session "${test_file}"' "${RUNNER}"; then
    fail "the orchestrator must only wait for Manager session stability before tests that use that session"
fi
if ! grep -A20 -F '_test_requires_manager_session()' "${RUNNER}" |
    grep -Fq '15|16|17|18|19|20|21|22|23|24|25|26) return 1'; then
    fail "controller/runtime tests 15-26 must not pay the Manager session quiet-period cost"
fi
if ! grep -A20 -F '_test_requires_manager_session()' "${RUNNER}" |
    grep -Fq '08|09|10|11|13)'; then
    fail "GitHub Manager tests must be classified separately so skipped tests do not add quiet-period waits"
fi
if ! grep -Fq 'Finished: ${test_name} (${test_duration}s)' "${RUNNER}"; then
    fail "the orchestrator must report per-test wall-clock durations"
fi
if ! grep -Fq '_is_parallel_controller_test()' "${RUNNER}" ||
    ! grep -Fq '15|16|17|18|19|20|22|23|24|25) return 0' "${RUNNER}"; then
    fail "a full local run must overlap only the isolated controller tests"
fi
if ! grep -Fq '_is_serial_tail_test()' "${RUNNER}" ||
    ! grep -Fq '21|26) return 0' "${RUNNER}"; then
    fail "the Team DAG and QwenPaw plugin tests must remain serial after the parallel lane"
fi
if ! grep -Fq 'Starting parallel controller lane' "${RUNNER}"; then
    fail "the orchestrator must expose when full-run controller parallelism is active"
fi
if ! sed -n '/^install-embedded:/,/^wait-ready-embedded:/p' "${MAKEFILE}" |
    grep -Fq 'AGENTTEAMS_VERSION=$${AGENTTEAMS_VERSION:-$(VERSION)}'; then
    fail "make install-embedded must preserve an explicit AGENTTEAMS_VERSION and fall back to VERSION"
fi

skills_test="${SCRIPT_DIR}/test-24-skills-management.sh"
if ! grep -Fq 'Retrying the idempotent skills update once' "${skills_test}" ||
    ! grep -Fq 'UPDATE_RETRIED=true' "${skills_test}"; then
    fail "test 24 must retry one accepted-but-not-yet-observable idempotent update"
fi

team_leader_agents="${SCRIPT_DIR}/../manager/agent/team-leader-agent/AGENTS.md"
if ! grep -Fq 'Skill names are references, not callable tool names.' "${team_leader_agents}" ||
    ! grep -Fq 'Never emit a tool call named `project-management`' "${team_leader_agents}"; then
    fail "Team Leader guidance must distinguish skill references from callable tools"
fi

team_dag_test="${SCRIPT_DIR}/test-21-team-project-dag.sh"
if ! grep -Fq 'wait_agent_file_contains "${TEST_LEADER}" "AGENTS.md"' "${team_dag_test}" ||
    ! grep -Fq '"Project/tool boundary" 30' "${team_dag_test}"; then
    fail "test 21 must wait for the asynchronous Team Leader AGENTS overlay"
fi
if ! grep -Fq 'state: Stopped' "${team_dag_test}" ||
    ! grep -Fq 'agt update worker --name "${w}" --state Running' "${team_dag_test}"; then
    fail "test 21 must stage Team members stopped until the Team Leader assets are ready"
fi

team_config_test="${SCRIPT_DIR}/test-18-team-config-verify.sh"
if ! grep -Fq 'wait_agent_file_contains "${TEST_LEADER}" "AGENTS.md" "Upstream" 120' "${team_config_test}" ||
    ! grep -Fq 'wait_agent_file_contains "${TEST_LEADER}" "AGENTS.md" "${TEST_TEAM}" 120' "${team_config_test}"; then
    fail "test 18 must wait for the final Team Leader coordination overlay before asserting it"
fi

if ! higress_gateway_authorization_ready 401 \
    '{"error":{"code":"invalid_api_key","message":"Invalid API-key provided"}}'; then
    fail "an upstream invalid API key response proves the Gateway authorized and forwarded the request"
fi
if higress_gateway_authorization_ready 401 ""; then
    fail "an empty Gateway 401 response must remain an authorization failure"
fi
if higress_gateway_authorization_ready 000 ""; then
    fail "a transport failure must not be treated as successful Gateway authorization"
fi
if higress_llm_probe_ready 503 '{"error":{"message":"upstream unavailable"}}'; then
    fail "an upstream 503 must not be treated as a usable LLM"
fi
if ! higress_llm_probe_ready 200 '{"choices":[]}'; then
    fail "a successful chat completion response must mark the LLM usable"
fi

terminal_worker_wait=$(
    (
        TEST_CONTROLLER_CONTAINER=""
        TEST_AGENT_CONTAINER=""
        docker() {
            if [ "$1" = "inspect" ]; then
                printf 'exited\n'
            fi
        }
        # shellcheck source=lib/test-helpers.sh
        source "${SCRIPT_DIR}/lib/test-helpers.sh"
        log_info() { :; }
        dump_diagnostics() { :; }
        sleep() { printf 'slept\n'; }

        if wait_for_worker_container "terminal-worker" 5; then
            printf 'running\n'
        else
            printf 'failed\n'
        fi
    )
)
assert_eq "failed" "${terminal_worker_wait}" \
    "worker readiness must fail immediately when an existing container is already exited"

assign_task_test="${SCRIPT_DIR}/test-03-assign-task.sh"
finite_task_protocol="${SCRIPT_DIR}/lib/finite-task-protocol.sh"
finite_tasks_doc="${SCRIPT_DIR}/../manager/agent/skills/task-management/references/finite-tasks.md"
if [ ! -f "${finite_task_protocol}" ] ||
    ! grep -Fq 'copaw)' "${finite_task_protocol}" ||
    ! grep -Fq 'taskflow action ack_task' "${finite_task_protocol}" ||
    ! grep -Fq 'Do not invoke taskflow; it is only available to CoPaw Workers.' "${finite_task_protocol}" ||
    ! grep -Fq 'STATUS: SUCCESS' "${finite_task_protocol}" ||
    ! grep -Fq 'using your runtime-specific file-sync procedure' "${finite_task_protocol}"; then
    fail "finite-task tests must preserve structured completion while selecting the protocol supported by each Worker runtime"
fi
# shellcheck source=lib/finite-task-protocol.sh
source "${finite_task_protocol}"
copaw_acceptance=$(finite_task_acceptance_instruction copaw task-check)
hermes_acceptance=$(finite_task_acceptance_instruction hermes task-check)
copaw_completion=$(finite_task_completion_instruction copaw task-check summary '[]')
hermes_completion=$(finite_task_completion_instruction hermes task-check summary '[]')
openclaw_completion=$(finite_task_completion_instruction openclaw task-check summary '[]' \
    '!worker-room:matrix.test' '@manager:matrix.test')
if ! printf '%s' "${copaw_acceptance}" | grep -Fq 'taskflow action ack_task' ||
    printf '%s' "${hermes_acceptance}" | grep -Fq 'taskflow action ack_task' ||
    ! printf '%s' "${hermes_acceptance}" | grep -Fq 'Do not invoke taskflow' ||
    ! printf '%s' "${copaw_completion}" | grep -Fq 'taskflow action submit_task' ||
    printf '%s' "${hermes_completion}" | grep -Fq 'taskflow action submit_task' ||
    ! printf '%s' "${hermes_completion}" | grep -Fq 'STATUS: SUCCESS' ||
    ! printf '%s' "${openclaw_completion}" | grep -Fq 'message tool with channel=matrix and target=room:!worker-room:matrix.test' ||
    ! printf '%s' "${openclaw_completion}" | grep -Fq '@manager:matrix.test TASK_COMPLETED: task-check'; then
    fail "finite-task protocol helper selected an unsupported Worker lifecycle"
fi
finite_state_line=$(grep -n -m1 -- '--action add-finite' "${finite_tasks_doc}" | cut -d: -f1)
finite_notify_line=$(grep -n -m1 -F 'Notify Worker in their Room' "${finite_tasks_doc}" | cut -d: -f1)
if [ -z "${finite_state_line}" ] || [ -z "${finite_notify_line}" ] ||
    [ "${finite_state_line}" -ge "${finite_notify_line}" ]; then
    fail "finite-task guidance must register state before notifying a Worker to avoid fast-completion races"
fi
if ! grep -Fq 'Get the Worker runtime together with its `room_id`' "${finite_tasks_doc}" ||
    ! grep -Fq 'For a **CoPaw Worker**' "${finite_tasks_doc}" ||
    ! grep -Fq 'For every **non-CoPaw Worker**' "${finite_tasks_doc}"; then
    fail "finite-task dispatch guidance must select taskflow only for Workers that provide it"
fi
if ! grep -Fq 'minio_wait_for_content "${TASK_RESULT}" "STATUS: SUCCESS" 120' \
    "${assign_task_test}"; then
    fail "test 03 must wait for a successful structured result with a bounded timeout"
fi

if ! grep -A5 -F 'Task brief was not created within 120s' \
    "${assign_task_test}" | grep -Fq 'exit 1'; then
    fail "test 03 must fail fast when the task brief dependency is missing"
fi
if ! grep -Fq 'project_id: "standalone"' "${assign_task_test}" ||
    ! grep -Fq 'Do not recreate or replace its task metadata' "${assign_task_test}"; then
    fail "test 03 must seed the task brief deterministically instead of asking the Manager model to rewrite it"
fi
if ! grep -Fq 'Register it with manage-state.sh before sending any Matrix message to Alice' \
    "${assign_task_test}"; then
    fail "test 03 must make the state-before-dispatch ordering explicit to the Manager"
fi
if ! grep -Fq 'wait_for_manager_task_state true 30' "${assign_task_test}" ||
    ! grep -Fq 'wait_for_manager_task_state false 60' "${assign_task_test}"; then
    fail "test 03 must finish the Manager task lifecycle before test 04 starts"
fi
if ! grep -Fq '"Processed ${SPEC_MARKER}" '\''[]'\'' "${ALICE_ROOM}" "${MANAGER_USER}")' \
    "${assign_task_test}"; then
    fail "test 03 must give OpenClaw a non-streamed completion route that can wake the Manager"
fi
if ! grep -A5 -F 'Alice did not submit a successful result within 120s' \
    "${assign_task_test}" | grep -Fq 'exit 1'; then
    fail "test 03 must fail fast when the structured result dependency is missing"
fi

human_intervene_test="${SCRIPT_DIR}/test-04-human-intervene.sh"
if ! grep -Fq 'Assign Alice one finite task with exact ID ${TASK_ID}' "${human_intervene_test}"; then
    fail "test 04 must create the intervention task with a deterministic ID"
fi
if ! grep -Fq 'RESULT_FILE="${TASK_DIR}/workspace/hello.py"' "${human_intervene_test}"; then
    fail "test 04 must verify the deliverable under the finite-task workspace directory"
fi
if ! grep -Fq 'project_id: "standalone"' "${human_intervene_test}" ||
    ! grep -Fq 'assigned_to: "alice"' "${human_intervene_test}" ||
    ! grep -Fq 'Do not recreate or replace its task metadata' "${human_intervene_test}"; then
    fail "test 04 must seed deterministic task metadata instead of asking the Manager model to invent it"
fi
if ! grep -Fq 'finite_task_sync_instruction "${TEST_WORKER_RUNTIME}" "${START_FILE}"' "${human_intervene_test}" ||
    ! grep -Fq 'minio_wait_for_content "${START_FILE}" "${ORIGINAL_MARKER}" 120' "${human_intervene_test}"; then
    fail "test 04 must sync the start marker with the selected Worker runtime and bound that dependency to 120 seconds"
fi
if ! grep -Fq 'finite_task_sync_instruction "${TEST_WORKER_RUNTIME}" "${RESULT_FILE}"' "${human_intervene_test}" ||
    ! grep -Fq 'minio_wait_for_content "${RESULT_FILE}" "${SUPPLEMENT_MARKER}" 120' "${human_intervene_test}"; then
    fail "test 04 must sync the final deliverable with the selected Worker runtime and bound that dependency to 120 seconds"
fi
if ! grep -Fq 'finite_task_completion_instruction "${TEST_WORKER_RUNTIME}" "${TASK_ID}"' "${human_intervene_test}" ||
    ! grep -Fq 'minio_wait_for_content "${TASK_RESULT}" "STATUS: SUCCESS" 120' "${human_intervene_test}"; then
    fail "test 04 must close the finite task through the selected Worker protocol before the next test starts"
fi
if ! grep -Fq '"[\"${RESULT_FILE}\"]"' "${human_intervene_test}"; then
    fail "test 04 must preserve the structured result deliverable for every Worker runtime"
fi
if ! grep -Fq 'wait_for_manager_task_state true 30' "${human_intervene_test}" ||
    ! grep -Fq 'wait_for_manager_task_state false 60' "${human_intervene_test}"; then
    fail "test 04 must verify Manager state registration and completion before the next heartbeat"
fi
if ! grep -Fq '"${ALICE_ROOM}" "${MANAGER_USER}")' "${human_intervene_test}"; then
    fail "test 04 must give OpenClaw a non-streamed completion route that can wake the Manager"
fi
if ! grep -Fq 'matrix_wait_for_mentioned_reply_matching_since' "${human_intervene_test}" ||
    ! grep -Fq 'visibly @mention exact Matrix ID ${ALICE_MATRIX_ID}' "${human_intervene_test}"; then
    fail "test 04 must verify that the supplement targets Alice's exact Matrix ID"
fi
if ! grep -Fq 'Supplement result missing; stopping without another blind wait' "${human_intervene_test}"; then
    fail "test 04 must fail fast when the supplementary deliverable misses its deadline"
fi

heartbeat_test="${SCRIPT_DIR}/test-05-heartbeat.sh"
for heartbeat_doc in \
    "${SCRIPT_DIR}/../manager/agent/HEARTBEAT.md" \
    "${SCRIPT_DIR}/../manager/agent/copaw-manager-agent/HEARTBEAT.md"; do
    if ! grep -Fq 'Never infer finite-task completion from room prose or deliverable presence.' "${heartbeat_doc}" ||
        ! grep -Fq 'result.md starts with `STATUS: SUCCESS` or `STATUS: FAILED`' "${heartbeat_doc}"; then
        fail "Manager heartbeat must keep finite tasks active until the Worker writes a structured terminal result"
    fi
done
if ! grep -Fq 'Assign Alice one finite task with exact ID ${TASK_ID}' "${heartbeat_test}"; then
    fail "test 05 must create the heartbeat task with a deterministic ID"
fi
if ! grep -Fq 'project_id: "standalone"' "${heartbeat_test}" ||
    ! grep -Fq 'Do not recreate or replace its task metadata' "${heartbeat_test}"; then
    fail "test 05 must seed deterministic task metadata so the heartbeat observes an in-progress task"
fi
if ! grep -Fq 'minio_wait_for_file "${OUTLINE_FILE}" 120' "${heartbeat_test}"; then
    fail "test 05 must wait for Alice to start the current task before triggering heartbeat"
fi
if ! grep -Fq 'matrix_wait_for_reply_matching_since "${ADMIN_TOKEN}" "${ALICE_ROOM}" "@manager"' "${heartbeat_test}" ||
    ! grep -Fq '"${MANAGER_ROOM_BASELINE}" "${TASK_ID}" 120' "${heartbeat_test}"; then
    fail "test 05 must correlate the heartbeat inquiry to its current task and use a bounded wait"
fi
if ! grep -Fq '(.content["m.mentions"].user_ids // []) | index($alice) != null' "${heartbeat_test}"; then
    fail "test 05 must verify the Manager heartbeat inquiry structurally mentions the assigned Worker"
fi
if ! grep -Fq '/api/agents/default/config/heartbeat' "${heartbeat_test}" ||
    ! grep -Fq '.every = "1s"' "${heartbeat_test}" ||
    ! grep -Fq '_restore_copaw_heartbeat' "${heartbeat_test}"; then
    fail "test 05 must trigger and restore CoPaw's real scheduled heartbeat instead of using the admin DM session"
fi
heartbeat_inquiry_line=$(grep -n '^INQUIRY=' "${heartbeat_test}" | head -1 | cut -d: -f1)
heartbeat_restore_line=$(grep -n '^[[:space:]]*_restore_copaw_heartbeat$' "${heartbeat_test}" | tail -1 | cut -d: -f1)
if [ -z "${heartbeat_inquiry_line}" ] ||
    [ -z "${heartbeat_restore_line}" ] ||
    [ "${heartbeat_restore_line}" -le "${heartbeat_inquiry_line}" ]; then
    fail "test 05 must keep CoPaw's accelerated schedule active until the first heartbeat inquiry is observed"
fi
if ! grep -Fq 'wait_for_manager_task_state true 30' "${heartbeat_test}" ||
    ! grep -Fq 'minio_wait_for_content "${TASK_RESULT}" "STATUS: SUCCESS" 120' "${heartbeat_test}" ||
    ! grep -Fq -- '--action complete --task-id "${TASK_ID}"' "${heartbeat_test}"; then
    fail "test 05 must verify structured completion and deterministically clean its fixture state"
fi
if ! grep -Fq 'matrix_send_mention_message "${ADMIN_TOKEN}" "${ALICE_ROOM}" "${ALICE_USER}" "${CLOSE_MESSAGE}"' "${heartbeat_test}"; then
    fail "test 05 cleanup must address Alice directly instead of adding another Manager LLM turn"
fi
if ! grep -Fq '"${ALICE_ROOM_BASELINE}" "HEARTBEAT_PROGRESS ${TASK_ID}" 60' "${heartbeat_test}" ||
    ! grep -Fq 'matrix_send_mention_message "${ADMIN_TOKEN}" "${ALICE_ROOM}" "${ALICE_USER}" "${PROGRESS_NUDGE}"' "${heartbeat_test}" ||
    ! grep -Fq '"${PROGRESS_NUDGE_BASELINE}" "HEARTBEAT_PROGRESS ${TASK_ID}" 60' "${heartbeat_test}"; then
    fail "test 05 must retry one correlated Worker progress request and fail within two bounded 60-second waits"
fi

if ! grep -Fq 'grep -Fq "**Name:** Manager" /root/manager-workspace/SOUL.md' "${RUNNER}" ||
    ! grep -Fq 'grep -Fqi "always respond in English" /root/manager-workspace/SOUL.md' "${RUNNER}"; then
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
if ! grep -Fq 'PROJECT_MEMBER_JOIN_TIMEOUT=90' "${git_collab_test}" ||
    ! grep -Fq '"@${w}:${TEST_MATRIX_DOMAIN}" "${PROJECT_MEMBER_JOIN_TIMEOUT}" &' "${git_collab_test}"; then
    fail "test 14 must allow bounded startup jitter when three Workers join the project room concurrently"
fi
if ! grep -Fq 'overall timeout: 420s, no-activity timeout: 90s' "${git_collab_test}" ||
    ! grep -Fq 'PROJECT_MESSAGES=$(matrix_read_messages' "${git_collab_test}" ||
    ! grep -Fq 'PROJECT_ACTIVITY=$(echo "${PROJECT_MESSAGES}"' "${git_collab_test}"; then
    fail "test 14 must use a bounded activity-aware collaboration deadline"
fi
if ! grep -Fq 'matrix_send_mention_message "${MANAGER_TOKEN}" "${PROJECT_ROOM}"' "${git_collab_test}" ||
    ! grep -Fq '"@alice:${TEST_MATRIX_DOMAIN}" "${PHASE1_MESSAGE}"' "${git_collab_test}" ||
    ! grep -Fq 'PHASE2_SENT=1' "${git_collab_test}" ||
    ! grep -Fq 'PHASE3_SENT=1' "${git_collab_test}" ||
    ! grep -Fq 'PHASE4_SENT=1' "${git_collab_test}"; then
    fail "test 14 must schedule all four phases with explicit mentions from observed git progress"
fi
if ! grep -Fq 'PHASE3_BASE_SHA="${FEATURE_SHA}"' "${git_collab_test}" ||
    ! grep -Fq '[ "${FEATURE_SHA}" != "${PHASE3_BASE_SHA}" ]' "${git_collab_test}"; then
    fail "test 14 must wait for Alice to update the exact post-review feature SHA before starting verification"
fi
if ! grep -Fq 'phase_report_seen "@alice:${TEST_MATRIX_DOMAIN}" "PHASE1_DONE ${TEST_RUN_ID}"' "${git_collab_test}" ||
    ! grep -Fq 'phase_report_seen "@bob:${TEST_MATRIX_DOMAIN}" "REVISION_NEEDED ${TEST_RUN_ID}"' "${git_collab_test}" ||
    ! grep -Fq 'phase_report_seen "@alice:${TEST_MATRIX_DOMAIN}" "PHASE3_DONE ${TEST_RUN_ID}"' "${git_collab_test}" ||
    ! grep -Fq 'phase_report_seen "@charlie:${TEST_MATRIX_DOMAIN}" "PHASE4_DONE ${TEST_RUN_ID}"' "${git_collab_test}" ||
    ! grep -Fq 'PHASE4_BASE_SHA="${FEATURE_SHA}"' "${git_collab_test}" ||
    ! grep -Fq 'merge-base --is-ancestor "${PHASE4_BASE_SHA}" "${TEST_BRANCH}"' "${git_collab_test}"; then
    fail "test 14 must gate every phase on the assigned Worker's correlated report and verify Alice's completed revision"
fi
if ! grep -Fq -- '- [x] Summary section exists' "${git_collab_test}" ||
    ! grep -Fq -- '- [x] Goals section exists' "${git_collab_test}" ||
    ! grep -Fq -- '- [x] Review request addressed' "${git_collab_test}"; then
    fail "test 14 must give Charlie a deterministic verification checklist covering every assertion"
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
if ! grep -Fq 'Do not create a Project Room and do not notify Bob yet' "${multi_worker_test}" ||
    ! grep -Fq '_wait_for_file_with_nudge "${ALICE_FILE}" 150 60' "${multi_worker_test}" ||
    ! grep -Fq '_wait_for_file_with_nudge "${BOB_FILE}" 150 60' "${multi_worker_test}"; then
    fail "test 06 must use bounded sequential finite-task handoff without an unnecessary project room"
fi

qwenpaw_team_test="${SCRIPT_DIR}/test-26-qwenpaw-teamharness-plugin-mode.sh"
qwenpaw_container_wait_line=$(grep -n -m1 'if wait_for_worker_container "${member}" 240' "${qwenpaw_team_test}" | cut -d: -f1)
qwenpaw_phase_wait_line=$(grep -n -m1 "'.status.phase == \"Running\"' 240" "${qwenpaw_team_test}" | cut -d: -f1)
if [ -z "${qwenpaw_container_wait_line}" ] || [ -z "${qwenpaw_phase_wait_line}" ] ||
    [ "${qwenpaw_container_wait_line}" -ge "${qwenpaw_phase_wait_line}" ]; then
    fail "test 26 must inspect the concrete Worker container before waiting on the derived Running phase"
fi
for failure in \
    'Member ${member} not provisioned' \
    'Member ${member} did not reach Running' \
    'Container for ${member} did not start'; do
    if ! grep -A5 -F "${failure}" "${qwenpaw_team_test}" | grep -Fq 'exit 1'; then
        fail "test 26 must stop immediately after the failed QwenPaw member prerequisite: ${failure}"
    fi
done
if grep -Eq 'matrix_wait_for_message_containing.* (480|720)' "${qwenpaw_team_test}" ||
    ! grep -Fq '"${WORKER_REPLY_BASELINE}"' "${qwenpaw_team_test}" ||
    ! grep -Fq 'Task submission metadata exists in shared storage' "${qwenpaw_team_test}"; then
    fail "test 26 must use pre-send Matrix baselines, bounded waits, and the TeamHarness submission metadata contract"
fi
if ! grep -Fq '_wait_runtime_team_roster 60' "${qwenpaw_team_test}"; then
    fail "test 26 must wait briefly for both runtime.yaml roster projections instead of taking a one-shot snapshot"
fi
if ! grep -Fq 'matrix_wait_for_reply_matching_since' "${qwenpaw_team_test}" ||
    ! grep -Fq '"${WORKER_REPLY_BASELINE}" "${DONE_LINE}" 120' "${qwenpaw_team_test}"; then
    fail "test 26 must correlate the exact Worker completion reply to a pre-send baseline within 120 seconds"
fi
if ! tail -n 20 "${qwenpaw_team_test}" |
    grep -A1 -F 'if [ "${TESTS_FAILED}" -gt 0 ]; then' |
    grep -Fq '_dump_debug_snapshot'; then
    fail "test 26 must only collect its expensive debug snapshot after a failure"
fi

skills_test="${SCRIPT_DIR}/test-24-skills-management.sh"
if ! grep -Fq 'copaw) BUILTIN_SKILL="file-sharing"' "${skills_test}" ||
    ! grep -Fq 'minio_wait_for_file "agents/${TEST_WORKER}/skills/${BUILTIN_SKILL}/SKILL.md" 30' "${skills_test}"; then
    fail "test 24 must bound the eventual-consistency wait for built-in skill mirroring"
fi

echo "Integration test plan checks passed."
