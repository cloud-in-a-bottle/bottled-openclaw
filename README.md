# bottled-openclaw

[OpenClaw](https://github.com/openclaw/openclaw) packaged as a Cloud in a
Bottle app. OpenClaw is a self-hosted personal AI assistant with a browser
control panel, an agent that can use tools, and a set of built-in plugins.

## What you get

- A browser control panel for chatting with the assistant and managing agent
  sessions.
- Built-in plugins including web browsing, file transfer, memory, and canvas.
- Owner auto-login: because the Cloud in a Bottle router already authenticates
  you, OpenClaw trusts that and drops you straight into the control panel with
  no separate OpenClaw login.

## Setup

OpenClaw needs an Anthropic API key to answer. Add a secret named
`ANTHROPIC_API_KEY` in your instance's secrets app, approve the grant for this
app, then reload OpenClaw. Until a key is available the panel loads but the
assistant replies with a "no API key" error. The default model is Claude
Sonnet.

## Usage

Open the app on your instance. You land in the control panel as the owner.
Start a chat, and the assistant can use its tools (for example fetching a web
page) as part of a reply. Manage sessions and plugins from the same panel.

## Caveats

- The assistant is non-functional until an `ANTHROPIC_API_KEY` is configured
  (see Setup).
- OpenClaw's device pairing is turned off because the Cloud in a Bottle owner
  gate is the authentication; anyone who can open the app is treated as the
  owner.
- OpenClaw tracks a fast-moving upstream. The base image is pinned by digest,
  so bump it in the Dockerfile to upgrade.

## Data

OpenClaw's configuration and state (sessions, memory, settings) persist in the
app's data directory. Removing the app deletes this data.

## Resources

2 GB RAM, 1 CPU core.

## License

OpenClaw is licensed under the MIT License (Copyright (c) 2026 OpenClaw
Foundation). The packaging files in this repository are also provided under the
MIT License. See LICENSE and NOTICE.
