import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

import pytest

from qwenpaw_worker.api import QwenPawApiClient, QwenPawApiError


class _ApiHandler(BaseHTTPRequestHandler):
    channel = {"enabled": False, "client_secret": "existing-secret"}
    agents = [
        {"id": "default", "enabled": True},
        {"id": "QwenPaw_QA_Agent_0.2", "enabled": True},
    ]

    def log_message(self, _format, *_args):
        return

    def _reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/version":
            self._reply(200, {"version": "2.0.1"})
            return
        if self.path == "/api/config/channels/agentteams_matrix":
            self._reply(200, type(self).channel)
            return
        if self.path == "/api/agents":
            self._reply(200, {"agents": type(self).agents})
            return
        self._reply(404, {"detail": "missing"})

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/config/channels/agentteams_matrix":
            type(self).channel = payload
            self._reply(200, payload)
            return
        self._reply(404, {"detail": "missing"})

    def do_PATCH(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/agents/QwenPaw_QA_Agent_0.2/toggle":
            for agent in type(self).agents:
                if agent["id"] == "QwenPaw_QA_Agent_0.2":
                    agent["enabled"] = payload["enabled"]
            self._reply(200, {"success": True, "enabled": payload["enabled"]})
            return
        self._reply(404, {"detail": "missing"})


@pytest.fixture()
def api_url():
    _ApiHandler.channel = {"enabled": False, "client_secret": "existing-secret"}
    _ApiHandler.agents = [
        {"id": "default", "enabled": True},
        {"id": "QwenPaw_QA_Agent_0.2", "enabled": True},
    ]
    server = ThreadingHTTPServer(("127.0.0.1", 0), _ApiHandler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        thread.join()


def test_put_channel_preserves_empty_secret_and_reads_back(api_url):
    client = QwenPawApiClient(api_url)

    result = client.put_channel(
        "agentteams_matrix",
        {"enabled": True, "client_secret": ""},
        secret_fields={"client_secret"},
    )

    assert result == {"enabled": True, "client_secret": "existing-secret"}
    assert client.get_channel("agentteams_matrix") == result


def test_require_version_rejects_unexpected_qwenpaw(api_url):
    client = QwenPawApiClient(api_url)

    with pytest.raises(QwenPawApiError, match="expected QwenPaw 2.0.0"):
        client.require_version("2.0.0")


def test_disable_agent_if_present_uses_api_and_reads_back(api_url):
    client = QwenPawApiClient(api_url)

    assert client.disable_agent_if_present("QwenPaw_QA_Agent_0.2") is True
    assert _ApiHandler.agents[1]["enabled"] is False
    assert client.disable_agent_if_present("missing") is False
