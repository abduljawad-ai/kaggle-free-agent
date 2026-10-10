#!/usr/bin/env bash
# ============================================================================
#  setup.sh  —  ONE-TIME PC setup: create the SSH key used by the tunnel.
#
#  Usage (run once on your PC, NOT on Kaggle):
#     ./setup.sh
#
#  Creates ~/.ssh/kaggle_key (Ed25519) if missing and prints the PUBLIC key.
#  Put that public key into a Kaggle Secret named  SSH_PUBKEY
#  (Kaggle notebook -> Add-ons -> Secrets) so only YOUR PC can connect.
# ============================================================================
set -euo pipefail

KEY="$HOME/.ssh/kaggle_key"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [[ -f "$KEY" ]]; then
  echo "==> SSH key already exists: $KEY (leaving it unchanged)"
else
  echo "==> Generating a new Ed25519 key at $KEY ..."
  ssh-keygen -t ed25519 -N "" -C "kaggle-tunnel" -f "$KEY" >/dev/null
  echo "    done."
fi
chmod 600 "$KEY" 2>/dev/null || true
chmod 644 "$KEY.pub" 2>/dev/null || true

echo
echo "================================================================="
echo "  Your PUBLIC key — copy this whole line:"
echo "================================================================="
cat "$KEY.pub"
echo "================================================================="
echo
echo "  One-time steps:"
echo "   1. Kaggle notebook -> Add-ons -> Secrets"
echo "      - SSH_PUBKEY = the public key line above"
echo "      - ZROK_TOKEN = your token from https://myzrok.io"
echo "   2. Run the Kaggle cell (kaggle_cell.py)."
echo "   3. On this PC:   ./connect.sh <SHARE_TOKEN>"
echo "================================================================="
