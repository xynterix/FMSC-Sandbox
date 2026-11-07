# Permanent schema-7 fixture

Place **only fictional and cleanly detached** files here:

- FMSC_DB.mdf
- FMSC_DB_log.ldf

Populate with comprehensive fictional school records **before the initial upload**. It must report dbo.DatabaseVersion = 7. CI must clone it and apply later migrations to the clone, never update these master files.
