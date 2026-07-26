#!/bin/bash
# Unit checks for runtime-aware Worker metrics workspace detection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TEST_CONTROLLER_CONTAINER=test-controller
export TEST_AGENT_CONTAINER=test-agent

docker() {
    if [ "$*" = "exec worker-copaw test -d /root/.copaw-worker/alice/.copaw" ]; then
        return 0
    fi
    return 1
}

source "${SCRIPT_DIR}/lib/agent-metrics.sh"

copaw_root=$(_worker_workspace_root worker-copaw alice)
if [ "${copaw_root}" != "/root/.copaw-worker/alice" ]; then
    echo "FAIL: expected CoPaw Worker metrics root, got: ${copaw_root}" >&2
    exit 1
fi

openclaw_root=$(_worker_workspace_root worker-openclaw bob)
if [ "${openclaw_root}" != "/root/agentteams-fs/agents/bob" ]; then
    echo "FAIL: expected standard Worker metrics root, got: ${openclaw_root}" >&2
    exit 1
fi

echo "Agent metrics runtime checks passed."
