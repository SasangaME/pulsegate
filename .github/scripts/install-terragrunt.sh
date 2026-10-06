#!/usr/bin/env bash
# Installs a pinned Terragrunt release on a Linux amd64 runner, and refuses a
# binary whose checksum does not match the release's SHA256SUMS.
#
# Usage: install-terragrunt.sh <version>     e.g. 1.1.4

set -euo pipefail

version="${1:?usage: install-terragrunt.sh <version>}"
asset="terragrunt_linux_amd64"
base="https://github.com/gruntwork-io/terragrunt/releases/download/v${version}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

curl -fsSLO "${base}/${asset}"
curl -fsSLO "${base}/SHA256SUMS"

grep " ${asset}\$" SHA256SUMS | sha256sum --check --strict -

sudo install -m 0755 "$asset" /usr/local/bin/terragrunt
terragrunt --version
