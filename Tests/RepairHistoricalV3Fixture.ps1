# One-time synthetic schema-3 fixture repair. Never run against a school database.
# Repairs only checksum-verified disposable MDF/LDF copies on an approved Windows runner.
param([Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Data

if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:GITHUB_REPOSITORY_ID -cne '1449162585' -or
    $env:GITHUB_REPOSITORY_OWNER_ID -cne '316891609' -or
    $env:GITHUB_REF -cne 'refs/heads/maintenance/repair-v3-synthetic-fixture') {
    throw 'V3 REPAIR REFUSED: approved Sandbox branch on GitHub-hosted Windows required.'
}
$root=[IO.Path]::GetFullPath($FixtureRoot)
if ($root.TrimEnd('\') -ine (Join-Path $env:GITHUB_WORKSPACE 'fmsc-sandbox')) {
    throw 'V3 REPAIR REFUSED: unexpected fixture workspace.'
}
$manifestPath=Join-Path $root 'Tests/manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.format -cne 'fmsc-sandbox-fixtures/v1') { throw 'Wrong fixture manifest.' }
$matches=@($manifest.fixtures | Where-Object { $_.schema -eq 3 })
if ($matches.Count -ne 1 -or $matches[0].id -cne 'historical-v3' -or
    $matches[0].mdf -cne 'Database/v3/FMSC_DB.mdf' -or
    $matches[0].ldf -cne 'Database/v3/FMSC_DB_log.ldf') {
    throw 'Unexpected synthetic v3 fixture identity.'
}
$record=$matches[0]
$files=@(
    @{path=$record.mdf;sha=$record.mdfSha256;bytes=8388608;field='mdfSha256'},
    @{path=$record.ldf;sha=$record.ldfSha256;bytes=75497472;field='ldfSha256'}
)
$temp=Join-Path $env:LOCALAPPDATA ('FMSC_V3Repair_'+$env:GITHUB_RUN_ID)
if (Test-Path -LiteralPath $temp) { throw 'Repair workspace already exists.' }
New-Item -ItemType Directory -Path $temp | Out-Null
foreach ($file in $files) {
    $original=Join-Path $root $file.path
    $item=Get-Item -LiteralPath $original -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.Length -ne $file.bytes -or
        $file.sha -cnotmatch '^[a-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ine $file.sha) {
        throw "Refusing unexpected immutable fixture: $($file.path)"
    }
    $copy=Join-Path $temp ([IO.Path]::GetFileName($original))
    Copy-Item -LiteralPath $original -Destination $copy
    (Get-Item -LiteralPath $copy).IsReadOnly=$false
    if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ine $file.sha) {
        throw 'Working-copy hash differs from immutable fixture.'
    }
}
$localDb=Get-Command SqlLocalDB.exe -ErrorAction SilentlyContinue
$exe=if ($localDb) { $localDb.Source } else {
    Join-Path $env:ProgramFiles 'Microsoft SQL Server/160/Tools/Binn/SqlLocalDB.exe'
}
if (-not (Test-Path -LiteralPath $exe)) { throw 'SQL Server LocalDB missing.' }
for ($attempt=1;$attempt -le 3;$attempt++) {
    & $exe start MSSQLLocalDB | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq 3) { throw 'LocalDB could not start.' }
    Start-Sleep -Seconds 3
}
function Sql([string]$database,[string]$command,[switch]$Scalar) {
    $cn=[System.Data.SqlClient.SqlConnection]::new(
        "Data Source=(localdb)\MSSQLLocalDB;Initial Catalog=$database;Integrated Security=True;Encrypt=False;Connect Timeout=30")
    try {
        $cn.Open()
        $cmd=$cn.CreateCommand()
        $cmd.CommandText=$command
        $cmd.CommandTimeout=180
        if ($Scalar) { return $cmd.ExecuteScalar() }
        [void]$cmd.ExecuteNonQuery()
    } finally {
        $cn.Dispose()
    }
}
$ready=$false
for ($attempt=1;$attempt -le 4;$attempt++) {
    try { [void](Sql master 'SELECT 1;' -Scalar); $ready=$true; break }
    catch {
        if ($attempt -eq 4) { throw 'SQL LocalDB did not become queryable.' }
        Start-Sleep -Seconds (2*$attempt)
        & $exe start MSSQLLocalDB | Out-Null
    }
}
if (-not $ready) { throw 'SQL readiness was not established.' }
function Attach([string]$name,[string]$dir) {
    if ($name -cnotmatch '^FMSC_V3Repair_[A-Za-z0-9_]+$') { throw 'Unexpected disposable database name.' }
    $data=(Join-Path $dir 'FMSC_DB.mdf').Replace("'","''")
    $log=(Join-Path $dir 'FMSC_DB_log.ldf').Replace("'","''")
    Sql master "CREATE DATABASE [$name] ON (FILENAME=N'$data'),(FILENAME=N'$log') FOR ATTACH;"
    $readonly=[int](Sql master "SELECT is_read_only FROM sys.databases WHERE name=N'$name';" -Scalar)
    if ($readonly -eq 1) {
        Sql master "ALTER DATABASE [$name] SET READ_WRITE WITH ROLLBACK IMMEDIATE;"
    }
    if ([int](Sql master "SELECT is_read_only FROM sys.databases WHERE name=N'$name';" -Scalar) -ne 0) {
        throw 'Disposable database did not become writable.'
    }
}
function Detach([string]$name) {
    Sql master "ALTER DATABASE [$name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; EXEC sys.sp_detach_db @dbname=N'$name';"
}
function Guard([string]$database) {
    Sql $database @'
SET NOCOUNT ON;
IF NOT EXISTS(SELECT 1 FROM dbo.DatabaseVersion HAVING COUNT(*)>0) OR
  TRY_CONVERT(int,(SELECT TOP(1) VersionNumber FROM dbo.DatabaseVersion ORDER BY VersionId DESC))<>3
 THROW 51010,'Expected schema-3 snapshot',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND major_id=0
 AND minor_id=0 AND name=N'FMSC_DisposableFixture'
 AND TRY_CONVERT(nvarchar(100),value)=N'approved-synthetic-only')
 THROW 51011,'Fixture synthetic ownership not proved',1;
'@
    foreach ($table in @('dbo.Students','dbo.Users','dbo.Staff','dbo.Families',
      'dbo.FamilyMembers','dbo.Enrollments','dbo.FeePayments','dbo.FeeBills',
      'dbo.Roles','dbo.Permissions','dbo.AdmissionNumberCounter',
      'comm.Contact','comm.Message','comm.Campaign','comm.Attempt')) {
        $obj=Sql $database "SELECT OBJECT_ID(N'$table',N'U');" -Scalar
        if ($null -ne $obj -and $obj -ne [DBNull]::Value) {
            Sql $database "IF EXISTS (SELECT 1 FROM $table) THROW 51012,'Nonempty synthetic fixture table: $table',1;"
        }
    }
    Sql $database 'DBCC CHECKDB WITH NO_INFOMSGS;'
}
function Identity([string]$database) {
    return [string](Sql $database @'
SELECT CONCAT(CONVERT(nvarchar(30),SQL_VARIANT_PROPERTY(value,'BaseType')),
 '|',COALESCE(CONVERT(nvarchar(36),TRY_CONVERT(uniqueidentifier,value)),N'INVALID'))
FROM sys.extended_properties
WHERE class=0 AND major_id=0 AND minor_id=0 AND name=N'FMSC_QuickRegistrationScope';
'@ -Scalar)
}
$base='FMSC_V3Repair_'+$env:GITHUB_RUN_ID
$mdf=Join-Path $temp 'FMSC_DB.mdf'
$ldf=Join-Path $temp 'FMSC_DB_log.ldf'
$attached=$false
$before=''
$after=''
$generated=$false
try {
    Attach $base $temp
    $attached=$true
    Guard $base
    $before=Identity $base
    if ($before -and $before -notmatch '^[A-Za-z0-9_]+\|[0-9a-fA-F-]{36}$') {
        throw 'Refusing missing or malformed historical GUID.'
    }
    if ($before -match '\|00000000-0000-0000-0000-000000000000$') {
        throw 'Refusing zero historical GUID.'
    }
    Sql $base @'
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @count int=(SELECT COUNT(*) FROM sys.extended_properties
   WHERE class=0 AND major_id=0 AND minor_id=0 AND name=N'FMSC_QuickRegistrationScope');
 IF @count>1 THROW 51013,'Ambiguous recovery identity property',1;
 DECLARE @scope uniqueidentifier;
 IF @count=0
 BEGIN
   SET @scope=NEWID();
   EXEC sys.sp_addextendedproperty @name=N'FMSC_QuickRegistrationScope',@value=@scope;
 END
 ELSE
 BEGIN
   SELECT @scope=TRY_CONVERT(uniqueidentifier,value)
   FROM sys.extended_properties WHERE class=0 AND name=N'FMSC_QuickRegistrationScope';
   IF @scope IS NULL OR @scope='00000000-0000-0000-0000-000000000000'
      THROW 51014,'Invalid recovery identity: original must be preserved',1;
   EXEC sys.sp_updateextendedproperty @name=N'FMSC_QuickRegistrationScope',@value=@scope;
 END;
 IF (SELECT SQL_VARIANT_PROPERTY(value,'BaseType')
   FROM sys.extended_properties WHERE class=0 AND name=N'FMSC_QuickRegistrationScope')<>N'uniqueidentifier'
   THROW 51015,'Native SQL GUID type repair failed',1;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
'@
    Guard $base
    $after=Identity $base
    if ($after -cnotmatch '^uniqueidentifier\|[0-9a-fA-F-]{36}$') {
        throw 'Native typed GUID did not survive repair.'
    }
    if ($before) {
        if (($before -split '\|')[-1] -ine ($after -split '\|')[-1]) {
            throw 'Repair changed the original GUID.'
        }
    } else { $generated=$true }
} finally {
    if ($attached) { Detach $base }
}
$recheck=Join-Path $temp 'recheck'
New-Item -ItemType Directory -Path $recheck | Out-Null
Copy-Item -LiteralPath $mdf -Destination (Join-Path $recheck 'FMSC_DB.mdf')
Copy-Item -LiteralPath $ldf -Destination (Join-Path $recheck 'FMSC_DB_log.ldf')
$checkName=$base+'_check'
$attached=$false
try {
    Attach $checkName $recheck
    $attached=$true
    Guard $checkName
    $persisted=Identity $checkName
    if ($persisted -cne $after) { throw 'Independent reattach changed stored GUID or native type.' }
} finally {
    if ($attached) { Detach $checkName }
}
# All checks succeeded. Only write to branch checkout, never the original revision.
foreach ($file in $files) {
    $from=Join-Path $temp ([IO.Path]::GetFileName($file.path))
    if ((Get-Item -LiteralPath $from).Length -ne $file.bytes) {
        throw 'Repair changed MDF/LDF file length outside approved limits.'
    }
}
foreach ($file in $files) {
    $from=Join-Path $temp ([IO.Path]::GetFileName($file.path))
    $to=Join-Path $root $file.path
    Copy-Item -LiteralPath $from -Destination $to -Force
    $record.($file.field)=(Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash.ToLowerInvariant()
}
$record.status='validated-schema-only'
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$source=if ($generated) {'missing: generated a new synthetic GUID'} elseif ($before -match '^uniqueidentifier\|') {'already native GUID'} else {'text GUID converted to native uniqueidentifier'}
$readme=Join-Path $root 'Database/v3/README.md'
@"
# Permanent synthetic schema-3 SQL fixture

The detached MDF/LDF pair is synthetic and data-free, not a production school database.
Its database schema remains **3**.

On the one-time guarded Windows SQL repair, the FMSC_QuickRegistrationScope property was checked and normalized to a native SQL uniqueidentifier. Result: $source. The native GUID, synthetic ownership marker, and schema version were independently verified on copied files after detach/reattach, with DBCC CHECKDB.

The updated file hashes are recorded in Tests/manifest.json. The original fixture remains recoverable from Git history. Keep the master files frozen after review and acceptance. Migrate and seed only disposable copies; never add school or credential data.
"@ | Set-Content -LiteralPath $readme -Encoding utf8
"V3 repaired on isolated disposable files. Identity: $source. Original master untouched. Independent reattach and CHECKDB passed." |
  Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
Write-Host 'SCHEMA-3 PAIR VERIFIED AND STAGED IN WORKTREE (not committed).'
