#!/usr/bin/env bash
# Scan all three governed images for known vulnerabilities (CVEs).
# NIST RA-5 (vulnerability monitoring/scanning), SI-2 (flaw remediation),
# SR-3 (supply-chain protection).
#
# The scanner matches installed components (OS packages + the Rust/Go/etc.
# application layer) against vulnerability feeds and reports findings by
# severity. This script enforces a SEVERITY GATE: it FAILS (non-zero exit) when
# a finding at/above the gate exists and is not on the exceptions allowlist.
# That non-zero exit is what a CI job / pre-deploy check keys off of.
#
# Tooling: prefers `trivy image` (rich DB, native .trivyignore allowlist).
# Falls back to `grype` (uses .grype.yaml ignore rules). Install notes in README.md.
#
# Exceptions / accepted findings (RA-5 / SI-2 exception process):
#   - trivy: a .trivyignore file (default: ./.trivyignore) lists accepted CVE IDs.
#   - grype: a .grype.yaml `ignore:` block (default: ./.grype.yaml).
#   Each entry MUST carry a justification comment + review date. The README
#   defines the exception process; an empty/absent allowlist means "no exceptions".
#
# Output: human-readable table to stdout AND machine-readable reports under
# ./reports/ (one per image, timestamped) — RA-5 assessment evidence.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${SCAN_REPORT_DIR:-$HERE/reports}"

# Severity that fails the gate, and everything above it. trivy/grype severities:
# UNKNOWN < LOW < MEDIUM < HIGH < CRITICAL. Default gate = CRITICAL (per SLA;
# HIGH is tracked but does not block — see README vulnerability SLA table).
GATE="${SEVERITY_GATE:-CRITICAL}"

# Exceptions allowlist (accepted/unpatched findings with justification).
TRIVYIGNORE="${TRIVYIGNORE:-$HERE/.trivyignore}"
GRYPE_CONFIG="${GRYPE_CONFIG:-$HERE/.grype.yaml}"

IMAGES=(
	"localhost/nextvault:latest"
	"docker.io/library/postgres:17.10"
	"docker.io/library/caddy:2.11.4"
)

mkdir -p "$REPORT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# Build the comma-separated severity list at/above the gate.
ALL_SEV=(UNKNOWN LOW MEDIUM HIGH CRITICAL)
gate_severities() {
	local out=() seen=0 s
	for s in "${ALL_SEV[@]}"; do
		[[ "$s" == "$GATE" ]] && seen=1
		[[ "$seen" -eq 1 ]] && out+=("$s")
	done
	local IFS=,
	echo "${out[*]}"
}
GATE_SEVS="$(gate_severities)"

# --- Tool selection -------------------------------------------------------
TOOL=""
if command -v trivy >/dev/null 2>&1; then
	TOOL="trivy"
elif command -v grype >/dev/null 2>&1; then
	TOOL="grype"
	echo "WARN: trivy not found; falling back to 'grype'." >&2
	echo "WARN: grype uses $GRYPE_CONFIG for ignore rules (not .trivyignore)."  >&2
else
	echo "ERROR: neither 'trivy' nor 'grype' is installed." >&2
	echo "Install one (see deploy/supplychain/README.md), then re-run." >&2
	exit 127
fi
# Only pass --ignorefile when the allowlist actually exists (trivy errors on a
# missing ignorefile path). Empty array = no flag = gate enforced on everything.
TRIVY_IGNORE_FLAG=()
[[ -f "$TRIVYIGNORE" ]] && TRIVY_IGNORE_FLAG=(--ignorefile "$TRIVYIGNORE")

echo "Scanner: $TOOL   gate: $GATE (fails on: $GATE_SEVS)   reports: $REPORT_DIR"
if [[ "$TOOL" == "trivy" && -f "$TRIVYIGNORE" ]]; then
	echo "Exceptions: $TRIVYIGNORE ($(grep -cvE '^\s*(#|$)' "$TRIVYIGNORE" 2>/dev/null || echo 0) entries)"
elif [[ "$TOOL" == "grype" && -f "$GRYPE_CONFIG" ]]; then
	echo "Exceptions: $GRYPE_CONFIG"
else
	echo "Exceptions: none (no allowlist file present)"
fi
echo

slug() { echo "$1" | tr '/:' '__'; }

overall=0
for ref in "${IMAGES[@]}"; do
	echo "========================================================================"
	echo "== $ref"
	echo "========================================================================"
	if ! podman image exists "$ref"; then
		echo "  SKIP: image not present locally."
		if [[ "$ref" == localhost/* ]]; then
			echo "        Build it first: deploy/scripts/build-image.sh"
		else
			echo "        Pull it first:  podman pull $ref"
		fi
		overall=1
		continue
	fi
	stem="$(slug "$ref")"

	case "$TOOL" in
	trivy)
		json="$REPORT_DIR/${stem}.${STAMP}.trivy.json"
		# Full JSON report (all severities) for evidence/triage — never gates.
		trivy image --quiet --scanners vuln \
			"${TRIVY_IGNORE_FLAG[@]}" \
			--format json --output "$json" "$ref" || true
		echo "  report: $json"
		echo
		# Gating pass: table to stdout, honoring the allowlist, exit 1 on a hit.
		set +e
		trivy image --scanners vuln \
			"${TRIVY_IGNORE_FLAG[@]}" \
			--severity "$GATE_SEVS" \
			--exit-code 1 \
			--format table "$ref"
		hit=$?
		set -e
		;;
	grype)
		json="$REPORT_DIR/${stem}.${STAMP}.grype.json"
		export GRYPE_CONFIG
		# Full JSON report for evidence.
		grype "$ref" -o json --file "$json" >/dev/null 2>&1 || true
		echo "  report: $json"
		echo
		# Gating pass: --fail-on triggers a non-zero exit at/above the gate.
		set +e
		grype "$ref" --fail-on "$(echo "$GATE" | tr 'A-Z' 'a-z')" -o table
		hit=$?
		set -e
		;;
	esac

	if [[ "$hit" -ne 0 ]]; then
		echo
		echo "  >> GATE FAILED: $ref has unaccepted findings >= $GATE (NIST RA-5/SI-2)."
		echo "     Remediate (rebuild/upgrade) or file an exception (see README)."
		overall=1
	else
		echo
		echo "  >> GATE PASS: no unaccepted findings >= $GATE for $ref."
	fi
	echo
done

echo "========================================================================"
if [[ "$overall" -eq 0 ]]; then
	echo "Result: all images PASS the $GATE gate. Reports retained in $REPORT_DIR (RA-5 evidence)."
else
	echo "Result: one or more images FAILED the $GATE gate or were missing."
	echo "        See reports in $REPORT_DIR. Per SI-2 SLA, remediate within the"
	echo "        window in README.md, or record an approved exception."
fi
exit "$overall"
