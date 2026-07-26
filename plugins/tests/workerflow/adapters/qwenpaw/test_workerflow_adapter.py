"""QwenPaw 2 public plugin API contract tests for WorkerFlow."""

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
PLUGIN_PATH = ROOT / "plugins" / "workerflow" / "adapters" / "qwenpaw" / "plugin.py"


def test_register_uses_skill_provider_api():
    spec = importlib.util.spec_from_file_location("workerflow_qwenpaw_plugin_test", PLUGIN_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    calls = []

    class Api:
        def register_skill_provider(self, *args, **kwargs):
            calls.append((args, kwargs))

        def register_http_router(self, *args, **kwargs):
            calls.append((args, kwargs))

    module.plugin.register(Api())
    assert calls[0][0][0].name == "agent"
    assert calls[0][1] == {"enabled_by_default": True, "channels": ["all"]}
