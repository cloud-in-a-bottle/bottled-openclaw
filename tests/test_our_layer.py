"""Tests for what this package changes on top of the upstream OpenClaw image.

- Owner auto-login: gateway auth is trusted-proxy on the router's X-OpenHost-Is-Owner header, device pairing is off,
  and the control UI origin is allowed, so the owner's browser connects straight to the control panel.
- Config: our openclaw.json (default model Claude Sonnet) lives in the app data dir, symlinked to ~/.openclaw.
- Secrets: ANTHROPIC_API_KEY is fetched from the secrets service at boot and passed to the gateway.
"""

import json
import subprocess
import time
import uuid
from typing import Any

import requests
from openhost_test_harness import OpenhostStack
from websockets.sync.client import ClientConnection
from websockets.sync.client import connect

FAKE_ANTHROPIC_API_KEY = "sk-ant-harness-not-a-real-key"  # stored in the secrets app by conftest.py
SESSIONS_LIST = {"tool": "sessions_list", "args": {}}


def _logs(stack: OpenhostStack) -> str:
    return f"\n\napp logs:\n{stack.app_logs()[-5000:]}"


def _request(ws: ClientConnection, method: str, params: dict[str, Any]) -> dict[str, Any]:
    request_id = str(uuid.uuid4())
    ws.send(json.dumps({"type": "req", "id": request_id, "method": method, "params": params}))
    while True:
        frame = json.loads(ws.recv(timeout=60))
        if frame.get("type") == "res" and frame.get("id") == request_id:
            return frame


def _connect_as_control_ui(stack: OpenhostStack) -> tuple[ClientConnection, dict[str, Any]]:
    """Open the gateway WebSocket the way the control panel does in the owner's browser: through the router, with the
    owner's cookie and the page's own origin, no device identity and no token."""
    cookie = "; ".join(f"{c.name}={c.value}" for c in stack.owner_session.cookies)
    ws = connect(
        stack.url.replace("http", "ws", 1) + "/",
        origin=stack.url,  # type: ignore[arg-type]
        additional_headers={"Cookie": cookie},
        open_timeout=30,
    )
    hello = _request(
        ws,
        "connect",
        {
            "minProtocol": 4,
            "maxProtocol": 4,
            "client": {"id": "openclaw-control-ui", "version": "control-ui", "platform": "web", "mode": "webchat"},
            "role": "operator",
            "scopes": ["operator.admin", "operator.read", "operator.write", "operator.approvals", "operator.pairing"],
            "caps": ["tool-events"],
        },
    )
    return ws, hello


def test_owner_control_panel_connects_without_login(stack: OpenhostStack) -> None:
    deadline = time.monotonic() + 180
    last: Any = None
    while time.monotonic() < deadline:
        try:
            ws, hello = _connect_as_control_ui(stack)
        except Exception as e:  # the gateway may still be starting
            last = repr(e)
            time.sleep(3)
            continue
        with ws:
            if not hello.get("ok"):
                last = hello
                if (hello.get("error") or {}).get("code") == "UNAVAILABLE":
                    time.sleep(3)
                    continue
                break
            scopes = hello["payload"]["auth"]["scopes"]
            assert "operator.admin" in scopes, f"control panel connected without operator scopes: {scopes}"
            config = _request(ws, "config.get", {})
            assert config.get("ok"), f"config.get failed: {config}"
            model = config["payload"].get("config", {}).get("agents", {}).get("defaults", {}).get("model")
            # Our entrypoint writes this into the app data dir; the gateway only sees it through the ~/.openclaw symlink.
            primary = model.get("primary") if isinstance(model, dict) else model
            assert primary == "anthropic/claude-sonnet-4-6", f"gateway isn't using our config: model={model}"
            return
    raise AssertionError(f"control panel WebSocket connect failed: {last}{_logs(stack)}")


def test_gateway_refuses_requests_without_owner_header(stack: OpenhostStack) -> None:
    deadline = time.monotonic() + 180
    while True:
        try:
            owner = stack.owner_session.post(f"{stack.url}/tools/invoke", json=SESSIONS_LIST, timeout=30)
            if owner.status_code == 200 or time.monotonic() > deadline:
                break
        except requests.ConnectionError:
            if time.monotonic() > deadline:
                raise
        time.sleep(3)
    assert owner.status_code == 200, f"owner tools/invoke: {owner.status_code}: {owner.text[:300]}{_logs(stack)}"
    # stack.app_url bypasses the router, so nothing stamps the owner header.
    anonymous = requests.post(f"{stack.app_url}/tools/invoke", json=SESSIONS_LIST, timeout=30)
    assert anonymous.status_code == 401, (
        f"expected 401 without the owner header: {anonymous.status_code}: {anonymous.text[:300]}"
    )
    not_owner = requests.post(
        f"{stack.app_url}/tools/invoke", json=SESSIONS_LIST, headers={"X-OpenHost-Is-Owner": "false"}, timeout=30
    )
    assert not_owner.status_code == 401, (
        f"expected 401 for a non-owner: {not_owner.status_code}: {not_owner.text[:300]}"
    )


def test_anthropic_key_from_secrets_reaches_gateway(stack: OpenhostStack) -> None:
    # The gateway is the node process running openclaw.mjs; read its environment inside the container.
    script = (
        'for p in /proc/[0-9]*; do tr "\\0" " " < $p/cmdline 2>/dev/null | grep -q "openclaw.mjs gateway" '
        '&& tr "\\0" "\\n" < $p/environ; done'
    )
    result = subprocess.run(
        ["podman", "exec", stack.container_name, "sh", "-c", script], capture_output=True, text=True, timeout=60
    )
    assert f"ANTHROPIC_API_KEY={FAKE_ANTHROPIC_API_KEY}" in result.stdout.splitlines(), (
        f"gateway process doesn't have the key from the secrets service (stderr: {result.stderr[:300]}){_logs(stack)}"
    )
