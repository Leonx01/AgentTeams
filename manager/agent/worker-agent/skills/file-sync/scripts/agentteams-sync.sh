#!/bin/sh
# agentteams-sync.sh - Pull latest config from centralized storage
# Called by the Worker agent when coordinator notifies of config updates.
# Uses /root/agentteams-fs/ layout — same absolute path as the Manager's MinIO mirror.

# Bootstrap env: provides AGENTTEAMS_STORAGE_PREFIX and ensure_mc_credentials
if [ -f /opt/agentteams/scripts/lib/agentteams-env.sh ]; then
    . /opt/agentteams/scripts/lib/agentteams-env.sh
else
    . /opt/agentteams/scripts/lib/oss-credentials.sh 2>/dev/null || true
    ensure_mc_credentials 2>/dev/null || true
    AGENTTEAMS_FS_BUCKET="${AGENTTEAMS_FS_BUCKET:-agentteams-storage}"
    AGENTTEAMS_STORAGE_PREFIX="${AGENTTEAMS_STORAGE_PREFIX:-agentteams/${AGENTTEAMS_FS_BUCKET}}"
fi

# Merge helper for openclaw.json (local-first: MinIO overlays models/gateway/channels + plugins rules)
. /opt/agentteams/scripts/lib/merge-openclaw-config.sh

WORKER_NAME="${AGENTTEAMS_WORKER_NAME:?AGENTTEAMS_WORKER_NAME is required}"
AGENTTEAMS_ROOT="/root/agentteams-fs"
WORKSPACE="${AGENTTEAMS_ROOT}/agents/${WORKER_NAME}"

ensure_mc_credentials 2>/dev/null || true

LOCAL_OPENCLAW="${WORKSPACE}/openclaw.json"
REMOTE_OPENCLAW="/tmp/openclaw-remote-sync.json"

mc mirror "${AGENTTEAMS_STORAGE_PREFIX}/agents/${WORKER_NAME}/" "${WORKSPACE}/" --overwrite \
    --exclude "openclaw.json" \
    --exclude ".openclaw/matrix/**" --exclude ".openclaw/canvas/**" 2>&1
mc mirror "${AGENTTEAMS_STORAGE_PREFIX}/shared/" "${AGENTTEAMS_ROOT}/shared/" --overwrite 2>/dev/null || true

# Update pull marker so the local→remote sync loop doesn't push back freshly-pulled files
touch "${WORKSPACE}/.last-pull"

# Keep the remote config away from the live path so OpenClaw never observes the
# stale remote access token before the local-first merge restores its token.
rm -f "${REMOTE_OPENCLAW}"
if mc cp "${AGENTTEAMS_STORAGE_PREFIX}/agents/${WORKER_NAME}/openclaw.json" "${REMOTE_OPENCLAW}" 2>/dev/null; then
    merge_openclaw_config "${REMOTE_OPENCLAW}" "${LOCAL_OPENCLAW}"
fi
rm -f "${REMOTE_OPENCLAW}"

# Restore +x on scripts (MinIO does not preserve Unix permission bits)
find "${WORKSPACE}/skills" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

echo "Config sync completed at $(date)"
