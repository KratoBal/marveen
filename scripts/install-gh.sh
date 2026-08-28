#!/bin/bash
set -euo pipefail
ARCH=$(dpkg --print-architecture)
KEY=/etc/apt/keyrings/githubcli-archive-keyring.gpg

echo "== 1. keyring"
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee "$KEY" > /dev/null
sudo chmod go+r "$KEY"

echo "== 2. repo"
echo "deb [arch=$ARCH signed-by=$KEY] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

echo "== 3. apt update (csak a gh repo)"
sudo apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/github-cli.list \
  -o Dir::Etc::sourceparts=/dev/null -o APT::Get::List-Cleanup=0

echo "== 4. telepites"
sudo apt-get install -y gh

echo "== 5. ellenorzes"
gh --version
