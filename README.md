# FMSC Sandbox

Private, **synthetic-only**, permanent SQL Server LocalDB test fixtures for the FMSC installer, updater, numbered migrations, rollback, and recovery.

## Permanent historical SQL files

- `Database/v3/FMSC_DB.mdf` and `Database/v3/FMSC_DB_log.ldf` — frozen schema-3 test baseline.
- `Database/v7/FMSC_DB.mdf` and `Database/v7/FMSC_DB_log.ldf` — frozen schema-7 test baseline.
- `Tests/manifest.json` — exact Git LFS file paths, schema versions, byte sizes, and SHA-256 checksums.
- `FMSC-schema-v3.zip` and `FMSC-schema-v7.zip` — retained original approved archives for recovery.

**Upload each master MDF/LDF pair only once.** On trusted disposable GitHub Windows runners, test jobs verify checksums, attach **copies**, verify physical schema versions, migrate copies, test backup/recovery and delete only disposable copies. Never upgrade master files. Future schema changes use new `Migrations/N.sql` in `FMSC-Source`, applied to copies; synthetic test records can be generated on copies by deterministic scripts. The permanent fixtures are currently mostly empty, not comprehensive fictional datasets.

## DACPAC policy

**FMSC-Sandbox does not store any DACPAC.** The owner may refresh `FMSC-Source/fmsc.dacpac` for developer/assistant **manual schema reading only**. No release, migration, installer, recovery, or fixture workflow may depend on that manually refreshed DACPAC, its modification date, or its contents. Test acceptance must use pinned, verified MDF/LDF copies and the numbered migration scripts. A separate historical schema test model may exist in FMSC-Source for independent PR smoke testing; it must never be confused with the owner-refreshed `fmsc.dacpac`.

## Security

- Only genuinely synthetic data; never add real or anonymized school records, credentials, passwords, or secrets.
- Keep masters detached/offline and immutable; never copy an attached SQL database file.
- Git LFS stores MDF/LDF; verify LFS materialization and exact SHA-256 before attaching a disposable copy.
- Cross-repository access must be **read only**, limited to trusted release jobs and pinned commits. Do not grant credentials to untrusted PR workflows.
- Never include any MDF/LDF/BAK or school records in public workflow artifacts or in the installer/application ZIP.
- Stop release publication if fixture validation, SQL migration, compatibility, cleanup, or the security gate fails.

The source-workflow integration lives in FMSC-Source; this repository contains immutable fixtures and private one-time integration tests only.
