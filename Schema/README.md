# Optional latest database schema

Place an inspection copy at Latest.dacpac, if desired. It may be refreshed independently of the permanent MDF/LDF test fixtures.

**Do not overwrite the schema-1 baseline** in FMSC-Source/Tests/LifecycleSqlChecks/Baseline/schema.dacpac. The latest DACPAC is for SQL schema inspection and comparison, not for reconstructing historical upgrade baselines.
