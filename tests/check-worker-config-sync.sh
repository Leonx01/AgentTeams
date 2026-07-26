#!/bin/bash
# Verify Worker config sync never exposes a transient remote openclaw.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNC_SCRIPT="${REPO_ROOT}/manager/agent/worker-agent/skills/file-sync/scripts/agentteams-sync.sh"
MERGE_HELPER="${REPO_ROOT}/shared/lib/merge-openclaw-config.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

sync_block=$(awk '
    /^mc mirror .*AGENTTEAMS_STORAGE_PREFIX.*agents/ { capture = 1 }
    capture { print }
    capture && /^$/ { exit }
' "${SYNC_SCRIPT}")
if ! grep -q -- '--exclude "openclaw.json"' <<<"${sync_block}"; then
    fail "Worker mirror must exclude the live openclaw.json"
fi

if ! grep -q 'REMOTE_OPENCLAW="/tmp/openclaw-remote-sync.json"' "${SYNC_SCRIPT}" ||
   ! grep -q 'mc cp .*openclaw.json.*REMOTE_OPENCLAW' "${SYNC_SCRIPT}"; then
    fail "Worker sync must download remote openclaw.json to a temporary file"
fi

if ! grep -q 'merge_openclaw_config .*REMOTE_OPENCLAW.*LOCAL_OPENCLAW' "${SYNC_SCRIPT}"; then
    fail "Worker sync must merge the temporary remote config into the live config"
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

local_config="${tmp_dir}/local.json"
remote_config="${tmp_dir}/remote.json"
marker="${tmp_dir}/marker"

jq -n '{
    channels: {matrix: {accessToken: "local-token", homeserver: "https://matrix.example"}},
    gateway: {port: 18789}
}' > "${local_config}"
jq -n '{
    channels: {matrix: {accessToken: "stale-remote-token", homeserver: "https://matrix.example"}},
    gateway: {port: 19000}
}' > "${remote_config}"

# shellcheck source=../shared/lib/merge-openclaw-config.sh
source "${MERGE_HELPER}"
merge_openclaw_config "${remote_config}" "${local_config}"

if [ "$(jq -r '.channels.matrix.accessToken' "${local_config}")" != "local-token" ]; then
    fail "The local Matrix token must survive a remote config merge"
fi
if [ "$(jq -r '.gateway.port' "${local_config}")" != "19000" ]; then
    fail "Manager-managed remote config must still be applied"
fi

cp "${local_config}" "${remote_config}"
touch -t 200001010000 "${local_config}"
touch -t 201001010000 "${marker}"

merge_openclaw_config "${remote_config}" "${local_config}"

if [ "${local_config}" -nt "${marker}" ]; then
    fail "An unchanged merged config must not rewrite the live file"
fi

echo "Worker config sync checks passed."
