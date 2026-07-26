#!/usr/bin/env bash
# Verify QwenPaw 2.0.1's native migration of a legacy single-agent workdir.

set -euo pipefail

IMAGE="${AGENTTEAMS_QWENPAW_IMAGE:?set AGENTTEAMS_QWENPAW_IMAGE to the release-candidate image}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qwenpaw-1-migration.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

command -v docker >/dev/null 2>&1
docker image inspect "${IMAGE}" >/dev/null

mkdir -p "${TMP_DIR}/workdir/sessions" "${TMP_DIR}/workdir/memory"
cat >"${TMP_DIR}/workdir/config.json" <<'JSON'
{
  "agents": {
    "active_agent": "",
    "profiles": {},
    "running": {"max_iters": 37},
    "system_prompt_files": ["AGENTS.md", "SOUL.md"]
  },
  "channels": {},
  "mcp": {"clients": {}}
}
JSON
printf '%s\n' '# Legacy AgentTeams worker' >"${TMP_DIR}/workdir/AGENTS.md"
printf '%s\n' '# Legacy worker soul' >"${TMP_DIR}/workdir/SOUL.md"
printf '%s\n' '{"legacy": true}' >"${TMP_DIR}/workdir/chats.json"
printf '%s\n' 'legacy-session' >"${TMP_DIR}/workdir/sessions/session.txt"
printf '%s\n' 'legacy-memory' >"${TMP_DIR}/workdir/memory/memory.txt"

docker run --rm -i \
  --user "$(id -u):$(id -g)" \
  --entrypoint /opt/venv/qwenpaw/bin/python \
  -e QWENPAW_WORKING_DIR=/migration \
  -v "${TMP_DIR}/workdir:/migration" \
  "${IMAGE}" - <<'PY'
import json
from pathlib import Path

from qwenpaw.app.migration import migrate_legacy_workspace_to_default_agent

root = Path("/migration")
assert migrate_legacy_workspace_to_default_agent() is True

workspace = root / "workspaces" / "default"
agent = json.loads((workspace / "agent.json").read_text(encoding="utf-8"))
config = json.loads((root / "config.json").read_text(encoding="utf-8"))

assert agent["id"] == "default"
assert agent["description"] == "Default QwenPaw agent (migrated from legacy config)"
assert agent["running"]["max_iters"] == 37
assert agent["system_prompt_files"] == ["AGENTS.md", "SOUL.md"]
assert (workspace / "AGENTS.md").read_text(encoding="utf-8").strip() == "# Legacy AgentTeams worker"
assert (workspace / "SOUL.md").read_text(encoding="utf-8").strip() == "# Legacy worker soul"
assert json.loads((workspace / "chats.json").read_text(encoding="utf-8")) == {"legacy": True}
assert (workspace / "sessions" / "session.txt").read_text(encoding="utf-8").strip() == "legacy-session"
assert (workspace / "memory" / "memory.txt").read_text(encoding="utf-8").strip() == "legacy-memory"

assert config["agents"]["active_agent"] == "default"
assert config["agents"]["profiles"]["default"]["workspace_dir"] == str(workspace)
assert config["agents"]["running"]["max_iters"] == 37
assert config["agents"]["system_prompt_files"] == ["AGENTS.md", "SOUL.md"]
assert "channels" in config and "mcp" in config

assert migrate_legacy_workspace_to_default_agent() is False
print("PASS: QwenPaw 1.x workdir migrated natively and idempotently")
PY
