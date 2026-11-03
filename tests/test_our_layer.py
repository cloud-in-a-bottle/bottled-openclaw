"""Tests for what this package changes on top of the upstream OpenClaw image.

- Owner auto-login: owner-proxy.mjs is the gateway's only trusted proxy and rebuilds forwarded client headers; gateway
  auth is trusted-proxy on the router's X-OpenHost-Is-Owner header, with full scopes for the owner, and the control UI
  origin is allowed, so the owner's browser connects straight to the control panel.
- The gateway's own local clients reach it over loopback with a local password.
- Config: our openclaw.json (default model Claude Sonnet) lives in the app data dir (OPENCLAW_STATE_DIR).
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
            # Our entrypoint writes this into the app data dir, which the gateway reads as its state dir.
            primary = model.get("primary") if isinstance(model, dict) else model
            assert primary == "anthropic/claude-sonnet-4-6", f"gateway isn't using our config: model={model}"
            return
    raise AssertionError(f"control panel WebSocket connect failed: {last}{_logs(stack)}")


def _wait_for_owner_tools_invoke(stack: OpenhostStack) -> None:
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


def test_gateway_refuses_requests_without_owner_header(stack: OpenhostStack) -> None:
    _wait_for_owner_tools_invoke(stack)
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


def test_forged_forwarded_headers_are_replaced(stack: OpenhostStack) -> None:
    """A request straight to the container port (no router, so no owner header) claiming to come from loopback.

    owner-proxy.mjs replaces the forwarded headers with its own view of the peer, so the gateway attributes the request
    to a non-loopback client and refuses it for lacking the owner identity (401). A 403 (proxy_attribution_required)
    means the gateway no longer accepts our proxy's attribution: it trusts more than loopback, or the client's headers
    got through.
    """
    forged = {"X-Forwarded-For": "127.0.0.1", "X-Real-IP": "127.0.0.1", "Forwarded": "for=127.0.0.1"}
    deadline = time.monotonic() + 180
    while True:  # wait out gateway startup (connection refused, 502 from our proxy, 503 from the gateway)
        try:
            response = requests.post(f"{stack.app_url}/tools/invoke", json=SESSIONS_LIST, headers=forged, timeout=30)
            if response.status_code not in (502, 503) or time.monotonic() > deadline:
                break
        except requests.ConnectionError:
            if time.monotonic() > deadline:
                raise
        time.sleep(3)
    assert response.status_code == 401, (
        f"expected 401 for a direct request with forged forwarded headers: {response.status_code}: "
        f"{response.text[:300]}{_logs(stack)}"
    )


def test_gateway_local_clients_connect_over_loopback(stack: OpenhostStack) -> None:
    """The gateway's own clients (here the CLI, as the agent's tools use when they can't dispatch in-process) carry no
    owner header; they connect over loopback with the local password our entrypoint configures."""
    _wait_for_owner_tools_invoke(stack)
    result = subprocess.run(
        [
            "podman",
            "exec",
            "--user",
            "node",
            stack.container_name,
            "node",
            "/app/openclaw.mjs",
            "gateway",
            "call",
            "sessions.list",
            "--json",
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, (
        f"local gateway call failed ({result.returncode}): {result.stdout[-1500:]} {result.stderr[-1500:]}{_logs(stack)}"
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
