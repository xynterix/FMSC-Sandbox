# One-time, owner-approved repair of the synthetic schema-7 historical fixture.
# Uses copies only; never attaches or edits the repository's original binaries.
param([Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data
$root = [IO.Path]::GetFullPath($FixtureRoot)
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:GITHUB_REPOSITORY_ID -cne '1449162585') {
    throw 'Refusing to repair outside the approved private GitHub Windows runner.'
}
$manifestPath = Join-Path $root 'Tests/manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.format -cne 'fmsc-sandbox-fixtures/v1') { throw 'Fixture manifest format mismatch.' }
$record = @($manifest.fixtures | Where-Object { $_.schema -eq 7 })
if ($record.Count -ne 1 -or $record[0].mdf -cne 'Database/v7/FMSC_DB.mdf' -or
    $record[0].ldf -cne 'Database/v7/FMSC_DB_log.ldf') { throw 'Unexpected historical v7 fixture identity.' }
$record = $record[0]
$expected = @(
    @{ Path=$record.mdf; Hash=$record.mdfSha256; Size=8388608 },
    @{ Path=$record.ldf; Hash=$record.ldfSha256; Size=75497472 }
)
$temp = Join-Path $env:RUNNER_TEMP ('fmsc-v7-typed-identity-' + $env:GITHUB_RUN_ID)
if (Test-Path -LiteralPath $temp) { throw 'Existing repair workspace; refusing overwrite.' }
New-Item -ItemType Directory -Path $temp | Out-Null
foreach ($entry in $expected) {
    $source = Join-Path $root $entry.Path
    $file = Get-Item -LiteralPath $source -ErrorAction Stop
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $file.Length -ne $entry.Size -or
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $entry.Hash) {
        throw "Original immutable fixture failed manifest verification: $($entry.Path)"
    }
    $dest = Join-Path $temp ([IO.Path]::GetFileName($source))
    Copy-Item -LiteralPath $source -Destination $dest
    (Get-Item -LiteralPath $dest).IsReadOnly = $false
}
$mdf = Join-Path $temp 'FMSC_DB.mdf'
$ldf = Join-Path $temp 'FMSC_DB_log.ldf'
$localDb = Get-Command SqlLocalDB.exe -ErrorAction SilentlyContinue
$exe = if ($localDb) { $localDb.Source } else {
    Join-Path $env:ProgramFiles 'Microsoft SQL Server/160/Tools/Binn/SqlLocalDB.exe'
}
if (-not (Test-Path -LiteralPath $exe)) { throw 'SQL Server 2022 LocalDB unavailable.' }
& $exe start MSSQLLocalDB | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'LocalDB failed to start.' }

function Invoke-Sql([string]$Database,[string]$Statement,[switch]$Scalar) {
    $connection = [System.Data.SqlClient.SqlConnection]::new(
        "Data Source=(localdb)\MSSQLLocalDB;Initial Catalog=$Database;Integrated Security=True;Encrypt=False;Connect Timeout=30")
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Statement
        $command.CommandTimeout = 180
        if ($Scalar) { return $command.ExecuteScalar() }
        [void]$command.ExecuteNonQuery()
    } finally {
        $connection.Dispose()
    }
}
function Attach([string]$name,[string]$data,[string]$log) {
    if ($name -cnotmatch '^[A-Za-z0-9_]+$') { throw 'Unsafe test catalog identifier.' }
    $dataSql = $data.Replace("'","''")
    $logSql = $log.Replace("'","''")
    Invoke-Sql 'master' "CREATE DATABASE [$name] ON (FILENAME=N'$dataSql'),(FILENAME=N'$logSql') FOR ATTACH;"
    $readOnly=[int](Invoke-Sql 'master' "SELECT is_read_only FROM sys.databases WHERE name=N'$name';" -Scalar)
    Write-Host "Attached disposable catalog $name; read-only status: $readOnly"
    if ($readOnly -eq 1) {
        Invoke-Sql 'master' "ALTER DATABASE [$name] SET READ_WRITE WITH ROLLBACK IMMEDIATE;"
        $readOnly=[int](Invoke-Sql 'master' "SELECT is_read_only FROM sys.databases WHERE name=N'$name';" -Scalar)
        if ($readOnly -ne 0) { throw 'Disposable database copy did not become writable.' }
    }
}
function Detach([string]$name) {
    Write-Host "Detaching disposable catalog $name"
    Invoke-Sql 'master' "ALTER DATABASE [$name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; EXEC sys.sp_detach_db @dbname=N'$name';"
}
$guard = @'
SET NOCOUNT ON;
IF TRY_CONVERT(int,(SELECT TOP(1) VersionNumber FROM dbo.DatabaseVersion ORDER BY VersionId DESC))<>7
 THROW 51010,'Database is not schema 7',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties
 WHERE class=0 AND major_id=0 AND minor_id=0 AND name=N'FMSC_DisposableFixture'
 AND TRY_CONVERT(nvarchar(100),value)=N'approved-synthetic-only')
 THROW 51011,'Not the approved synthetic fixture',1;
IF EXISTS(SELECT 1 FROM dbo.Students) OR EXISTS(SELECT 1 FROM dbo.Users)
 OR EXISTS(SELECT 1 FROM dbo.Staff) OR EXISTS(SELECT 1 FROM dbo.Families)
 OR EXISTS(SELECT 1 FROM dbo.FeePayments)
 THROW 51012,'Unexpected school or account data in synthetic fixture',1;
IF EXISTS(SELECT 1 FROM dbo.Roles) OR EXISTS(SELECT 1 FROM dbo.Permissions)
 OR EXISTS(SELECT 1 FROM dbo.AdmissionNumberCounter)
 THROW 51013,'Expected empty reference rows; leave initializers to migrations 15/16',1;
IF (SELECT COUNT(*) FROM sys.extended_properties
 WHERE class=0 AND major_id=0 AND minor_id=0 AND name=N'FMSC_QuickRegistrationScope')<>1
 THROW 51014,'Expected exactly one registration identity property',1;
IF TRY_CONVERT(uniqueidentifier,(SELECT value FROM sys.extended_properties
 WHERE class=0 AND major_id=0 AND minor_id=0 AND name=N'FMSC_QuickRegistrationScope')) IS NULL
 THROW 51015,'Historical registration identity cannot be preserved',1;
'@
$repair = @'
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @original uniqueidentifier = TRY_CONVERT(uniqueidentifier,
   (SELECT value FROM sys.extended_properties
    WHERE class=0 AND major_id=0 AND minor_id=0 AND name=N'FMSC_QuickRegistrationScope'));
 IF @original IS NULL OR @original='00000000-0000-0000-0000-000000000000'
  THROW 51016,'Historical recovery identity absent or invalid',1;
 EXEC sys.sp_updateextendedproperty @name=N'FMSC_QuickRegistrationScope',@value=@original;
 IF (SELECT SQL_VARIANT_PROPERTY(value,'BaseType') FROM sys.extended_properties
     WHERE class=0 AND major_id=0 AND minor_id=0 AND name=N'FMSC_QuickRegistrationScope')<>N'uniqueidentifier'
    OR (SELECT TRY_CONVERT(uniqueidentifier,value) FROM sys.extended_properties
     WHERE class=0 AND major_id=0 AND minor_id=0 AND name=N'FMSC_QuickRegistrationScope')<>@original
  THROW 51017,'Typed GUID preservation failed',1;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
'@
$verifyTyped = @'
SET NOCOUNT ON;
IF (SELECT SQL_VARIANT_PROPERTY(value,'BaseType') FROM sys.extended_properties
     WHERE class=0 AND major_id=0 AND minor_id=0 AND name=N'FMSC_QuickRegistrationScope')<>N'uniqueidentifier'
 THROW 51018,'Typed GUID did not survive detach/attach',1;
DBCC CHECKDB WITH NO_INFOMSGS;
'@
$name = 'FMSC_V7Repair_' + $env:GITHUB_RUN_ID
$attached = $false
try {
    Attach $name $mdf $ldf
    $attached = $true
    Write-Host "Checking schema-7 data-free and owner guards."
    Invoke-Sql $name $guard
    $before = [string](Invoke-Sql $name "SELECT CONVERT(nvarchar(36),TRY_CONVERT(uniqueidentifier,value)) FROM sys.extended_properties WHERE class=0 AND name=N'FMSC_QuickRegistrationScope';" -Scalar)
    Invoke-Sql $name 'DBCC CHECKDB WITH NO_INFOMSGS;'
    Invoke-Sql $name $repair
    Invoke-Sql $name $verifyTyped
    $after = [string](Invoke-Sql $name "SELECT CONVERT(nvarchar(36),value) FROM sys.extended_properties WHERE class=0 AND name=N'FMSC_QuickRegistrationScope';" -Scalar)
    if ($before -cne $after) { throw 'The historical GUID was changed.' }
} finally {
    if ($attached) { Detach $name }
}
# A second independent attach from the finalized detached files proves that
# the stored native SQL variant type survives a transfer to another computer.
$recheck = Join-Path $temp 'recheck'
New-Item -ItemType Directory -Path $recheck | Out-Null
$mdfCheck = Join-Path $recheck 'FMSC_DB.mdf'
$ldfCheck = Join-Path $recheck 'FMSC_DB_log.ldf'
Copy-Item -LiteralPath $mdf -Destination $mdfCheck
Copy-Item -LiteralPath $ldf -Destination $ldfCheck
$name2 = $name + '_check'
$attached2 = $false
try {
    Attach $name2 $mdfCheck $ldfCheck
    $attached2 = $true
    Invoke-Sql $name2 $guard
    Invoke-Sql $name2 $verifyTyped
    $persisted = [string](Invoke-Sql $name2 "SELECT CONVERT(nvarchar(36),value) FROM sys.extended_properties WHERE class=0 AND name=N'FMSC_QuickRegistrationScope';" -Scalar)
    if ($persisted -cne $before) { throw 'Reattached fixture lost its original identity.' }
} finally {
    if ($attached2) { Detach $name2 }
}
# Only now replace the checked-out branch files; no school database is touched.
$copy = @(@{file=$mdf;path=$record.mdf;field='mdfSha256';size=8388608},
          @{file=$ldf;path=$record.ldf;field='ldfSha256';size=75497472})
foreach ($item in $copy) {
    if ((Get-Item -LiteralPath $item.file).Length -ne $item.size) {
        throw 'Repair unexpectedly enlarged or truncated historical SQL files.'
    }
}
foreach ($item in $copy) {
    Copy-Item -LiteralPath $item.file -Destination (Join-Path $root $item.path) -Force
    $record.($item.field)=(Get-FileHash -LiteralPath (Join-Path $root $item.path) -Algorithm SHA256).Hash.ToLowerInvariant()
}
$record.status = 'validated-schema-only'
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
"Validated synthetic schema-7 native GUID identity, empty state, original GUID preservation, independent reattach, and CHECKDB." |
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
Write-Host 'REPAIRED SCHEMA-7 BINARY PAIR VERIFIED (not yet committed).'
