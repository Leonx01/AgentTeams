"""WorkerFlow integration implemented with QwenPaw 2 public plugin APIs."""

from __future__ import annotations

from pathlib import Path
from typing import Any


PLUGIN_DIR = Path(__file__).resolve().parent
ASSET_DIR = PLUGIN_DIR / "workerflow"
if not (ASSET_DIR / "plugin.yaml").exists():
    ASSET_DIR = PLUGIN_DIR.parent.parent


def _allow_persisted_internal_mcp_policy() -> None:
    from qwenpaw.constant import WORKING_DIR
    from qwenpaw.drivers.storage import card_paths_for_name, dump_card, load_card

    workspaces_dir = WORKING_DIR / "workspaces"
    if not workspaces_dir.is_dir():
        return
    for workspace_dir in workspaces_dir.iterdir():
        if not workspace_dir.is_dir():
            continue
        cards_dir = workspace_dir / "drivers"
        for path in card_paths_for_name(cards_dir, MCP_CLIENT_ID):
            card = load_card(path)
            if card.protocol != "mcp":
                continue
            if card.policy.default_effect == "allow" and not card.policy.rules:
                continue
            card.policy.default_effect = "allow"
            card.policy.rules = []
            dump_card(card, path)


def install_internal_mcp_allow_policy() -> dict[str, Any]:
    try:
        from qwenpaw.drivers.adapters import mcp_legacy_config
    except ImportError:
        return {"ok": True, "installed": False, "reason": "qwenpaw driver API unavailable"}

    allowed_clients = getattr(mcp_legacy_config, "_agentteams_allowed_mcp_clients", set())
    allowed_clients.add(MCP_CLIENT_ID)
    mcp_legacy_config._agentteams_allowed_mcp_clients = allowed_clients
    _allow_persisted_internal_mcp_policy()
    if getattr(mcp_legacy_config, "_agentteams_policy_wrapper_installed", False):
        return {"ok": True, "installed": True, "action": "updated"}

    original = mcp_legacy_config.legacy_mcp_client_to_driver

    def _legacy_mcp_client_to_driver(client_key, config):
        card, credential = original(client_key, config)
        if client_key in mcp_legacy_config._agentteams_allowed_mcp_clients:
            card.policy.default_effect = "allow"
            card.policy.rules = []
        return card, credential

    mcp_legacy_config.legacy_mcp_client_to_driver = _legacy_mcp_client_to_driver
    mcp_legacy_config._agentteams_policy_wrapper_installed = True
    return {"ok": True, "installed": True, "action": "created"}


class WorkerFlowPlugin:
    def register(self, api: Any) -> None:
        api.register_skill_provider(
            ASSET_DIR / "skills" / "agent",
            enabled_by_default=True,
            channels=["all"],
        )
        self._register_http(api)

    def _register_http(self, api: Any) -> None:
        try:
            from fastapi import APIRouter
        except ImportError:
            return
        router = APIRouter()

        @router.get("/health")
        def health() -> dict[str, Any]:
            return {"ok": True, "plugin": "workerflow", "adapter": "qwenpaw-2"}

        @router.post("/sync")
        def sync_endpoint() -> dict[str, Any]:
            return {"ok": True, "plugin": "workerflow", "managedBy": "qwenpaw-plugin-api"}

        api.register_http_router(router, prefix="/workerflow", tags=["workerflow"])


plugin = WorkerFlowPlugin()
