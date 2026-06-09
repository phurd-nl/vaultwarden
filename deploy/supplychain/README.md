# Vaultwarden — supply-chain controls (NIST SR-3/SR-4, RA-5, CM-2, SI-2)

Supply-chain assurance slice for the hardened podman deployment. Implements the
"Not yet built → **SBOM + image scan (SR-3/RA-5)**" item from `deploy/README.md`
and operationalises the repeated "**pin the digest** (CM-2/SR)" notes in the
quadlets and `deploy/scripts/build-image.sh`.

Everything new lives in **`deploy/supplychain/`**. Nothing outside this directory
is edited. The one change needed to existing files — replacing the `Image=` tags
in `deploy/quadlet/*.container` with `name@sha256:...` digests — is **printed for
copy-paste by `pin-digests.sh`, not applied** (see *Required external change*).

## What this governs

Three images make up the running stack (`deploy/quadlet/*.container`):

| Image | Origin | Trust basis |
|---|---|---|
| `localhost/vaultwarden-nist:latest` | **Built from this fork** (`deploy/scripts/build-image.sh`) | Source you control; provenance by build, then digest-pin |
| `docker.io/library/postgres:17.5` | Pulled (Docker Official Image) | Registry content digest; allowlisted registry |
| `docker.io/library/caddy:2.8` | Pulled (Docker Official Image) | Registry content digest; allowlisted registry |

## Files in this directory

| File | Purpose | NIST control |
|---|---|---|
| `sbom.sh` | Generate CycloneDX **and** SPDX SBOMs for all three images into `./sbom/`, filename pinned to the image digest. Prefers `syft`, falls back to `trivy --format cyclonedx` (CycloneDX only). | SR-3, SR-4, CM-2 |
| `scan.sh` | Scan all three images for CVEs; configurable severity gate (default FAIL on `CRITICAL`); honors an exceptions allowlist; writes JSON reports to `./reports/`. Prefers `trivy`, falls back to `grype`. | RA-5, SI-2, SR-3 |
| `pin-digests.sh` | Resolve each image's current digest and **print** the exact `Image=...@sha256:...` line to set in each quadlet. Does not edit quadlets. | CM-2, SR-4 |
| `.trivyignore` | Vulnerability exception allowlist template; documents the accepted-finding (exception) process inline. | RA-5, SI-2 |
| `sbom/` | Generated SBOMs (assessment evidence). | SR-3/SR-4, CM-2 |
| `reports/` | Generated scan reports (assessment evidence). | RA-5 |
| `README.md` | This file: the supply-chain control set, risk register entry, SLAs, processes, NIST mapping. | SR/RA/CM/SI |

## How to run

```bash
# 0. Prereqs: build/pull the images first.
deploy/scripts/build-image.sh                 # localhost/vaultwarden-nist:latest
podman pull docker.io/library/postgres:17.5
podman pull docker.io/library/caddy:2.8

# 1. SBOM every image (CycloneDX + SPDX) -> ./sbom/
deploy/supplychain/sbom.sh

# 2. Scan every image; CRITICAL fails the gate -> reports in ./reports/
deploy/supplychain/scan.sh
#    Tighten the gate (also block HIGH):     SEVERITY_GATE=HIGH deploy/supplychain/scan.sh
#    Exceptions: edit deploy/supplychain/.trivyignore (see Exception process)

# 3. Print the digest-pin diff for the quadlets (does NOT edit them)
deploy/supplychain/pin-digests.sh
#    Then hand-edit deploy/quadlet/*.container, commit, daemon-reload, restart.
```

Order matters: SBOM + scan FIRST, pin SECOND. You only pin a digest you have
inventoried and scanned, so the deployed artifact equals the assessed artifact.

## Tooling install

No scanner is installed on the current host (`podman` is the only relevant tool
present). The scripts detect tooling at runtime and fall back; install one of:

```bash
# syft (best for SBOM — native CycloneDX + SPDX)
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b ~/.local/bin
# trivy (best for scanning — rich DB, .trivyignore allowlist; also does CycloneDX SBOM)
curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b ~/.local/bin
# grype (scanner fallback; uses .grype.yaml for ignore rules)
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b ~/.local/bin
```

Verify the installer over a controlled channel before piping to a shell, or
mirror these tools into your environment per your own supply-chain policy.

Capability matrix the scripts rely on:

| Tool | SBOM CycloneDX | SBOM SPDX | Scan | Allowlist |
|---|:--:|:--:|:--:|---|
| `syft`  | yes | yes | no  | n/a |
| `trivy` | yes | no  | yes | `.trivyignore` |
| `grype` | no  | no  | yes | `.grype.yaml` |

---

## The supply-chain control set

### 1. Product-selection risk (ACCEPTED RISK — record in the risk register)

**Vaultwarden is NOT Bitwarden.** It is an unofficial, third-party,
community-maintained reimplementation of the Bitwarden server API in Rust. It is
**not produced, endorsed, or supported by Bitwarden, Inc.** This deployment
additionally runs a **local fork** of Vaultwarden, not upstream Vaultwarden.

Per the handoff doc this is recorded as an **accepted risk**, with these
compensating controls (all implemented in `deploy/`):

- We build from source we control (`build-image.sh`) and pin the digest (CM-2/SR-4)
  rather than trusting a third-party published image.
- Defence-in-depth hardening (`deploy/README.md`): TLS everywhere, internal-only
  DB, cap-drop/read-only/non-root, audit + lockout, encrypted backups.
- This supply-chain slice: SBOM + continuous scanning + EOL monitoring of every
  layer, so a flaw in the unofficial codebase or its dependencies is detected.

**Risk acceptance owner:** Authorizing Official (AO) / Security Lead, per the
handoff doc. Re-affirm at each authorization (ATO) cycle. *(CA-6, PM-9, SR-3.)*

### 2. Open-source software approval (CM-2 / SR-3)

Vaultwarden, PostgreSQL, and Caddy are open-source. Approval basis recorded here:

- **Active maintenance** — all three have active upstream release cadences.
- **License** — Vaultwarden (AGPL-3.0), PostgreSQL (PostgreSQL License), Caddy
  (Apache-2.0): all compatible with internal deployment. Confirm against your
  organisation's OSS-approval list before authorization.
- **Provenance** — see §3. Each component is scanned (§6) and EOL-tracked (§8).

The SBOM (`sbom.sh`) is the authoritative component inventory backing this
approval: it enumerates every transitive package an assessor would ask about.

### 3. Image provenance + private / allowlisted registry (SR-3 / SR-4 / CM-2)

**Provenance by construction (the fork image).** `localhost/vaultwarden-nist` is
built from this repository via `build-image.sh`. Provenance is the build itself,
fixed by pinning the resulting digest.

**Provenance by digest (pulled images).** `postgres` and `caddy` are pulled from
Docker Hub and pinned to their **registry content digest** (`@sha256:...`), so the
mutable tag becomes irrelevant and pulls are reproducible and verifiable.

**Private / allowlisted registry workflow (recommended for production).** A
locally-built image has **no registry digest until pushed** — its only identifier
is the host-local image ID (`.Id`), which is not independently verifiable and does
not exist on other hosts. For a multi-host or assessable deployment:

```bash
# Build, then push the fork image to your private/allowlisted registry:
deploy/scripts/build-image.sh
podman tag localhost/vaultwarden-nist:latest \
  registry.internal.example.com/vaultwarden-nist:2026.06.09
podman push registry.internal.example.com/vaultwarden-nist:2026.06.09
# Obtain the verifiable registry digest to pin:
podman image inspect --format '{{index .RepoDigests 0}}' \
  registry.internal.example.com/vaultwarden-nist:2026.06.09
# -> Image=registry.internal.example.com/vaultwarden-nist@sha256:...
```

Mirror `postgres` and `caddy` into the same registry and configure podman's
registry allowlist (`/etc/containers/registries.conf`) so only the
private/allowlisted registry is permitted as a pull source. `pin-digests.sh`
prints the exact `Image=` line for whichever source you pin.

**Provenance attestation (optional, stronger SR-4).** Sign images with `cosign`
and verify the signature before deploy (`cosign sign` / `cosign verify`,
optionally keyless via your OIDC). Not scripted here; documented as the next
hardening step.

### 4. Who can push (SR-3 / AC-6 / CM-5)

- **Image build/push:** only the CI service account or a named release engineer
  may build the fork image and push to the private registry. Enforce least
  privilege (CM-5) — developers do not push directly to the deploy registry.
- **Registry write access:** restricted to that account; pulls are read-only for
  the deploy host. The deploy host's registry credentials are read-only.
- **Quadlet edits (the digest pin):** changing an `Image=` line is a reviewed
  commit to `deploy/quadlet/*.container` — the same change-control path as any
  config (CM-3). `pin-digests.sh` produces the diff; a human commits it.

### 5. Vulnerability SLA by severity (RA-5 / SI-2)

Findings from `scan.sh`. Remediation = rebuild/upgrade the affected image and
re-pin its digest; if no fix exists, file an exception (§7).

| Severity | Gate (`scan.sh`) | Remediation SLA | Action |
|---|---|---|---|
| **CRITICAL** | **FAILS gate** (default) | **7 days** | Block deploy; patch/rebuild or documented exception with compensating control. |
| **HIGH** | tracked (gate at `SEVERITY_GATE=HIGH`) | **30 days** | Schedule remediation; exception if no fix. |
| **MEDIUM** | tracked | **90 days** | Address in normal patch cycle. |
| **LOW / UNKNOWN** | tracked | best effort | Review at each cycle. |

Scan cadence (RA-5): on every image build/change **and** on a recurring schedule
(weekly) so newly-disclosed CVEs against an unchanged image are caught. Wire
`scan.sh` into CI and/or a systemd timer alongside `deploy/backup/vw-backup.timer`.

### 6. SBOM + scan as assessment evidence (RA-5 / SR-3 / CA-7)

- `sbom.sh` writes one CycloneDX + one SPDX SBOM **per image digest** to `./sbom/`
  — the component inventory backing the OSS approval (§2) and the input the
  scanner correlates CVEs against.
- `scan.sh` writes a timestamped JSON report **per image** to `./reports/` — the
  RA-5 vulnerability-scan record, plus the pass/fail gate decision.
- Together they answer the assessor's questions: *what is in each image* (SBOM),
  *what is known-vulnerable* (scan), *what was accepted and why* (`.trivyignore`),
  and *what is actually running* (the pinned digest from `pin-digests.sh`). Retain
  these artifacts across authorization cycles for continuous monitoring (CA-7).

### 7. Exception process (accepted/unpatched findings — RA-5 / SI-2)

Some findings have no fix yet, are not reachable in this deployment, or are false
positives. These are **accepted, with justification**, via the allowlist:

- **trivy:** add the CVE ID to `.trivyignore` with the four-field comment block
  (Justification / Approved-by / Date / Expires) — template is in that file.
- **grype:** add an `ignore:` rule to `.grype.yaml` using the same four fields.

Rules: prefer remediation over exception; every exception has an **owner** and an
**Expires** review date; the file is the auditable exception register. An empty
allowlist means the gate is enforced on every finding. Review all exceptions at
each authorization cycle and on expiry.

### 8. EOL / end-of-support monitoring (SI-2 / RA-5 / CM-2)

Running an end-of-life component means no security fixes — a standing SI-2 risk.
Track support windows for every layer and plan upgrades before EOL:

| Component | What to watch | Source |
|---|---|---|
| **Vaultwarden (fork)** | Upstream releases vs. fork drift; rebase the fork on a supported upstream tag. | upstream `vaultwarden/vaultwarden` releases / advisories |
| **PostgreSQL** | Major-version EOL (5-year support; **17 → ~Nov 2029**). Plan the major upgrade + pin the new digest before EOL. | endoflife.date/postgresql, postgresql.org/support/versioning |
| **Caddy** | Latest stable line; track 2.x advisories. | github.com/caddyserver/caddy releases |
| **OS base layer** | The Debian base in `docker/Dockerfile.debian` (Vaultwarden) and the Debian base under the postgres/caddy official images — track Debian release/LTS EOL. | endoflife.date/debian |

The SBOM names the exact base-image and package versions, so EOL tracking is
driven from `./sbom/` output, not guesswork. Re-run `sbom.sh` after every rebuild.

---

## Required external change (documented, not applied)

To pin digests in production, the `Image=` line in each quadlet must change from a
tag to a digest. **This is not done by these scripts** — `pin-digests.sh` prints
the exact replacement lines; a human edits and commits them (CM-3 change control):

| File | From | To (example shape) |
|---|---|---|
| `deploy/quadlet/vaultwarden.container` | `Image=localhost/vaultwarden-nist:latest` | `Image=registry.internal.example.com/vaultwarden-nist@sha256:...` (after push) |
| `deploy/quadlet/vw-postgres.container` | `Image=docker.io/library/postgres:17.5` | `Image=docker.io/library/postgres@sha256:...` |
| `deploy/quadlet/vw-caddy.container` | `Image=docker.io/library/caddy:2.8` | `Image=docker.io/library/caddy@sha256:...` |

After editing: `systemctl --user daemon-reload` and restart the units. Re-run
`sbom.sh` + `scan.sh` whenever a digest changes — the new artifact must be
inventoried and scanned before it ships.

Optional registry-allowlist change (`/etc/containers/registries.conf`) to permit
only your private/allowlisted registry is described in §3 and is also left to the
operator (host-level, outside `deploy/`).

## NIST control mapping (summary)

| Control | Where satisfied |
|---|---|
| **SR-3** (supply-chain protection) | SBOM (`sbom.sh`), scanning (`scan.sh`), provenance/registry (§3), who-can-push (§4) |
| **SR-4** (provenance) | build-from-source + digest pin (`pin-digests.sh`, §3), optional cosign |
| **RA-5** (vulnerability monitoring) | `scan.sh` gate + reports (`./reports/`), scan cadence (§5), exceptions (§7) |
| **SI-2** (flaw remediation) | severity SLAs (§5), EOL monitoring (§8), exception register (§7) |
| **CM-2** (baseline config) | digest pinning (`pin-digests.sh`), SBOM inventory (`sbom.sh`), OSS approval (§2) |
| **CM-3/CM-5** (change control / access) | quadlet pin is a reviewed commit; push restricted (§4) |
| **CA-6 / CA-7 / PM-9** (authorization / continuous monitoring / risk) | accepted-risk record (§1), retained SBOM+scan evidence (§6) |
