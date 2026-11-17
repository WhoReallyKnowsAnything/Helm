# Phone Access via Tailscale + SSH + tmux

How to attach to this project's Claude Code sessions (orchestrator or worker) from your
iPhone. Traditional SSH does authentication; Tailscale only provides the private network
transport between your phone and your Mac. tmux keeps sessions alive and lets the phone
and the desktop iTerm window attach to the exact same running session at once.

## Mac setup

```bash
brew install tmux                   # required by this project's session-wrapping (Phase 18)
brew install --cask tailscale-app   # GUI app is sufficient -- see "Not used: tailscale ssh" below
open -a Tailscale                   # sign in, grant VPN permission
```

Then: **System Settings -> General -> Sharing -> Remote Login** -> ON, restricted to a
specific user (never "All users"). This is the SSH server macOS ships with, and it's what
your phone will actually connect to.

## SSH key auth

On the Mac, generate an ed25519 key if you don't already have one:

```bash
ssh-keygen -t ed25519 -C "iphone-access"
```

Add the iPhone's public key (generated in the next section) to `~/.ssh/authorized_keys` on
the Mac. Then disable password auth so the Mac only accepts key-based login:

```bash
# /etc/ssh/sshd_config
PasswordAuthentication no
```

Restart the SSH service (toggle Remote Login off/on in System Settings) after editing.

## iPhone setup

1. App Store: install **Tailscale**, sign in with the same account used on the Mac.
2. App Store: install **Termius** (default recommendation) or Blink Shell.
3. In Termius, generate an ed25519 SSH key in-app and copy its public key onto the Mac's
   `~/.ssh/authorized_keys` (see above).
4. Add a new host in Termius using the Mac's Tailscale hostname (visible in the Tailscale
   app's device list) and the SSH key you just generated.

## Usage

From the phone:

```bash
ssh <user>@<mac-tailscale-hostname>
tmux attach -t <label>          # SAME grouped session the matching iTerm tab uses
```

`<label>` is `dashboard` for the orchestrator session, or the worker's slugified
task-title label (the same name shown in the matching iTerm tab). `Ctrl-b d` detaches
without disturbing the desktop view -- the Mac's iTerm window keeps running exactly as
before.

## Not used: `tailscale ssh`

This setup deliberately does **not** use `tailscale ssh` (a.k.a. `tailscale up --ssh`).
That is a different mechanism: Tailscale's own reimplemented SSH server, with identity
granted via tailnet policy instead of SSH keys. It requires the open-source `tailscaled`
daemon variant specifically -- **the standard GUI Tailscale.app installed above cannot
serve inbound `tailscale ssh` connections at all.** If you ever run `tailscale up --ssh`
or `tailscale ssh <host>` against this Mac, it will hang or error, because the GUI app
doesn't run the SSH server side of that feature.

This project doesn't need it: Tailscale here is purely a private network transport, and
traditional Remote Login + `~/.ssh/authorized_keys` (configured above) does the actual
authentication.

## Not used: `/remote-control`

Claude Code ships a Remote Control feature (`/remote-control`, shown in the status line as
`/rc`) that keeps a session running on this Mac while phone or browser acts as the remote.
It is **not usable in this project** and never will be while the current tooling stands.

Remote Control requires a first-party Anthropic endpoint. This machine sets
`ANTHROPIC_BASE_URL` to a local proxy (`http://localhost:4444`), which the lean-ctx and
headroom chains depend on, so the eligibility check fails with `custom_base_url` and the
feature reports "not available with a custom ANTHROPIC_BASE_URL".

The override flag does not help: `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL` is honoured for
gateway and model-discovery paths but is explicitly excluded for Remote Control. Verified
against the Claude Code 2.1.270 binary.

Note that `/teleport` is a different feature (handing the session off to claude.ai/code)
gated by the same set of reasons. Neither is a route into these sessions.

Tailscale + SSH + tmux, documented above, is the supported path.
