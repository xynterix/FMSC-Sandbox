# FMSC Sandbox

Private, synthetic-only SQL Server LocalDB fixtures for FMSC installer, updater, migration, rollback and recovery testing.

## Permanent snapshots

- Database/v3/FMSC_DB.mdf + FMSC_DB_log.ldf — schema-3 historical upgrade baseline.
- Database/v7/FMSC_DB.mdf + FMSC_DB_log.ldf — schema-7 fully fictional school database for realistic upgrades.
- Schema/Latest.dacpac — optional latest-schema snapshot for inspection, not for recreating the historical baseline.
- Tests/manifest.json — schema expectations and metadata, initially marked pending.

**Upload each approved MDF/LDF pair once, not after every release.** CI takes independent copies, attaches only those copies, applies pending migrations to the copies, verifies data and cleanup, then discards the copies. The permanent fixture versions remain unchanged.

As database versions advance, CI can continue migrating copies of the schema-7 baseline through versions 8, 9, and later. Add more test situations using deterministic fictional-data seed scripts checked into the source repository, instead of replacing these binary fixtures.

## Safety

- Absolutely no real school information, passwords or authentic personal details: use only fictional data.
- Source files must be **cleanly detached / offline** before upload. Never copy an active attached MDF/LDF pair.
- MDF/LDF are tracked with Git LFS; install Git LFS before uploading them.
- CI must confirm SHA-256, real dbo.DatabaseVersion, safe paths, and disposable database identity before making changes.
- Private repository access should use a read-only token only in trusted workflows, never untrusted PR code.
- Preserve the separate schema-1 DACPAC baseline inside FMSC-Source unchanged. A refreshed Latest.dacpac is not the initial baseline.

The folders alone do not connect FMSC-Source workflows to these files; integration and permissions must be tested separately.
