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

# GitHub redirects /releases/latest to /releases/tag/<tag> for the release it
# has marked latest -- drafts and prereleases are skipped, which is the point of
# asking it rather than version-sorting the tags here. -o /dev/null throws away
# the page; %{url_effective} is where -L finally landed. curl is the only thing
# needed, which is what makes this usable at all: this script runs from
# cloud-init's runcmd, where there is no jq and no guarantee of git.
#
# The script itself arrives by the much simpler
# /releases/latest/download/install-dotfiles.sh, but that endpoint serves
# attached assets only -- the source tarball is not one -- so the payload below
# has to go the long way round.
latest_release_tag() {
  local url
  if ! url="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/$1/releases/latest")"; then
    echo "Could not reach GitHub to resolve the latest release of $1." >&2
    return 1
  fi
  case "$url" in
    */releases/tag/*) printf '%s\n' "${url##*/releases/tag/}" ;;
    *)
      echo "$1 has no published release (landed on $url)." >&2
      return 1
      ;;
  esac
}

# The boxes things get broken on track the tip; the box that serves
# new.xin-xin.me installs what was actually cut. DOTFILES_REF overrides either
# one -- GitHub's archive endpoint takes a branch, a tag or a commit sha there --
# which is how to try an unmerged branch on thevenin without editing this.
if [ -n "${DOTFILES_REF:-}" ]; then
  REF="$DOTFILES_REF"
else
  case "$HOST_TYPE" in
    devbox|thevenin-dev) REF="refs/heads/main" ;;
    *)                   REF="refs/tags/$(latest_release_tag "$REPO")" ;;
  esac
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Downloading $REPO@$REF ==="
curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" \
  | tar -xz -C "$TMP_DIR" --strip-components=1

if [ ! -d "$TMP_DIR/$HOST_TYPE" ]; then
  echo "Unknown host type '$HOST_TYPE': $REPO@$REF has no such directory." >&2
  exit 1
fi

echo "=== Installing $HOST_TYPE files into $HOME ==="
cp -a "$TMP_DIR/$HOST_TYPE/." "$HOME/"
find "$HOME" -maxdepth 1 -name '*.sh' -exec chmod 0755 {} +

echo "=== Dotfiles installed ==="
