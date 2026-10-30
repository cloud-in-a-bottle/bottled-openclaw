// The only path from the router to the OpenClaw gateway. The gateway listens on loopback and trusts only loopback as
// a proxy (gateway.trustedProxies), so its trusted-proxy auth sees requests from here, never from the router directly.
//
// Forwarded client headers are rebuilt from what this proxy knows, never passed through: X-Forwarded-For is the peer
// this proxy sees, and X-Forwarded-Proto/-Host come from the app's own origin. X-OpenHost-Is-Owner is forwarded as
// received: the router strips client copies of X-OpenHost-* headers and sets it only for the owner.
import http from "node:http";
import net from "node:net";

const LISTEN_PORT = Number(requireEnv("OWNER_PROXY_LISTEN_PORT"));
const GATEWAY_PORT = Number(requireEnv("OWNER_PROXY_GATEWAY_PORT"));
const FORWARDED_PROTO = requireEnv("OWNER_PROXY_FORWARDED_PROTO");
const FORWARDED_HOST = requireEnv("OWNER_PROXY_FORWARDED_HOST");
const GATEWAY_HOST = "127.0.0.1";
// OpenClaw refuses a proxied request whose client resolves to loopback. Depending on the host's podman/pasta setup,
// the router's connection reaches the container either from the host's own address or from loopback; in the latter
// case the router is still the peer, so name it with an address from TEST-NET-1 (RFC 5737), which is never routable.
const LOOPBACK_PEER_STANDIN = "192.0.2.1";

const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-connection",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is not set`);
  }
  return value;
}

function peerAddress(socket) {
  const raw = (socket.remoteAddress ?? "").replace(/^::ffff:/i, "");
  if (!net.isIP(raw) || raw === "::1" || raw.startsWith("127.")) {
    return LOOPBACK_PEER_STANDIN;
  }
  return raw;
}

function gatewayRequestHeaders(req) {
  const headers = {};
  for (const [name, value] of Object.entries(req.headers)) {
    if (
      HOP_BY_HOP.has(name) ||
      name === "forwarded" ||
      name === "x-real-ip" ||
      name.startsWith("x-forwarded-")
    ) {
      continue;
    }
    headers[name] = value;
  }
  headers["x-forwarded-for"] = peerAddress(req.socket);
  headers["x-forwarded-proto"] = FORWARDED_PROTO;
  headers["x-forwarded-host"] = FORWARDED_HOST;
  return headers;
}

function responseHeaders(rawHeaders) {
  const kept = [];
  for (let i = 0; i < rawHeaders.length; i += 2) {
    if (!HOP_BY_HOP.has(rawHeaders[i].toLowerCase())) {
      kept.push(rawHeaders[i], rawHeaders[i + 1]);
    }
  }
  return kept;
}

function writeRawHead(socket, statusCode, statusMessage, rawHeaders) {
  let head = `HTTP/1.1 ${statusCode} ${statusMessage ?? ""}\r\n`;
  for (let i = 0; i < rawHeaders.length; i += 2) {
    head += `${rawHeaders[i]}: ${rawHeaders[i + 1]}\r\n`;
  }
  socket.write(`${head}\r\n`);
}

const server = http.createServer((req, res) => {
  const upstream = http.request(
    { host: GATEWAY_HOST, port: GATEWAY_PORT, method: req.method, path: req.url, headers: gatewayRequestHeaders(req) },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode, upstreamRes.statusMessage, responseHeaders(upstreamRes.rawHeaders));
      upstreamRes.pipe(res);
    },
  );
  upstream.on("error", () => {
    if (!res.headersSent) {
      res.writeHead(502, { "content-type": "text/plain" });
    }
    res.end("gateway unavailable");
  });
  req.pipe(upstream);
});

server.on("upgrade", (req, socket, head) => {
  const headers = gatewayRequestHeaders(req);
  headers.connection = "Upgrade";
  headers.upgrade = req.headers.upgrade;
  const upstream = http.request({ host: GATEWAY_HOST, port: GATEWAY_PORT, method: req.method, path: req.url, headers });
  upstream.on("upgrade", (upstreamRes, upstreamSocket, upstreamHead) => {
    writeRawHead(socket, 101, upstreamRes.statusMessage, upstreamRes.rawHeaders);
    if (upstreamHead.length > 0) {
      socket.write(upstreamHead);
    }
    if (head.length > 0) {
      upstreamSocket.write(head);
    }
    upstreamSocket.on("error", () => socket.destroy());
    socket.on("error", () => upstreamSocket.destroy());
    upstreamSocket.pipe(socket);
    socket.pipe(upstreamSocket);
  });
  // The gateway refused the upgrade (eg 401/403): relay its response and close.
  upstream.on("response", (upstreamRes) => {
    writeRawHead(socket, upstreamRes.statusCode, upstreamRes.statusMessage, [
      ...responseHeaders(upstreamRes.rawHeaders),
      "Connection",
      "close",
    ]);
    upstreamRes.pipe(socket);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
  upstream.end();
});

server.listen(LISTEN_PORT, "::", () => {
  console.log(`[owner-proxy] listening on :${LISTEN_PORT}, forwarding to ${GATEWAY_HOST}:${GATEWAY_PORT}`);
});
