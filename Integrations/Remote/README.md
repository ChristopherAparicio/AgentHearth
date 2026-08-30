# AgentHearth Remote Agent

The remote agent is a Python-standard-library helper installed over SSH by the
macOS app. It scans provider stores on the remote host and exposes the same
loopback metadata receiver used locally.

- Installed path: `~/.local/share/agenthearth/agenthearth_remote.py`
- Receiver: `127.0.0.1:5274` on the remote host
- Persistence: normalized hook/plugin events under
  `~/.local/state/agenthearth`
- Transport: the macOS app invokes snapshots through the user's system SSH
  client and existing `~/.ssh/config`

No SSH private key, prompt, response, tool payload, or source-code content is
stored by AgentHearth.

Installation is idempotent and owns only the paths listed above plus
`~/.config/systemd/user/agenthearth-remote.service` and the bundled OpenCode
plugin at `~/.config/opencode/plugins/agenthearth.ts`. The Settings UI exposes a
separate uninstall action that stops the service and removes those owned files.
Removing a host from the macOS list does not silently delete remote files.

Explicit OpenCode servers are addressed by loopback port. The macOS app asks
the remote agent over SSH to query `127.0.0.1:<port>` and return metadata-only
sessions. This supports several OpenCode runtimes on one SSH host without
opening an OpenCode listener to the LAN.
