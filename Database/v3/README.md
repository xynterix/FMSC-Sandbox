# Permanent synthetic schema-3 SQL fixture

The detached MDF/LDF pair is synthetic and data-free, not a production school database.
Its database schema remains **3**.

On the one-time guarded Windows SQL repair, the FMSC_QuickRegistrationScope property was checked and normalized to a native SQL uniqueidentifier. Result: text GUID converted to native uniqueidentifier. The native GUID, synthetic ownership marker, and schema version were independently verified on copied files after detach/reattach, with DBCC CHECKDB.

The updated file hashes are recorded in Tests/manifest.json. The original fixture remains recoverable from Git history. Keep the master files frozen after review and acceptance. Migrate and seed only disposable copies; never add school or credential data.
