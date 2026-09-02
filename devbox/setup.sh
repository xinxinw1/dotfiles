#!/bin/bash
set -e

echo "=== Authorizing GitHub CLI for xinxinw1 ==="
echo "Paste a GitHub personal access token (repo, admin:public_key scopes) and press enter:"
read -s -p "Token: " GH_TOKEN
echo
echo "$GH_TOKEN" | gh auth login --hostname github.com --git-protocol ssh --with-token
unset GH_TOKEN

echo "=== Adding SSH key to GitHub account ==="
gh ssh-key add ~/.ssh/id_rsa.pub --title "$(hostname)-$(date +%Y%m%d)"

echo "=== Cloning repos into ~/git ==="
mkdir -p ~/git
git clone git@github.com:xinxinw1/xin-xin.me.git ~/git/xin-xin.me
git clone git@github.com:xinxinw1/cloud-config.git ~/git/cloud-config

echo "=== Setup complete ==="
