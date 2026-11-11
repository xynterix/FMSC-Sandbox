# Permanent synthetic schema-7 SQL fixture

The detached `FMSC_DB.mdf` and `FMSC_DB_log.ldf` are **synthetic and data-free**, not a school production backup. Schema version remains **7**.

On 2026-11-10 a one-time Windows SQL repair was validated against copies, then uploaded with Git LFS after an independent reattach/DBCC check, complete migration SQL contract and real Windows installer/update/rollback acceptance. The repair preserved the existing `FMSC_QuickRegistrationScope` GUID while changing its native SQL-variant base type from `varchar` to `uniqueidentifier`.

**Do not seed Administrator, Accountant, permissions, admission counters or billing settings in this historical file.** Production migrations 15 and 16 initialize first-run reference data when the empty schema-7 fixture is upgraded. The permanent fixture must stay empty of real users, students, credentials and operational school records.

The earlier historical fixture revisions remain recoverable from Git history. The approved repaired binary hashes are recorded in `Tests/manifest.json`. Treat this pair as frozen after acceptance: future migrations and synthetic records belong on **disposable copies**, never in the permanent files.
