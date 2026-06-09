#!/usr/bin/env bash
# Build the hardened Vaultwarden image from THIS fork (NIST SR: provenance —
# you build from source you control, then pin the resulting digest).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${1:-localhost/nextvault:latest}"

cd "$REPO_ROOT"
echo "Building $TAG from $REPO_ROOT (DB=postgresql) ..."
# --format docker is REQUIRED: the Dockerfile uses SHELL ["/bin/bash", ...]
# (for `source`), which podman's default OCI format ignores.
podman build \
	--format docker \
	-f docker/Dockerfile.debian \
	--build-arg DB=postgresql \
	--build-arg CARGO_PROFILE=release \
	-t "$TAG" \
	.

echo
echo "Built $TAG"
echo "Pin this digest in deploy/quadlet/nextvault.container (NIST CM-2/SR):"
podman image inspect --format '{{.Id}}' "$TAG"
