"""
Bridge: translate openclaw.json (AgentTeams Worker config) into CoPaw's
config.json + providers.json, then set COPAW_WORKING_DIR so CoPaw
picks up the right workspace.
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

# Sentinel returned by controller-field derivations when a value should remain
# untouched during this bridge pass.
_MISSING: Any = object()

import json
import os
import shutil
from importlib import resources
from pathlib import Path
from typing import Any, Callable


def _port_remap(url: str, is_container: bool) -> str:
    """Remap container-internal :8080 to host-exposed gateway port when needed."""
    if not is_container and url and ":8080" in url:
        gateway_port = os.environ.get("AGENTTEAMS_PORT_GATEWAY", "18080")
        return url.replace(":8080", f":{gateway_port}")
    return url


def _is_in_container() -> bool:
    return Path("/.dockerenv").exists() or Path("/run/.containerenv").exists()


def _secret_dir(working_dir: Path) -> Path:
    """Return the secret dir path that copaw uses alongside working_dir."""
    return Path(str(working_dir) + ".secret")


def _patch_copaw_paths(working_dir: Path) -> None:
    """Patch copaw's module-level path constants to point at working_dir.

    copaw.constant captures WORKING_DIR / SECRET_DIR at import time from
    env vars, so setting COPAW_WORKING_DIR after import has no effect.
    We must update the live module objects directly.
    """
    secret_dir = _secret_dir(working_dir)
    secret_dir.mkdir(parents=True, exist_ok=True)

    try:
        import copaw.constant as _const
        _const.WORKING_DIR = working_dir
        _const.SECRET_DIR = secret_dir
        _const.ACTIVE_SKILLS_DIR = working_dir / "active_skills"
        _const.CUSTOMIZED_SKILLS_DIR = working_dir / "customized_skills"
        _const.MEMORY_DIR = working_dir / "memory"
        _const.CUSTOM_CHANNELS_DIR = working_dir / "custom_channels"
        _const.MODELS_DIR = working_dir / "models"
    except ImportError:
        pass

    try:
        import copaw.providers.store as _store
        _store._PROVIDERS_JSON = secret_dir / "providers.json"
        _store._LEGACY_PROVIDERS_JSON_CANDIDATES = (
            Path(__file__).resolve().parent / "providers.json",
            working_dir / "providers.json",
        )
    except ImportError:
        pass

    try:
        import copaw.envs.store as _envs
        _envs._BOOTSTRAP_WORKING_DIR = working_dir
        _envs._BOOTSTRAP_SECRET_DIR = secret_dir
        _envs._ENVS_JSON = secret_dir / "envs.json"
        _envs._LEGACY_ENVS_JSON_CANDIDATES = (working_dir / "envs.json",)
    except (ImportError, AttributeError):
        pass

    # copaw.app.channels.registry binds CUSTOM_CHANNELS_DIR via
    # `from ...constant import CUSTOM_CHANNELS_DIR` at import time, so it keeps
    # a STALE copy of the default path even after we patch copaw.constant above.
    # _discover_custom_channels() / register_custom_channel_routes() read this
    # module global at CALL time, so rebinding it here (before ChannelManager
    # starts) makes them see our working_dir/custom_channels regardless of
    # import order. Without this the patched matrix_channel.py is never
    # discovered and copaw falls back to its builtin (broken) Matrix channel.
    try:
        import copaw.app.channels.registry as _channels_registry
        _channels_registry.CUSTOM_CHANNELS_DIR = working_dir / "custom_channels"
        logger.info(
            "bridge: patched channels registry CUSTOM_CHANNELS_DIR -> %s",
            _channels_registry.CUSTOM_CHANNELS_DIR,
        )
    except ImportError:
        pass


def bridge_controller_to_copaw(
    openclaw_cfg: dict[str, Any],
    working_dir: Path,
    *,
    profile: str = "worker",
    agent: str = "default",
) -> None:
    """
    Read openclaw_cfg (parsed openclaw.json) and write:
      - <working_dir>/config.json          (global config)
      - <working_dir>/workspaces/default/agent.json (per-agent config)
      - <working_dir>/providers.json       (LLM credentials, for reference)
      - <working_dir>.secret/providers.json (where copaw actually reads from)

    Also sets COPAW_WORKING_DIR env var and patches copaw's module-level
    path constants so the running process uses the correct directory.

    """
    if profile not in ("worker", "manager"):
        raise ValueError(
            f"unknown bridge profile: {profile!r} (use 'worker' or 'manager')"
        )

    working_dir.mkdir(parents=True, exist_ok=True)
    in_container = _is_in_container()

    _write_config_json(working_dir)
    _write_agent_json(
        openclaw_cfg,
        working_dir,
        in_container,
        profile=profile,
        agent=agent,
    )
    _write_providers_json(openclaw_cfg, working_dir, in_container)

    os.environ["COPAW_WORKING_DIR"] = str(working_dir)

    # Patch module-level constants (import-time values won't reflect env change)
    _patch_copaw_paths(working_dir)

    # Copy providers.json into secret_dir — that's where copaw actually reads it
    secret_dir = _secret_dir(working_dir)
    providers_src = working_dir / "providers.json"
    if providers_src.exists():
        shutil.copy2(providers_src, secret_dir / "providers.json")


def bridge_standard_to_runtime(
    standard_dir: Path,
    runtime_dir: Path,
    controller_config: dict[str, Any],
    *,
    skill_names: list[str] | None = None,
    profile: str = "worker",
) -> None:
    """Materialize standard-space files into CoPaw's default workspace."""
    sync_outer_prompt_files_to_inner(standard_dir, runtime_dir)
    bridge_controller_to_copaw(
        controller_config,
        runtime_dir,
        profile=profile,
    )
    sync_mcporter_config_to_runtime(standard_dir, runtime_dir)
    if skill_names is not None:
        sync_skills_to_runtime(standard_dir, runtime_dir, skill_names)


def refresh_standard_to_runtime(
    standard_dir: Path,
    runtime_dir: Path,
    controller_config: dict[str, Any],
    *,
    get_soul: Callable[[], str | None],
    get_agents_md: Callable[[], str | None],
    skill_names: list[str] | None = None,
    profile: str = "worker",
) -> None:
    """Refresh CoPaw runtime files, including legacy prompt fallbacks."""
    sync_rebridged_prompt_files_to_inner(
        standard_dir,
        runtime_dir,
        get_soul=get_soul,
        get_agents_md=get_agents_md,
    )
    bridge_controller_to_copaw(
        controller_config,
        runtime_dir,
        profile=profile,
    )
    sync_mcporter_config_to_runtime(standard_dir, runtime_dir)
    if skill_names is not None:
        sync_skills_to_runtime(standard_dir, runtime_dir, skill_names)


def sync_mcporter_config_to_runtime(
    standard_dir: Path,
    runtime_dir: Path,
) -> Path | None:
    """Copy mcporter config into CoPaw's default workspace."""
    src_candidates = (
        standard_dir / "config" / "mcporter.json",
        standard_dir / "mcporter-servers.json",
    )
    src = next((candidate for candidate in src_candidates if candidate.exists()), None)
    if src is None:
        return None

    dst = runtime_dir / "workspaces" / "default" / "config" / "mcporter.json"
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return dst


def sync_skills_to_runtime(
    standard_dir: Path,
    runtime_dir: Path,
    skill_names: list[str],
) -> list[str]:
    """Expose controller-managed skills in CoPaw's default workspace."""
    standard_skills_dir = standard_dir / "skills"
    standard_skills_dir.mkdir(parents=True, exist_ok=True)

    for script in standard_skills_dir.rglob("*.sh"):
        script.chmod(script.stat().st_mode | 0o111)

    desired = set(skill_names)
    for child in list(standard_skills_dir.iterdir()):
        if child.is_dir() and child.name not in desired:
            shutil.rmtree(child)

    workspace_skills_dir = runtime_dir / "workspaces" / "default" / "skills"
    workspace_skills_dir.parent.mkdir(parents=True, exist_ok=True)
    _dedup_customized_skills(runtime_dir)

    expected_target = standard_skills_dir.resolve()
    if workspace_skills_dir.is_symlink():
        if workspace_skills_dir.resolve() != expected_target:
            workspace_skills_dir.unlink()
    elif workspace_skills_dir.exists():
        if workspace_skills_dir.is_dir():
            shutil.rmtree(workspace_skills_dir)
        else:
            workspace_skills_dir.unlink()

    if not workspace_skills_dir.exists():
        target = os.path.relpath(standard_skills_dir, workspace_skills_dir.parent)
        workspace_skills_dir.symlink_to(target, target_is_directory=True)

    installed = [
        skill_name
        for skill_name in skill_names
        if (standard_skills_dir / skill_name).exists()
    ]
    _enable_workspace_skills(runtime_dir, installed)
    return installed


def _enable_workspace_skills(runtime_dir: Path, skill_names: list[str]) -> None:
    if not skill_names:
        return

    workspace_dir = runtime_dir / "workspaces" / "default"
    manifest_path = workspace_dir / "skill.json"
    manifest: dict[str, Any] = {
        "schema_version": "workspace-skill-manifest.v1",
        "version": 1,
        "skills": {},
    }
    if manifest_path.exists():
        try:
            loaded = json.loads(manifest_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                manifest.update(loaded)
        except json.JSONDecodeError:
            logger.warning("Invalid CoPaw skill manifest, recreating: %s", manifest_path)

    if not isinstance(manifest.get("skills"), dict):
        manifest["skills"] = {}
    skills = manifest["skills"]
    changed = False
    for skill_name in sorted(set(skill_names)):
        if not (
            workspace_dir / "skills" / skill_name / "SKILL.md"
        ).exists():
            continue
        existing = skills.get(skill_name)
        if isinstance(existing, dict):
            if existing.get("enabled") is not True:
                existing["enabled"] = True
                changed = True
            if not existing.get("channels"):
                existing["channels"] = ["all"]
                changed = True
            continue
        skills[skill_name] = {
            "enabled": True,
            "channels": ["all"],
            "source": "customized",
        }
        changed = True

    if changed or not manifest_path.exists():
        workspace_dir.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )


def _dedup_customized_skills(runtime_dir: Path) -> None:
    customized_dir = runtime_dir / "customized_skills"
    if not customized_dir.is_dir():
        return

    try:
        import copaw.agents.skills as skills_package

        builtin_root = Path(skills_package.__file__).resolve().parent
    except (ImportError, AttributeError):
        return

    builtin_names = {
        child.name
        for child in builtin_root.iterdir()
        if child.is_dir() and not child.name.startswith("_")
    }
    for child in list(customized_dir.iterdir()):
        if child.is_dir() and child.name in builtin_names:
            shutil.rmtree(child)


def sync_outer_prompt_files_to_inner(
    standard_dir: Path,
    runtime_dir: Path,
) -> None:
    """Copy standard prompt files into CoPaw's default workspace."""
    workspace_dir = runtime_dir / "workspaces" / "default"
    workspace_dir.mkdir(parents=True, exist_ok=True)

    for name in ("SOUL.md", "AGENTS.md"):
        src = standard_dir / name
        if src.exists():
            (workspace_dir / name).write_text(src.read_text())

    heartbeat_dst = workspace_dir / "HEARTBEAT.md"
    if not heartbeat_dst.exists():
        heartbeat_src = standard_dir / "HEARTBEAT.md"
        if heartbeat_src.exists():
            heartbeat_dst.write_text(heartbeat_src.read_text())


def sync_rebridged_prompt_files_to_inner(
    standard_dir: Path,
    runtime_dir: Path,
    *,
    get_soul: Callable[[], str | None],
    get_agents_md: Callable[[], str | None],
) -> None:
    """Refresh runtime prompts, falling back to legacy MinIO readers."""
    soul_path = standard_dir / "SOUL.md"
    agents_path = standard_dir / "AGENTS.md"
    soul = soul_path.read_text() if soul_path.exists() else get_soul()
    agents = agents_path.read_text() if agents_path.exists() else get_agents_md()

    workspace_dir = runtime_dir / "workspaces" / "default"
    if soul:
        workspace_dir.mkdir(parents=True, exist_ok=True)
        (workspace_dir / "SOUL.md").write_text(soul)
    if agents:
        workspace_dir.mkdir(parents=True, exist_ok=True)
        (workspace_dir / "AGENTS.md").write_text(agents)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _resolve_active_model(cfg: dict[str, Any]) -> dict[str, Any] | None:
    """Return the config dict of the active model from openclaw.json, or None.

    Prefers agents.defaults.model.primary ("provider_id/model_id");
    falls back to the first model of the first provider.
    """
    providers_raw = cfg.get("models", {}).get("providers", {})
    if not providers_raw:
        return None

    primary = (
        cfg.get("agents", {})
        .get("defaults", {})
        .get("model", {})
        .get("primary", "")
    )

    if primary and "/" in primary:
        pid, mid = primary.split("/", 1)
        provider = providers_raw.get(pid, {})
        for m in provider.get("models", []):
            if m.get("id") == mid:
                return m

    # Fallback: first provider, first model
    for provider_cfg in providers_raw.values():
        models = provider_cfg.get("models", [])
        if models:
            return models[0]

    return None


def _resolve_context_window(cfg: dict[str, Any]) -> int | None:
    """Return the contextWindow of the active (or first) model, or None."""
    m = _resolve_active_model(cfg)
    if m and "contextWindow" in m:
        return int(m["contextWindow"])
    return None


def _resolve_vision_enabled(cfg: dict[str, Any]) -> bool:
    """Return True if the active model declares image input support.

    The openclaw.json model's ``input`` field is a list of supported modalities
    (e.g. ["text", "image"]).  If the field is absent we assume text-only to
    avoid sending images to a model that cannot handle them.
    """
    m = _resolve_active_model(cfg)
    if m is None:
        return False
    input_types = m.get("input", [])
    return "image" in input_types


def _resolve_matrix_user_id(
    matrix_raw: dict[str, Any],
    *,
    profile: str = "worker",
) -> str:
    """Resolve the Matrix MXID that CoPaw tools use for proactive sends."""
    explicit = matrix_raw.get("userId") or matrix_raw.get("user_id")
    if explicit:
        return str(explicit)

    env_user_id = (
        os.environ.get("AGENTTEAMS_MATRIX_USER_ID")
        or os.environ.get("COPAW_MATRIX_USER_ID")
    )
    if env_user_id:
        return env_user_id

    matrix_domain = os.environ.get("AGENTTEAMS_MATRIX_DOMAIN")
    localpart = (
        os.environ.get("AGENTTEAMS_WORKER_NAME")
        or ("manager" if profile == "manager" else "")
    )
    if matrix_domain and localpart:
        return f"@{localpart}:{matrix_domain}"

    return ""


def _template_text(name: str) -> str:
    """Read a bundled CoPaw configuration template."""
    return (resources.files("copaw_worker") / "templates" / name).read_text(
        encoding="utf-8"
    )


def _install_from_template(dst: Path, template_name: str) -> bool:
    """Install a template only when the destination does not exist."""
    if dst.exists():
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(_template_text(template_name), encoding="utf-8")
    return True


def _matrix_raw(cfg: dict[str, Any]) -> dict[str, Any]:
    return cfg.get("channels", {}).get("matrix", {})


def _matrix_bool(
    cfg: dict[str, Any],
    camel_key: str,
    snake_key: str,
    default: bool,
) -> bool:
    matrix = _matrix_raw(cfg)
    if camel_key in matrix:
        return bool(matrix[camel_key])
    if snake_key in matrix:
        return bool(matrix[snake_key])
    return default


def _resolve_embedding_config(
    cfg: dict[str, Any],
    in_container: bool,
) -> dict[str, Any] | None:
    memory_search = (
        cfg.get("agents", {})
        .get("defaults", {})
        .get("memorySearch", {})
    )
    if not memory_search:
        return None

    remote = memory_search.get("remote", {})
    base_url = _port_remap(remote.get("baseUrl", ""), in_container)
    model = memory_search.get("model", "")
    if not base_url or not model:
        return None

    dimensions = (
        memory_search.get("outputDimensionality")
        or int(os.environ.get("AGENTTEAMS_EMBEDDING_DIMENSIONS", "0"))
        or 1024
    )
    return {
        "backend": "openai",
        "api_key": remote.get("apiKey", ""),
        "base_url": base_url,
        "model_name": model,
        "dimensions": dimensions,
        "enable_cache": True,
        "use_dimensions": False,
    }


def _resolve_history_limit(cfg: dict[str, Any]) -> int | None:
    history_limit = _matrix_raw(cfg).get("historyLimit")
    if history_limit is None:
        history_limit = (
            cfg.get("messages", {}).get("groupChat", {}).get("historyLimit")
        )
    return int(history_limit) if history_limit is not None else None


def _derive_matrix_user_id(
    cfg: dict[str, Any],
    _in_container: bool = False,
) -> Any:
    user_id = _resolve_matrix_user_id(_matrix_raw(cfg))
    return user_id or _MISSING


def _derive_heartbeat(
    cfg: dict[str, Any],
    _in_container: bool = False,
) -> Any:
    heartbeat = cfg.get("agents", {}).get("defaults", {}).get("heartbeat")
    if not isinstance(heartbeat, dict) or not heartbeat:
        return _MISSING

    result: dict[str, Any] = {"enabled": True}
    if "every" in heartbeat:
        result["every"] = heartbeat["every"]
    if "target" in heartbeat:
        result["target"] = heartbeat["target"]
    if "activeHours" in heartbeat:
        result["active_hours"] = heartbeat["activeHours"]
    return result


def _get_path(container: dict[str, Any], path: tuple[str, ...]) -> Any:
    node: Any = container
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return _MISSING
        node = node[key]
    return node


def _set_path(
    container: dict[str, Any],
    path: tuple[str, ...],
    value: Any,
) -> None:
    node = container
    for key in path[:-1]:
        child = node.get(key)
        if not isinstance(child, dict):
            child = {}
            node[key] = child
        node = child
    node[path[-1]] = value


def _deep_merge_local_wins(remote: Any, local: Any) -> Any:
    if isinstance(remote, dict) and isinstance(local, dict):
        result: dict[str, Any] = {}
        for key in remote.keys() | local.keys():
            if key in remote and key in local:
                result[key] = _deep_merge_local_wins(remote[key], local[key])
            elif key in remote:
                result[key] = remote[key]
            else:
                result[key] = local[key]
        return result
    return local


def _union_list(remote: list[Any], local: list[Any]) -> list[Any]:
    seen: set[str] = set()
    result: list[Any] = []
    for item in local + remote:
        key = (
            json.dumps(item, sort_keys=True)
            if isinstance(item, (dict, list))
            else repr(item)
        )
        if key not in seen:
            seen.add(key)
            result.append(item)
    return result


def _apply_policy(
    existing: dict[str, Any],
    path: tuple[str, ...],
    policy: str,
    remote_value: Any,
) -> None:
    if remote_value is _MISSING:
        return
    if policy == "remote-wins":
        _set_path(existing, path, remote_value)
        return
    if policy == "union":
        local_value = _get_path(existing, path)
        local_list = local_value if isinstance(local_value, list) else []
        remote_list = remote_value if isinstance(remote_value, list) else []
        _set_path(existing, path, _union_list(remote_list, local_list))
        return
    if policy == "deep-merge":
        local_value = _get_path(existing, path)
        value = (
            remote_value
            if local_value is _MISSING
            else _deep_merge_local_wins(remote_value, local_value)
        )
        _set_path(existing, path, value)
        return
    if policy == "seed":
        if _get_path(existing, path) is _MISSING:
            _set_path(existing, path, remote_value)
        return
    raise ValueError(f"unknown merge policy: {policy}")


_PolicyDeriver = Callable[[dict[str, Any], bool], Any]


_CONTROLLER_FIELDS: list[
    tuple[tuple[str, ...], str, _PolicyDeriver]
] = [
    (
        ("channels", "matrix", "enabled"),
        "remote-wins",
        lambda c, _: _matrix_raw(c).get("enabled", True),
    ),
    (
        ("channels", "matrix", "homeserver"),
        "remote-wins",
        lambda c, ic: _port_remap(_matrix_raw(c).get("homeserver", ""), ic),
    ),
    (
        ("channels", "matrix", "access_token"),
        "remote-wins",
        lambda c, _: _matrix_raw(c).get("accessToken", ""),
    ),
    (
        ("channels", "matrix", "user_id"),
        "remote-wins",
        _derive_matrix_user_id,
    ),
    (
        ("channels", "matrix", "encryption"),
        "remote-wins",
        lambda c, _: _matrix_raw(c).get("encryption", False),
    ),
    (
        ("channels", "matrix", "dm_policy"),
        "remote-wins",
        lambda c, _: _matrix_raw(c).get("dm", {}).get(
            "policy", "allowlist"
        ),
    ),
    (
        ("channels", "matrix", "group_policy"),
        "remote-wins",
        lambda c, _: _matrix_raw(c).get("groupPolicy", "allowlist"),
    ),
    (
        ("channels", "matrix", "filter_tool_messages"),
        "remote-wins",
        lambda c, _: _matrix_bool(
            c, "filterToolMessages", "filter_tool_messages", False
        ),
    ),
    (
        ("channels", "matrix", "filter_thinking"),
        "remote-wins",
        lambda c, _: _matrix_bool(
            c, "filterThinking", "filter_thinking", True
        ),
    ),
    (
        ("channels", "matrix", "vision_enabled"),
        "remote-wins",
        lambda c, _: _resolve_vision_enabled(c),
    ),
    (
        ("channels", "matrix", "history_limit"),
        "remote-wins",
        lambda c, _: (
            _resolve_history_limit(c)
            if _resolve_history_limit(c) is not None
            else _MISSING
        ),
    ),
    (
        ("channels", "matrix", "allow_from"),
        "union",
        lambda c, _: _matrix_raw(c).get("dm", {}).get("allowFrom", []) or [],
    ),
    (
        ("channels", "matrix", "group_allow_from"),
        "union",
        lambda c, _: _matrix_raw(c).get("groupAllowFrom", []) or [],
    ),
    (
        ("channels", "matrix", "groups"),
        "deep-merge",
        lambda c, _: _matrix_raw(c).get("groups", {}) or {},
    ),
    (
        ("running", "max_input_length"),
        "remote-wins",
        lambda c, _: (
            _resolve_context_window(c)
            if _resolve_context_window(c) is not None
            else _MISSING
        ),
    ),
    (
        ("running", "embedding_config"),
        "remote-wins",
        lambda c, ic: _resolve_embedding_config(c, ic) or _MISSING,
    ),
    (("heartbeat",), "seed", _derive_heartbeat),
]


# ---------------------------------------------------------------------------
# config.json
# ---------------------------------------------------------------------------

def _write_config_json(
    working_dir: Path,
) -> None:
    _install_from_template(working_dir / "config.json", "config.json")




# ---------------------------------------------------------------------------
# agent.json — per-agent config (CoPaw 1.0.2+ reads this, not config.json)
# ---------------------------------------------------------------------------

def _write_agent_json(
    cfg: dict[str, Any],
    working_dir: Path,
    in_container: bool,
    *,
    profile: str = "worker",
    agent: str = "default",
) -> None:
    """Create agent.json from template, then overlay controller-owned fields."""
    agent_path = working_dir / "workspaces" / agent / "agent.json"
    _install_from_template(agent_path, f"agent.{profile}.json")

    try:
        with open(agent_path) as f:
            agent_cfg = json.load(f)
        if not isinstance(agent_cfg, dict):
            raise ValueError("agent.json root is not an object")
    except Exception as exc:
        logger.warning("Re-seeding unreadable agent config %s: %s", agent_path, exc)
        agent_path.unlink(missing_ok=True)
        _install_from_template(agent_path, f"agent.{profile}.json")
        with open(agent_path) as f:
            agent_cfg = json.load(f)

    for path, policy, deriver in _CONTROLLER_FIELDS:
        _apply_policy(agent_cfg, path, policy, deriver(cfg, in_container))

    agent_cfg.setdefault("workspace_dir", str(agent_path.parent))

    with open(agent_path, "w") as f:
        json.dump(agent_cfg, f, indent=2, ensure_ascii=False)

# ---------------------------------------------------------------------------
# providers.json
# ---------------------------------------------------------------------------

def _write_providers_json(
    cfg: dict[str, Any],
    working_dir: Path,
    in_container: bool,
) -> None:
    providers_raw = cfg.get("models", {}).get("providers", {})

    custom_providers: dict[str, Any] = {}
    active_provider_id = ""
    active_model = ""

    for provider_id, provider_cfg in providers_raw.items():
        base_url = _port_remap(
            provider_cfg.get("baseUrl", ""), in_container
        )
        api_key = provider_cfg.get("apiKey", "")

        models_raw = provider_cfg.get("models", [])
        models = [
            {"id": m["id"], "name": m.get("name", m["id"])}
            for m in models_raw
            if m.get("id")
        ]

        custom_providers[provider_id] = {
            "id": provider_id,
            "name": provider_id,
            "default_base_url": base_url,
            "api_key_prefix": "",
            "models": models,
            "base_url": base_url,
            "api_key": api_key,
            "chat_model": "OpenAIChatModel",
        }

        # Use first provider + first model as active LLM
        if not active_provider_id and models:
            active_provider_id = provider_id
            active_model = models[0]["id"]

    # Resolve active model from agents.defaults.model.primary
    # Format: "provider_id/model_id"
    primary = (
        cfg.get("agents", {})
        .get("defaults", {})
        .get("model", {})
        .get("primary", "")
    )
    if primary and "/" in primary:
        pid, mid = primary.split("/", 1)
        if pid in custom_providers:
            active_provider_id = pid
            active_model = mid

    providers_data: dict[str, Any] = {
        "providers": {},
        "custom_providers": custom_providers,
        "active_llm": {
            "provider_id": active_provider_id,
            "model": active_model,
        },
    }

    providers_path = working_dir / "providers.json"
    with open(providers_path, "w") as f:
        json.dump(providers_data, f, indent=2, ensure_ascii=False)



# ---------------------------------------------------------------------------
# Runtime-to-standard sync (worker uses this to push edits back to sync root)
# ---------------------------------------------------------------------------

def bridge_runtime_to_standard(standard_dir):
    """Materialize runtime-space edits back into the standard sync root."""
    sync_inner_prompt_files_to_outer(standard_dir)


def sync_inner_prompt_files_to_outer(local_dir):
    """Copy agent-edited prompt files from CoPaw workspace back to sync root."""
    inner_outer_files = ("AGENTS.md", "SOUL.md", "HEARTBEAT.md")
    copaw_ws_dir = Path(local_dir) / ".copaw" / "workspaces" / "default"
    for name in inner_outer_files:
        inner = copaw_ws_dir / name
        outer = Path(local_dir) / name
        if not inner.exists():
            continue
        try:
            inner_mtime = inner.stat().st_mtime
        except OSError:
            continue
        outer_mtime = outer.stat().st_mtime if outer.exists() else 0
        if inner_mtime > outer_mtime:
            inner_content = inner.read_text(errors="replace")
            outer_content = outer.read_text(errors="replace") if outer.exists() else ""
            if inner_content != outer_content:
                outer.write_text(inner_content)
                logger.debug(
                    "Inner->Outer sync: .copaw/workspaces/default/%s -> %s",
                    name,
                    name,
                )

# ---------------------------------------------------------------------------
# CLI entry point — used by manager/scripts/init/start-copaw-manager.sh
# ---------------------------------------------------------------------------

def _main_cli(argv=None):
    import argparse

    parser = argparse.ArgumentParser(
        prog="python -m copaw_worker.bridge",
        description="Bridge Controller config into CoPaw runtime files.",
    )
    parser.add_argument("--openclaw-json", required=True,
                        help="Path to openclaw.json")
    parser.add_argument("--working-dir", required=True,
                        help="CoPaw working dir (e.g. ~/.copaw)")
    parser.add_argument("--profile", default="manager",
                        choices=["worker", "manager"],
                        help="Template profile (default: manager)")
    args = parser.parse_args(argv)

    from pathlib import Path as _Path
    import json as _json

    openclaw_path = _Path(args.openclaw_json)
    if not openclaw_path.exists():
        print(f"ERROR: {openclaw_path} not found", flush=True)
        return 1

    working_dir = _Path(args.working_dir)
    working_dir.mkdir(parents=True, exist_ok=True)

    with open(openclaw_path) as f:
        controller_config = _json.load(f)

    bridge_controller_to_copaw(
        controller_config,
        working_dir,
        profile=args.profile,
    )
    return 0


if __name__ == "__main__":
    import sys as _sys
    _sys.exit(_main_cli())
