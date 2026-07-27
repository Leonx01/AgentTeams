from pathlib import Path
import tomllib


ROOT = Path(__file__).resolve().parents[1]


def test_agent_client_protocol_stays_compatible_with_qwenpaw_1() -> None:
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    dependencies = project["project"]["dependencies"]

    assert "agent-client-protocol>=0.9.0,<0.11.0" in dependencies
