#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <host-type>" >&2
  exit 1
fi

HOST_TYPE="$1"
REPO="xinxinw1/dotfiles"
BRANCH="main"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Downloading $REPO@$BRANCH ==="
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar -xz -C "$TMP_DIR" --strip-components=1

echo "=== Installing $HOST_TYPE files into $HOME ==="
cp -a "$TMP_DIR/$HOST_TYPE/." "$HOME/"
find "$HOME" -maxdepth 1 -name '*.sh' -exec chmod 0755 {} +

echo "=== Dotfiles installed ==="
