#!/bin/bash
set -e

# Written by cloud-init at bootstrap so re-runs don't need the host type
# spelled out again. An explicit argument still wins.
HOST_TYPE_FILE="/etc/host-type"

if [ -n "$1" ]; then
  HOST_TYPE="$1"
elif [ -r "$HOST_TYPE_FILE" ]; then
  HOST_TYPE="$(tr -d '[:space:]' < "$HOST_TYPE_FILE")"
fi

if [ -z "$HOST_TYPE" ]; then
  echo "Usage: $0 [host-type]" >&2
  echo "No host type given and $HOST_TYPE_FILE is missing or empty." >&2
  exit 1
fi

REPO="xinxinw1/dotfiles"
BRANCH="main"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Downloading $REPO@$BRANCH ==="
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar -xz -C "$TMP_DIR" --strip-components=1

if [ ! -d "$TMP_DIR/$HOST_TYPE" ]; then
  echo "Unknown host type '$HOST_TYPE': $REPO@$BRANCH has no such directory." >&2
  exit 1
fi

echo "=== Installing $HOST_TYPE files into $HOME ==="
cp -a "$TMP_DIR/$HOST_TYPE/." "$HOME/"
find "$HOME" -maxdepth 1 -name '*.sh' -exec chmod 0755 {} +

echo "=== Dotfiles installed ==="
