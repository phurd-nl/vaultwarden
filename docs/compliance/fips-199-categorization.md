# FIPS 199 Security Categorization — NextVault

**System:** NextVault (hardened Vaultwarden fork) — internal corporate password
manager. **System type (per ADR-0001):** internal corporate, not a federal
system or cloud service offering. **Status:** DRAFT for system-owner / AO review.

FIPS 199 categorizes a system by the **potential impact** (Low / Moderate /
High) of a loss of **Confidentiality**, **Integrity**, and **Availability**.
NIST SP 800-60 maps information types to provisional impacts. The overall
categorization is the **high-water mark** of the three.

## 1. Information types stored

NextVault stores, for the organization's workforce:
- Account credentials for *other* systems (passwords, passphrases).
- TOTP/2FA seeds, security questions, recovery codes.
- Secure notes, attachments, and "Sends" (which may contain anything).
- Per-user E2E-encryption key material (`rsa_key.pem`, protected by each user's
  master password — see ADR-0005 and the Bitwarden zero-knowledge model).

This is, in effect, **a concentrated store of the credentials that protect the
rest of the enterprise.** That single fact drives the categorization below.

## 2. Impact analysis

### Confidentiality — **provisional: HIGH**  `[DECISION NEEDED — confirm]`
A breach of vault contents discloses the credentials guarding many other
systems, enabling lateral compromise across the enterprise. For a credential
store this is the textbook case for **High** confidentiality impact ("severe or
catastrophic adverse effect"). Mitigations (E2E encryption, master password,
LUKS at rest) *reduce likelihood*, but FIPS 199 categorizes by **impact if the
control fails**, not residual risk. Recommend **HIGH** unless the AO documents
why the credential set is low-value enough for Moderate.

### Integrity — **provisional: MODERATE**
Tampering with stored credentials could redirect users to attacker-controlled
values or deny access. Serious, but generally detectable and recoverable from
backups (CP-9/CP-10). E2E integrity and DB constraints limit silent tampering.
**Moderate** ("serious adverse effect").

### Availability — **provisional: MODERATE**
If NextVault is unavailable, users cannot retrieve credentials, disrupting
operations — but cached/active sessions and offline clients soften the blow, and
it is not life-safety. **Moderate**. (Drives the HA/standby and RTO/RPO work —
see `rto-rpo.md`. If the org deems the vault business-critical enough that an
outage halts operations, this could be argued **High**.)

## 3. Provisional categorization

```
SC(NextVault) = { (Confidentiality, HIGH*), (Integrity, MODERATE), (Availability, MODERATE) }
Overall (high-water mark) = HIGH*      *pending the confidentiality decision below
```

## 4. The decision that sets the baseline `[DECISION NEEDED]`

**The deployment was engineered to the 800-53B MODERATE baseline.** The analysis
above points at **HIGH confidentiality**, which would make the overall
categorization **HIGH** and pull in the High baseline (additional controls,
notably stronger SC, AU, CP, and AC requirements).

The system owner + AO must choose and **record the rationale**:

- **(A) Accept HIGH overall** (confidentiality = High). Most defensible for a
  credential store. Requires gap-assessing the current build against the High
  baseline (delta is real but not huge — much of SC/AU/CP is already strong).
- **(B) Categorize confidentiality MODERATE** and stay at the Moderate baseline.
  Defensible *only* with explicit documented justification (e.g. the vault holds
  only low-sensitivity, easily-rotated credentials for non-critical systems).
  For most orgs this is hard to justify for a password manager.

Until this is decided, treat the package as **Moderate-with-a-flagged-gap**: the
implemented controls satisfy Moderate, and the open question is whether High is
required.

## 5. Tailoring notes (apply after the baseline is fixed)

- **N/A (documented):** FedRAMP (not a federal cloud offering — ADR-0001);
  Kubernetes controls (rootless podman instead); client-cert DB auth (SCRAM+TLS
  chosen). Record each as a tailoring-out with rationale.
- **FIPS 140-2/3 cryptographic boundary:** `[DECISION NEEDED]` — define whether
  validated cryptographic modules are mandatory. Likely N/A for internal
  corporate, but the *decision memo* is currently missing and is required.
- **Privacy baseline:** `[DECISION NEEDED]` — confirm whether the vault holds
  PII triggering the NIST privacy controls.

## 6. Sign-off

| Role | Name | Decision (baseline) | Date | Signature |
|---|---|---|---|---|
| System Owner | `[OWNER]` | `[A: High / B: Moderate]` | | |
| Authorizing Official | `[AO]` | | | `[AO SIGNATURE]` |
