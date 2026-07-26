#!/bin/bash
# test-14-git-collab.sh - Case 14: Non-linear multi-Worker local git collaboration
# Verifies: 4-phase PR-style collaboration using local bare git repo (no GitHub required):
#   Phase 1 (alice): implement feature on a branch
#   Phase 2 (bob): review and request changes via a review branch
#   Phase 3 (alice): fix based on review, update branch
#   Phase 4 (charlie): add tests on a test branch

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
source "${SCRIPT_DIR}/lib/agent-metrics.sh"

test_setup "14-git-collab"

if ! require_llm_key; then
    test_teardown "14-git-collab"
    test_summary
    exit 0
fi

ADMIN_LOGIN=$(matrix_login "${TEST_ADMIN_USER}" "${TEST_ADMIN_PASSWORD}")
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | jq -r '.access_token')

MANAGER_USER="@manager:${TEST_MATRIX_DOMAIN}"

# Generate unique branch names for this test run
TEST_RUN_ID=$(date +%s)
REPO_PATH="/root/git-repos/collab-test-${TEST_RUN_ID}"
FEATURE_BRANCH="feature/proposal-${TEST_RUN_ID}"
REVIEW_BRANCH="review/proposal-${TEST_RUN_ID}"
TEST_BRANCH="verify/proposal-${TEST_RUN_ID}"
PROJECT_NAME="Project: git-collab-${TEST_RUN_ID}"
GIT_DAEMON_PORT=19418
GIT_DAEMON_PID="/tmp/agentteams-git-daemon-${TEST_RUN_ID}.pid"

log_section "Setup: Initialize Bare Git Repo"

docker exec "${TEST_CONTROLLER_CONTAINER}" bash -c "
    set -e
    mkdir -p '${REPO_PATH}.git'
    git init --bare '${REPO_PATH}.git'
    tmpdir=\$(mktemp -d)
    git -C \"\$tmpdir\" init
    git -C \"\$tmpdir\" remote add origin '${REPO_PATH}.git'
    echo '# Collab Test Project' > \"\$tmpdir/README.md\"
    git -C \"\$tmpdir\" add .
    git -C \"\$tmpdir\" -c user.email='setup@agentteams.io' -c user.name='Setup' -c core.hooksPath=/dev/null commit -m 'Initial commit'
    git -C \"\$tmpdir\" push origin HEAD:main
    rm -rf \"\$tmpdir\"
    git daemon --reuseaddr --listen=0.0.0.0 --port=${GIT_DAEMON_PORT} \
        --base-path=/root/git-repos --export-all --enable=receive-pack \
        --detach --pid-file='${GIT_DAEMON_PID}'
" || {
    log_fail "Failed to initialize bare git repo"
    test_teardown "14-git-collab"
    test_summary
    exit 1
}
log_pass "Bare git repo initialized at ${REPO_PATH}.git"

_cleanup_git_repo() {
    docker exec "${TEST_CONTROLLER_CONTAINER}" sh -c \
        "test ! -f '${GIT_DAEMON_PID}' || kill \$(cat '${GIT_DAEMON_PID}')" \
        2>/dev/null || true
    docker exec "${TEST_CONTROLLER_CONTAINER}" rm -rf "${REPO_PATH}.git" 2>/dev/null || true
    docker exec "${TEST_CONTROLLER_CONTAINER}" rm -f "${GIT_DAEMON_PID}" 2>/dev/null || true
}
trap _cleanup_git_repo EXIT

# Expose the temporary bare repo only on the test Docker network so every
# runtime can perform the same clone/push workflow without credentials.
GIT_REPO_URL="git://agentteams-controller:${GIT_DAEMON_PORT}/$(basename "${REPO_PATH}").git"
log_info "Git repo URL (test Docker network only): ${GIT_REPO_URL}"

log_section "Setup: Find or Create DM Room"

DM_ROOM=$(matrix_find_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}" 2>/dev/null || true)

if [ -z "${DM_ROOM}" ]; then
    log_info "Creating DM room with Manager..."
    DM_ROOM=$(matrix_create_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}")
    sleep 5
fi

assert_not_empty "${DM_ROOM}" "DM room with Manager exists"

wait_for_manager_agent_ready 300 "${DM_ROOM}" "${ADMIN_TOKEN}" || {
    log_fail "Manager Agent not ready in time"
    docker exec "${TEST_CONTROLLER_CONTAINER}" rm -rf "${REPO_PATH}.git" 2>/dev/null || true
    test_teardown "14-git-collab"
    test_summary
    exit 1
}

log_section "Phase 1-4: Assign 4-Phase Git Collaboration Task"

TASK_DESCRIPTION="Please coordinate a 4-phase git collaboration workflow to test non-linear multi-worker coordination.

Git repo URL (reachable from all worker containers): ${GIT_REPO_URL}
The repo has a 'main' branch with an initial commit.

⚠️ CRITICAL WORKER ASSIGNMENT TABLE — MUST FOLLOW EXACTLY, NO EXCEPTIONS:

| Phase | Assigned Worker | Trigger condition                     |
|-------|-----------------|---------------------------------------|
| 1     | alice           | start immediately                     |
| 2     | bob             | ONLY after alice reports PHASE1_DONE  |
| 3     | alice           | ONLY after bob reports REVISION_NEEDED|
| 4     | charlie         | ONLY after alice reports PHASE3_DONE  |

DO NOT assign any phase to a different worker. DO NOT give alice phase 2 or phase 4. DO NOT give bob phase 1 or phase 3. DO NOT give charlie any phase except phase 4. Each phase must be done by the worker listed above and no one else.

IMPORTANT: You MUST use the EXACT branch names and file paths specified below. Do not rename, substitute, or simplify them. The verification system checks these exact names.

Before starting any phase:
1. Ensure workers with usernames exactly 'alice', 'bob', and 'charlie' exist with the git-delegation skill. The username (container name) must match exactly — do not use variations like 'alice-dev' or 'bob-backend'. IMPORTANT: Create any missing workers IN PARALLEL (run all create-worker.sh calls concurrently) to save time — do NOT create them one by one sequentially. When creating any missing worker, use these exact values — do NOT ask me to confirm any of them:
   - runtime: install default
   - skills: github-operations, git-delegation
   - SOUL/role: 'Developer working on a shared git repo using git-delegation workflows'
   If a worker already exists, reuse it.
2. Create a shared project room named EXACTLY '${PROJECT_NAME}' that includes alice, bob, charlie, and the human admin (use the create-project.sh script). All phase assignments and reports MUST happen in this project room — never in individual worker rooms.
3. The temporary git:// URL is directly reachable from every Worker and needs no credentials. Tell Workers to run the listed git commands directly. Do NOT use git-request or git-delegation for this test.

Run the phases strictly in order, waiting for each phase's report before starting the next.

**Phase 1 — alice (and only alice)**:
- Clone ${GIT_REPO_URL}
- Create branch named EXACTLY '${FEATURE_BRANCH}' from main (do not use any other name)
- Create file at path EXACTLY 'doc/proposal.md' with this content:
  # Project Proposal

  ## Background
  This project aims to improve team collaboration.

  ## Goals
  - Faster delivery
  - Better quality
- Commit with message 'feat: add proposal' and push branch '${FEATURE_BRANCH}' to ${GIT_REPO_URL}
- Report PHASE1_DONE

**Phase 2 — bob and only bob** (assign to bob, NOT alice, only after alice reports PHASE1_DONE):
- Clone ${GIT_REPO_URL}, check out branch '${FEATURE_BRANCH}', read doc/proposal.md
- Create branch named EXACTLY '${REVIEW_BRANCH}' from '${FEATURE_BRANCH}' (do not use any other name)
- Create file at path EXACTLY 'reviews/proposal-review.md' with this content:
  # Review

  The proposal looks good. Please add a ## Summary section at the top that briefly describes the project in one sentence.
- Commit 'review: request summary section' and push branch '${REVIEW_BRANCH}' to ${GIT_REPO_URL}
- Report REVISION_NEEDED

**Phase 3 — alice and only alice** (assign back to alice, NOT bob, only after bob reports REVISION_NEEDED):
- Work on branch '${FEATURE_BRANCH}' (not a new branch)
- Read bob's review file at path 'reviews/proposal-review.md' on branch '${REVIEW_BRANCH}'
- Edit 'doc/proposal.md' on branch '${FEATURE_BRANCH}': add a '## Summary' section immediately after the '# Project Proposal' title line, with one sentence describing the project
- Commit 'fix: add summary section per review' and push branch '${FEATURE_BRANCH}' to ${GIT_REPO_URL}
- Report PHASE3_DONE

**Phase 4 — charlie and only charlie** (assign to charlie, NOT alice or bob, only after alice reports PHASE3_DONE):
- Clone ${GIT_REPO_URL}, create branch named EXACTLY '${TEST_BRANCH}' from '${FEATURE_BRANCH}' (do not use any other name)
- Create file at path EXACTLY 'verify/checklist.md' confirming: (1) proposal.md has a Summary section, (2) Goals section is present, (3) review was addressed
- Commit 'verify: proposal review checklist' and push branch '${TEST_BRANCH}' to ${GIT_REPO_URL}
- Report PHASE4_DONE

When all 4 phases are done, post exactly 'GIT_COLLAB_COMPLETE ${TEST_RUN_ID}' in the project room and @mention the human admin."

# Snapshot before first LLM interaction
METRICS_BASELINE=$(snapshot_baseline "alice" "bob" "charlie")

MANAGER_BASELINE_EVENT=$(matrix_latest_reply_event "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager")
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "${TASK_DESCRIPTION}"

log_info "Waiting for Manager to acknowledge and start coordination..."
REPLY=$(matrix_wait_for_reply_since "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" \
    "${MANAGER_BASELINE_EVENT}" 300 \
    "${ADMIN_TOKEN}" "${DM_ROOM}" "Please check if the git collaboration task has been processed.")

if [ -n "${REPLY}" ]; then
    log_pass "Manager acknowledged the git collaboration task"
else
    log_info "No explicit acknowledgment (Manager may have started processing directly)"
fi

log_section "Wait for Workflow State"

# Get Manager's Matrix token (retry until openclaw.json is written)
log_info "Waiting for Manager token (timeout: 120s)..."
MANAGER_TOKEN=""
DEADLINE=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    MANAGER_TOKEN=$(docker exec "${TEST_AGENT_CONTAINER}" \
        jq -r '.channels.matrix.accessToken // empty' /root/manager-workspace/openclaw.json 2>/dev/null || true)
    [ -n "${MANAGER_TOKEN}" ] && break
    sleep 5
done
assert_not_empty "${MANAGER_TOKEN}" "Manager Matrix token available"
if [ -z "${MANAGER_TOKEN}" ]; then
    test_teardown "14-git-collab"
    test_summary
    exit 1
fi

log_info "Waiting for the correlated project room (timeout: 300s)..."
PROJECT_ROOM=""
DEADLINE=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    PROJECT_ROOM=$(matrix_find_room_by_name "${MANAGER_TOKEN}" "git-collab-${TEST_RUN_ID}" 2>/dev/null || true)
    [ -n "${PROJECT_ROOM}" ] && break
    sleep 5
done
assert_not_empty "${PROJECT_ROOM}" "Project room created by Manager"
if [ -z "${PROJECT_ROOM}" ]; then
    test_teardown "14-git-collab"
    test_summary
    exit 1
fi
log_info "Project room: ${PROJECT_ROOM}"

PROJECT_BASELINE_EVENT=$(matrix_latest_reply_event "${MANAGER_TOKEN}" "${PROJECT_ROOM}" "@manager")

log_info "Waiting for collaboration milestones (overall timeout: 600s, no-progress timeout: 120s)..."
DEADLINE=$(( $(date +%s) + 600 ))
STALL_DEADLINE=$(( $(date +%s) + 120 ))
NEXT_NUDGE=$(( $(date +%s) + 45 ))
LAST_STATE=""
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    FEATURE_SHA=$(docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
        rev-parse --verify "refs/heads/${FEATURE_BRANCH}" 2>/dev/null || true)
    REVIEW_SHA=$(docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
        rev-parse --verify "refs/heads/${REVIEW_BRANCH}" 2>/dev/null || true)
    TEST_SHA=$(docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
        rev-parse --verify "refs/heads/${TEST_BRANCH}" 2>/dev/null || true)
    FEATURE_COMMITS=0
    if [ -n "${FEATURE_SHA}" ]; then
        FEATURE_COMMITS=$(docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
            rev-list --count "main..${FEATURE_BRANCH}" 2>/dev/null || echo 0)
    fi
    STATE="${FEATURE_SHA}:${REVIEW_SHA}:${FEATURE_COMMITS}:${TEST_SHA}"

    if [ -n "${TEST_SHA}" ] && [ "${FEATURE_COMMITS}" -ge 2 ]; then
        break
    fi

    NOW=$(date +%s)
    if [ "${STATE}" != "${LAST_STATE}" ]; then
        log_info "Git collaboration advanced (feature commits=${FEATURE_COMMITS}, review=$([ -n "${REVIEW_SHA}" ] && echo yes || echo no), verify=$([ -n "${TEST_SHA}" ] && echo yes || echo no))"
        LAST_STATE="${STATE}"
        STALL_DEADLINE=$((NOW + 120))
        NEXT_NUDGE=$((NOW + 45))
    elif [ "${NOW}" -ge "${STALL_DEADLINE}" ]; then
        log_fail "Git collaboration made no branch progress for 120s"
        break
    elif [ "${NOW}" -ge "${NEXT_NUDGE}" ]; then
        if [ -z "${FEATURE_SHA}" ]; then
            NUDGE="Continue git collaboration ${TEST_RUN_ID}: explicitly @mention Alice and remind her to clone ${GIT_REPO_URL} directly (no git-request) and push ${FEATURE_BRANCH}."
        elif [ -z "${REVIEW_SHA}" ]; then
            NUDGE="Continue git collaboration ${TEST_RUN_ID}: Phase 1 is pushed; explicitly @mention Bob with Phase 2 and require ${REVIEW_BRANCH}."
        elif [ "${FEATURE_COMMITS}" -lt 2 ]; then
            NUDGE="Continue git collaboration ${TEST_RUN_ID}: Bob's review is pushed; explicitly @mention Alice with Phase 3 and require the second commit on ${FEATURE_BRANCH}."
        else
            NUDGE="Continue git collaboration ${TEST_RUN_ID}: Alice's revision is pushed; explicitly @mention Charlie with Phase 4 and require ${TEST_BRANCH}."
        fi
        matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "${NUDGE}" >/dev/null
        NEXT_NUDGE=$((NOW + 45))
    fi
    sleep 5
done

if docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
        show-ref --verify --quiet "refs/heads/${FEATURE_BRANCH}" \
    && docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
        show-ref --verify --quiet "refs/heads/${REVIEW_BRANCH}" \
    && docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
        show-ref --verify --quiet "refs/heads/${TEST_BRANCH}"; then
    log_pass "Feature, review, and verification branches were pushed"
else
    log_info "Available refs:"
    docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" show-ref 2>/dev/null || true
    log_fail "Collaboration branches were not all available before the progress deadline"
    test_teardown "14-git-collab"
    test_summary
    exit 1
fi

FEATURE_CONTENT=$(docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
    show "${FEATURE_BRANCH}:doc/proposal.md" 2>/dev/null || true)
REVIEW_CONTENT=$(docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
    show "${REVIEW_BRANCH}:reviews/proposal-review.md" 2>/dev/null || true)
VERIFY_CONTENT=$(docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
    show "${TEST_BRANCH}:verify/checklist.md" 2>/dev/null || true)

assert_contains "${FEATURE_CONTENT}" "## Summary" \
    "Alice incorporated Bob's requested Summary section"
assert_contains "${FEATURE_CONTENT}" "## Goals" \
    "Feature branch preserves the original Goals section"
assert_contains "${REVIEW_CONTENT}" "Please add a ## Summary section" \
    "Bob pushed the requested review"
assert_contains_i "${VERIFY_CONTENT}" "summary" \
    "Charlie verified the Summary requirement"
assert_contains_i "${VERIFY_CONTENT}" "goals" \
    "Charlie verified the Goals requirement"

if docker exec "${TEST_CONTROLLER_CONTAINER}" git --git-dir="${REPO_PATH}.git" \
        merge-base --is-ancestor "${FEATURE_BRANCH}" "${TEST_BRANCH}" 2>/dev/null; then
    log_pass "Verification branch is based on Alice's updated feature branch"
else
    log_fail "Verification branch is not based on the updated feature branch"
fi

if [ "${TESTS_FAILED}" -gt 0 ]; then
    test_teardown "14-git-collab"
    test_summary
    exit 1
fi

log_info "Waiting for the correlated completion marker (timeout: 120s)..."
COMPLETION_MSG=$(matrix_read_messages "${MANAGER_TOKEN}" "${PROJECT_ROOM}" 50 2>/dev/null | \
    jq -r --arg marker "GIT_COLLAB_COMPLETE ${TEST_RUN_ID}" \
    '[.chunk[] | select(.sender | startswith("@manager")) | .content.body | select(contains($marker))] | first // empty' \
    2>/dev/null || true)
if [ -z "${COMPLETION_MSG}" ]; then
    COMPLETION_MSG=$(matrix_wait_for_reply_matching_since \
        "${MANAGER_TOKEN}" "${PROJECT_ROOM}" "@manager" "${PROJECT_BASELINE_EVENT}" \
        "GIT_COLLAB_COMPLETE ${TEST_RUN_ID}" 120 \
        "${ADMIN_TOKEN}" "${DM_ROOM}" \
        "Please finish git collaboration ${TEST_RUN_ID} and post the exact completion marker." \
        30 2>/dev/null || true)
fi
assert_not_empty "${COMPLETION_MSG}" \
    "Manager posted the correlated completion marker in the project room"

log_section "Collect Metrics"

wait_for_worker_session_stable "alice" 5 120
wait_for_worker_session_stable "bob" 5 120
wait_for_worker_session_stable "charlie" 5 120
wait_for_session_stable 5 60
PREV_METRICS=$(cat "${TEST_OUTPUT_DIR}/metrics-14-git-collab.json" 2>/dev/null || true)
METRICS=$(collect_delta_metrics "14-git-collab" "$METRICS_BASELINE" "alice" "bob" "charlie")
print_metrics_report "$METRICS" "$PREV_METRICS"
save_metrics_file "$METRICS" "14-git-collab"

log_section "Cleanup"

_cleanup_git_repo
trap - EXIT
log_info "Removed bare git repo"

test_teardown "14-git-collab"
test_summary
