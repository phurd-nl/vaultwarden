#!/usr/bin/env bash
# Resolve the current content digest of each governed image and PRINT the exact
# Image= line to set in each quadlet. NIST CM-2 (config baseline by immutable
# reference), SR-4 (provenance: you deploy the exact artifact you assessed).
#
# This script does NOT edit the quadlets — it prints a copy-paste diff so the
# change to deploy/quadlet/*.container stays a reviewed, deliberate commit.
#
# Digest sources (mirrors deploy/scripts/build-image.sh + the quadlet comments):
#   - Pulled images (postgres, caddy): RepoDigests[0] -> name@sha256:...  This is
#     the REGISTRY content digest: pinning to it makes the tag irrelevant and the
#     pull reproducible/verifiable.
#   - Locally-built fork (vaultwarden-nist): has NO registry digest until pushed.
#     We print its local image .Id and the private-registry workflow to obtain a
#     real, deployable digest (see README "Image provenance / private registry").
set -euo pipefail

# ref|quadlet file|kind   (kind: built = local fork, pulled = from a registry)
SPECS=(
	"localhost/vaultwarden-nist:latest|vaultwarden.container|built"
	"docker.io/library/postgres:17.5|vw-postgres.container|pulled"
	"docker.io/library/caddy:2.8|vw-caddy.container|pulled"
)

QUADLET_DIR="${QUADLET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../quadlet" && pwd)}"

echo "Resolving image digests for the three quadlet images."
echo "Quadlet dir: $QUADLET_DIR   (NOT modified — copy-paste the diffs below.)"
echo

# Registry digest of a pulled image: name@sha256:...
repo_digest() {
	podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$1" 2>/dev/null || true
}
# Local image ID of any image present locally, normalised to sha256:<hex> so it
# is usable as a digest reference (podman's .Id is the bare hex, no algo prefix).
image_id() {
	local id
	id="$(podman image inspect --format '{{.Id}}' "$1" 2>/dev/null || true)"
	[[ -z "$id" ]] && return
	[[ "$id" == sha256:* ]] && echo "$id" || echo "sha256:${id}"
}
# Name without tag, e.g. docker.io/library/postgres:17.5 -> docker.io/library/postgres
name_no_tag() { echo "${1%:*}"; }

# Print the current Image= line from a quadlet (the line we'd replace).
current_image_line() {
	local qf="$QUADLET_DIR/$1"
	[[ -f "$qf" ]] && grep -E '^[[:space:]]*Image=' "$qf" | head -n1
}

missing=0
for spec in "${SPECS[@]}"; do
	IFS='|' read -r ref qfile kind <<<"$spec"
	echo "------------------------------------------------------------------------"
	echo "Image:   $ref"
	echo "Quadlet: $qfile"

	if ! podman image exists "$ref"; then
		echo "  STATUS: NOT present locally."
		if [[ "$kind" == built ]]; then
			echo "          Build it:  deploy/scripts/build-image.sh"
		else
			echo "          Pull it:   podman pull $ref"
		fi
		missing=1
		echo
		continue
	fi

	cur="$(current_image_line "$qfile" || true)"
	[[ -n "$cur" ]] && echo "  current: ${cur#"${cur%%[![:space:]]*}"}"

	if [[ "$kind" == pulled ]]; then
		rd="$(repo_digest "$ref")"
		if [[ -z "$rd" ]]; then
			echo "  STATUS: present but no RepoDigest (image built/loaded locally, not pulled)."
			echo "          Re-pull from the registry to obtain a verifiable digest:"
			echo "            podman pull $ref"
			missing=1
			echo
			continue
		fi
		nt="$(name_no_tag "$ref")"
		newline="Image=${nt}@${rd##*@}"
		echo
		echo "  Replace the Image= line in $qfile with:"
		echo
		echo "    $newline"
		echo
	else
		# Locally-built fork: no registry digest unless pushed.
		id="$(image_id "$ref")"
		nt="$(name_no_tag "$ref")"
		echo
		echo "  NOTE (SR-4): this image was built locally from the fork and has NO"
		echo "  registry digest until it is pushed to a registry. Its local image ID is:"
		echo
		echo "    ${id}"
		echo
		echo "  Local-only deployment (single host, AutoUpdate=local): you MAY pin to"
		echo "  the local ID, but it is host-local and not independently verifiable:"
		echo
		echo "    Image=${nt}@${id}"
		echo
		echo "  RECOMMENDED (SR-3/SR-4) — push to your private/allowlisted registry,"
		echo "  then pin the returned registry digest. See README 'Private registry'."
		echo "    podman tag $ref registry.internal.example.com/vaultwarden-nist:<ver>"
		echo "    podman push registry.internal.example.com/vaultwarden-nist:<ver>"
		echo "    podman image inspect --format '{{index .RepoDigests 0}}' \\"
		echo "      registry.internal.example.com/vaultwarden-nist:<ver>"
		echo "    # -> Image=registry.internal.example.com/vaultwarden-nist@sha256:..."
		echo
	fi
done

echo "------------------------------------------------------------------------"
echo "After editing the quadlets: systemctl --user daemon-reload && restart the units."
echo "Pin digests ONLY for an image you have SBOM'd (sbom.sh) and scanned (scan.sh)"
echo "so the deployed artifact == the assessed artifact (CM-2/SR-4)."
exit "$missing"
