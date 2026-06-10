#!/usr/bin/env bash
# Build the hardened Vaultwarden image from THIS fork (NIST SR: provenance —
# you build from source you control, then pin the resulting digest).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${1:-localhost/nextvault:latest}"

# The server image's `vault` stage (docker/Dockerfile.debian) copies the
# NextVault-branded web-vault from this locally-built image. It is produced by
# the bw_web_builds fork (branch nextvault-rebrand) via `make podman-extract`
# and must be present on this build host before we build the server.
VAULT_IMAGE="localhost/nextvault-web-vault:v2026.4.1"
if ! podman image exists "$VAULT_IMAGE"; then
	echo "ERROR: branded web-vault image '$VAULT_IMAGE' not found on this host." >&2
	echo "Build it from the bw_web_builds fork and load it here, e.g.:" >&2
	echo "  (on the build box) cd bw_web_builds && make podman-extract" >&2
	echo "  podman tag bw_web_vault $VAULT_IMAGE" >&2
	echo "  podman save $VAULT_IMAGE | ssh <this-host> podman load" >&2
	exit 1
fi

cd "$REPO_ROOT"
echo "Building $TAG from $REPO_ROOT (DB=postgresql) ..."
echo "Using branded web-vault: $VAULT_IMAGE"
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
