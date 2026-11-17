#!/bin/bash
# orchestration/lib/setup-phone-keys.sh
# One-shot setup: per-project SSH keypair + authorized_keys restriction + ssh config
# Host entry, for every subdirectory of $PROJECTS_DIR (default ~/Documents/Projects), so
# Termius can pick up every project's phone-access host via a single "Import from SSH
# config" sync.
#
# Required: TAILSCALE_IP, this Mac's Tailscale IP (used as HostName in each Host entry).
# Example: TAILSCALE_IP=100.x.y.z bash setup-phone-keys.sh
#
# Writes only to ~/.ssh/* -- run this yourself in a terminal, it is never invoked
# automatically by launch-claude.sh or any other script in this repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/tmux-session.sh"

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/Documents/Projects}"
SSH_DIR="$HOME/.ssh"
KEYS_DIR="$SSH_DIR/phone-keys"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
SSH_CONFIG="$SSH_DIR/config"
: "${TAILSCALE_IP:?set TAILSCALE_IP to the Tailscale IP of this Mac before running}"

mkdir -p "$SSH_DIR" "$KEYS_DIR"
chmod 700 "$SSH_DIR" "$KEYS_DIR"

# setup_keypair slug -> path to the project's private key, generating it first if absent
setup_keypair() {
    local slug="$1" key_path="$KEYS_DIR/$slug-iphone"
    if [[ ! -f "$key_path" ]]; then
        ssh-keygen -t ed25519 -N "" -q -f "$key_path" -C "$slug-iphone"
    fi
    echo "$key_path"
}

# ensure_authorized_keys_entry slug pubkey_path -- forced command= restricts the phone
# key to exactly this project's dashboard window, so a leaked/lost-phone key can't get
# an interactive shell or reach any other project's session.
ensure_authorized_keys_entry() {
    local slug="$1" pub_path="$2"
    local blob
    blob="$(awk '{print $2}' "$pub_path")"

    [[ -f "$AUTHORIZED_KEYS" ]] || { : > "$AUTHORIZED_KEYS"; chmod 600 "$AUTHORIZED_KEYS"; }
    grep -qF "$blob" "$AUTHORIZED_KEYS" && return 0

    local attach_cmd
    attach_cmd="$(tmux_client_attach_cmd "$slug" dashboard)"
    echo "command=\"$attach_cmd\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$pub_path")" >> "$AUTHORIZED_KEYS"
}

# ensure_ssh_config_block slug key_path -- IdentitiesOnly forces this key for this host
# instead of ssh trying every identity in the agent, which is both slow and would leak
# which project keys exist to the far end during auth.
ensure_ssh_config_block() {
    local slug="$1" key_path="$2" host="$slug-iphone"
    [[ -f "$SSH_CONFIG" ]] || { : > "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"; }
    grep -qx "Host $host" "$SSH_CONFIG" && return 0

    cat >> "$SSH_CONFIG" <<EOF
Host $host
    HostName $TAILSCALE_IP
    User $USER
    IdentityFile $key_path
    IdentitiesOnly yes
EOF
}

summary=()
for dir in "$PROJECTS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    slug="$(tmux_base_session_name "$dir")"
    key_path="$(setup_keypair "$slug")"
    ensure_authorized_keys_entry "$slug" "$key_path.pub"
    ensure_ssh_config_block "$slug" "$key_path"
    summary+=("$slug|$key_path")
done

echo
printf '%-30s %s\n' "PROJECT" "KEY PATH"
for row in "${summary[@]}"; do
    printf '%-30s %s\n' "${row%%|*}" "${row#*|}"
done
echo
echo "Termius (Mac app) -> Import from SSH config, then sync, pushes all Host entries above to the phone at once."
