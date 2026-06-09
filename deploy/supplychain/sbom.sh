#!/usr/bin/env bash
# Generate an SBOM (CycloneDX + SPDX) for all three governed images.
# NIST SR-3/SR-4 (supply-chain provenance), CM-2 (baseline inventory).
#
# An SBOM is the machine-readable component inventory the assessor uses as
# evidence that you KNOW what is inside each image. It is also the input the
# vulnerability scanner (scan.sh) correlates CVEs against. We emit BOTH formats:
#   - CycloneDX  : feeds scanners / OWASP Dependency-Track.
#   - SPDX (tag)  : the format most procurement / compliance tooling expects.
#
# Tooling: prefers `syft` (purpose-built SBOM generator, both formats native).
# Falls back to `trivy image --format cyclonedx` (CycloneDX only — SPDX is then
# skipped with a warning). Install notes are in README.md.
#
# Output: ./sbom/<image-slug>@<digest>.<format>.json  (digest in the filename so
# an SBOM is unambiguously tied to the exact image it describes — SR evidence).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SBOM_OUT_DIR:-$HERE/sbom}"

# The three images this deployment runs (must match deploy/quadlet/*.container).
# The locally-built fork image is FIRST: build-image.sh must have produced it.
IMAGES=(
	"localhost/nextvault:latest"
	"docker.io/library/postgres:17.5"
	"docker.io/library/caddy:2.8"
)

mkdir -p "$OUT_DIR"

# --- Tool selection -------------------------------------------------------
TOOL=""
if command -v syft >/dev/null 2>&1; then
	TOOL="syft"
elif command -v trivy >/dev/null 2>&1; then
	TOOL="trivy"
	echo "WARN: syft not found; falling back to 'trivy image --format cyclonedx'." >&2
	echo "WARN: trivy fallback emits CycloneDX only — SPDX output will be SKIPPED." >&2
	echo "WARN: install syft for SPDX (see deploy/supplychain/README.md)."          >&2
else
	echo "ERROR: neither 'syft' nor 'trivy' is installed." >&2
	echo "Install one (see deploy/supplychain/README.md), then re-run." >&2
	exit 127
fi
echo "Using $TOOL to generate SBOMs into $OUT_DIR"
echo

# slugify an image ref into a filename-safe stem.
slug() { echo "$1" | tr '/:' '__'; }

# Resolve the digest that identifies this exact image. Pulled images carry a
# RepoDigest (registry-content digest); the locally-built fork has none unless
# pushed, so we fall back to its local image ID (.Id). Either way the SBOM
# filename is pinned to a sha256 that names the bytes we scanned.
image_digest() {
	local ref="$1" d
	d="$(podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$ref" 2>/dev/null || true)"
	if [[ -n "$d" ]]; then
		# RepoDigests look like name@sha256:...; keep only the sha256:... part.
		echo "${d##*@}"
		return
	fi
	# No registry digest (e.g. the locally-built, never-pushed fork image): use
	# the local image ID, normalised to sha256:<hex> to match pin-digests.sh.
	local id
	id="$(podman image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true)"
	[[ -z "$id" ]] && return
	[[ "$id" == sha256:* ]] && echo "$id" || echo "sha256:${id}"
}

rc=0
for ref in "${IMAGES[@]}"; do
	echo "== $ref =="
	if ! podman image exists "$ref"; then
		echo "  SKIP: image not present locally."
		if [[ "$ref" == localhost/* ]]; then
			echo "        Build it first: deploy/scripts/build-image.sh"
		else
			echo "        Pull it first:  podman pull $ref"
		fi
		rc=1
		continue
	fi

	digest="$(image_digest "$ref")"
	if [[ -z "$digest" ]]; then
		echo "  WARN: could not resolve a digest for $ref; using 'nodigest'." >&2
		digest="nodigest"
	fi
	stem="$(slug "$ref")@${digest}"
	cdx="$OUT_DIR/${stem}.cyclonedx.json"
	spdx="$OUT_DIR/${stem}.spdx.json"

	case "$TOOL" in
	syft)
		echo "  CycloneDX -> $(basename "$cdx")"
		syft scan "containerd:$ref" -o "cyclonedx-json=$cdx" 2>/dev/null \
			|| syft "$ref" -o "cyclonedx-json=$cdx"
		echo "  SPDX      -> $(basename "$spdx")"
		syft "$ref" -o "spdx-json=$spdx"
		;;
	trivy)
		echo "  CycloneDX -> $(basename "$cdx")"
		trivy image --quiet --format cyclonedx --output "$cdx" "$ref"
		echo "  SPDX      -> SKIPPED (trivy fallback; install syft)"
		;;
	esac
	echo "  digest: $digest"
	echo
done

echo "SBOMs written to $OUT_DIR"
echo "Retain these as SR-3/SR-4 + CM-2 assessment evidence (one per image digest)."
exit "$rc"
