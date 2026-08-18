# EVO-005 — Exclude sensitive stores from Android backup

- Status: proposed
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: protected_apps (manifest + `res/xml`; no Dart/Kotlin logic)
- Commit: 5052d20
- Date: 2026-08-13
- Effort: S

## Why
`android/app/src/main/AndroidManifest.xml` declares no `android:allowBackup` and no
`android:dataExtractionRules`/`android:fullBackupContent`, so the default
(`allowBackup=true`) makes the Hive box `detoxo` (key `protected_apps` — the user's
manually protected banking/UPI/password apps) and `detoxo_engine_prefs` (key
`protected_packages`) eligible for Google cloud backup and device-to-device transfer.
`docs/code_docs/24-protected-apps.md` §6 promises "the list never leaves the device";
backup makes that claim technically false.

## Expected user impact
Invisible in daily use. Makes the privacy promise literally true: the inventory of a
user's sensitive apps never lands in a Google backup. Cost: after a reinstall-from-backup
the user's manual additions are gone (catalog protection is derived and unaffected).

## Technical complexity
Manifest attributes + one `res/xml/data_extraction_rules.xml` (and
`fullBackupContent` twin for API < 31). Decision inside the proposal: exclude only the
sensitive stores vs. `allowBackup=false` wholesale. No channel/storage schema changes.

## Performance impact
None — backup configuration only; nothing runs on the hot path or at startup.

## Business value
Backs the trust story in `docs/info_docs/01-product-overview.md` ("keeps what you see
and do private") and gives the Play data-safety listing (`22-play-release.md` §4) a
verifiable claim. Strengthens retention indirectly; peripheral to the intervention loop.

## Rejected alternative
Encrypting the protected-apps list at rest inside the backup instead of excluding it —
more code, still leaks existence/size, and Detoxo has no key-escrow story; exclusion is
the honest fix.

## Rollback
Remove the manifest attributes and the XML file. One-way-door note: none — no schema or
key changes; existing backups simply resume including the stores.

## Implementation Plan
<!-- Fill this section ONLY once Status: approved. -->
