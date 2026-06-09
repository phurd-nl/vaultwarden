#!/usr/bin/env bash
# Build the minimal egress allowlist proxy image (alpine + tinyproxy) from this
# repo (NIST SR-3/CM-2: controlled source). The tinyproxy config + FQDN allowlist
# are mounted at runtime by the quadlet, not baked, so editing the allowlist does
# not require a rebuild.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${1:-localhost/nextvault-egress-proxy:latest}"
CTX="$REPO_ROOT/deploy/egress-proxy"

echo "Building $TAG from $CTX ..."
podman build -f "$CTX/Containerfile" -t "$TAG" "$CTX"

echo
echo "Built $TAG"
echo "Pin this digest in deploy/quadlet/nextvault-egress-proxy.container (NIST CM-2/SR):"
podman image inspect --format '{{.Id}}' "$TAG"
