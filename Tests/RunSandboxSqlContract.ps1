# Read-only fixture attestation harness. Runs only on GitHub-hosted Windows.
# It never attaches, edits, or uploads the immutable Git LFS fixtures.
param(
  [Parameter(Mandatory)][ValidateSet(3,7)][int]$Schema,
  [Parameter(Mandatory)][string]$SourceRoot,
  [Parameter(Mandatory)][string]$FixtureRoot
)
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted') {
  throw 'This SQL acceptance is restricted to disposable GitHub Windows runners.'
}
Add-Type -AssemblyName System.Data
$source=[IO.Path]::GetFullPath($SourceRoot)
$fixtures=[IO.Path]::GetFullPath($FixtureRoot)
$manifest=Get-Content -LiteralPath (Join-Path $fixtures 'Tests/manifest.json') -Raw | ConvertFrom-Json
if ($manifest.format -cne 'fmsc-sandbox-fixtures/v1') { throw 'Wrong pinned fixture manifest.' }
$entries=@($manifest.fixtures | Where-Object { $_.schema -eq $Schema })
if ($entries.Count -ne 1) { throw 'Expected exactly one fixture in manifest.' }
$entry=$entries[0]
if ($entry.mdf -cne "Database/v$Schema/FMSC_DB.mdf" -or
    $entry.ldf -cne "Database/v$Schema/FMSC_DB_log.ldf") { throw 'Unexpected fixture locations.' }
$root=Join-Path $env:LOCALAPPDATA "FMSC_SQL_Contract_$Schema"
$db="FMSC_SQL_Contract_$Schema"
if (Test-Path -LiteralPath $root) { throw 'Disposable database workspace already exists.' }
New-Item -ItemType Directory -Path $root | Out-Null
$attached=$false
function Query([string]$Database,[string]$Sql,[string]$Requirements='') {
  $conn=[System.Data.SqlClient.SqlConnection]::new("Data Source=(localdb)\MSSQLLocalDB;Initial Catalog=$Database;Integrated Security=True;Encrypt=False;Connect Timeout=30")
  try {
    $conn.Open()
    $cmd=$conn.CreateCommand()
    $cmd.CommandText=$Sql
    $cmd.CommandTimeout=180
    if ($Requirements) {
      [void]$cmd.Parameters.Add('@Requirements',[System.Data.SqlDbType]::NVarChar,-1)
      $cmd.Parameters['@Requirements'].Value=$Requirements
    }
    $ds=[System.Data.DataSet]::new()
    $adapter=[System.Data.SqlClient.SqlDataAdapter]::new($cmd)
    [void]$adapter.Fill($ds)
    return $ds
  } finally { $conn.Dispose() }
}
function Run([string]$database,[string]$sql) { [void](Query $database $sql) }
try {
  foreach ($p in @(
    @{path=$entry.mdf; sha=$entry.mdfSha256; bytes=8388608},
    @{path=$entry.ldf; sha=$entry.ldfSha256; bytes=75497472}
  )) {
    $origin=Join-Path $fixtures $p.path
    $original=Get-Item -LiteralPath $origin -ErrorAction Stop
    if (($original.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $original.Length -ne $p.bytes -or
        $p.sha -notmatch '^[0-9a-f]{64}$' -or
        (Get-FileHash -LiteralPath $origin -Algorithm SHA256).Hash -ine $p.sha) {
      throw 'Pinned fixture bytes do not match manifest and approved length.'
    }
    $dest=Join-Path $root ([IO.Path]::GetFileName($origin))
    Copy-Item -LiteralPath $origin -Destination $dest
    (Get-Item -LiteralPath $dest).IsReadOnly=$false
    if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ine $p.sha) {
      throw 'Working-copy hash mismatch.'
    }
    $handle=[IO.File]::Open($dest,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $handle.Dispose()
  }
  $localDb=Get-Command SqlLocalDB.exe -ErrorAction SilentlyContinue
  $exe=if ($localDb) { $localDb.Source } else {
    Join-Path $env:ProgramFiles 'Microsoft SQL Server/160/Tools/Binn/SqlLocalDB.exe'
  }
  if (-not (Test-Path -LiteralPath $exe)) { throw 'SQL LocalDB missing.' }
  for ($attempt=1;$attempt -le 3;$attempt++) {
    & $exe start MSSQLLocalDB | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq 3) { throw 'SQL LocalDB could not start after 3 attempts.' }
    Start-Sleep -Seconds 3
  }
  # GitHub-hosted Windows occasionally reports a successful LocalDB start
  # before MSSQLLocalDB accepts connections. Check actual SQL readiness, not
  # just the process exit code; still fail closed on persistent startup errors.
  $ready=$false
  for ($attempt=1;$attempt -le 4;$attempt++) {
    try {
      [void](Query master 'SELECT 1 AS Ready;')
      $ready=$true
      break
    } catch {
      if ($attempt -eq 4) {
        throw "Disposable LocalDB did not become queryable after 4 checks: $($_.Exception.Message)"
      }
      Start-Sleep -Seconds (2 * $attempt)
      & $exe start MSSQLLocalDB | Out-Null
    }
  }
  if (-not $ready) { throw 'Disposable LocalDB readiness was not established.' }
  $mdf=(Join-Path $root 'FMSC_DB.mdf').Replace("'","''")
  $ldf=(Join-Path $root 'FMSC_DB_log.ldf').Replace("'","''")
  Run master "CREATE DATABASE [$db] ON (FILENAME=N'$mdf'),(FILENAME=N'$ldf') FOR ATTACH;"
  $attached=$true
  $state=Query master "SELECT is_read_only FROM sys.databases WHERE name=N'$db';"
  if ([int]$state.Tables[0].Rows[0][0] -ne 0) { throw 'Disposable SQL fixture attached read-only.' }
  $version=Query $db 'SELECT TOP(1) TRY_CONVERT(int,VersionNumber) FROM dbo.DatabaseVersion ORDER BY VersionId DESC;'
  if ([int]$version.Tables[0].Rows[0][0] -ne $Schema) { throw 'Fixture schema/version mismatch.' }
  Run $db @'
SET NOCOUNT ON;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties
 WHERE class=0 AND major_id=0 AND name=N'FMSC_DisposableFixture'
 AND CONVERT(nvarchar(200),value)=N'approved-synthetic-only')
 THROW 51000,'Synthetic fixture ownership missing',1;
IF EXISTS(SELECT 1 FROM dbo.Students) OR EXISTS(SELECT 1 FROM dbo.Users)
 THROW 51001,'Fixture is not personal-data-free',1;
'@
  foreach ($name in @('dbo.Staff','dbo.Families','dbo.FamilyMembers','dbo.FeePayments',
    'dbo.Enrollments','dbo.StudentGuardianCommunication','comm.Contact',
    'comm.Message','comm.Campaign','comm.Attempt')) {
    $id=(Query $db "SELECT OBJECT_ID(N'$name',N'U');").Tables[0].Rows[0][0]
    if ($id -ne [DBNull]::Value) {
      Run $db "IF EXISTS(SELECT 1 FROM $name) THROW 51002,'Fixture has unexpected operational records',1;"
    }
  }
  Run $db 'DBCC CHECKDB WITH NO_INFOMSGS;'
  # Rebuild metadata that DacFx exports as text or omits from its data-free
  # model. This is seed-only test setup on the disposable copy.
  Run $db @'
SET NOCOUNT ON;
DECLARE @scope uniqueidentifier=NEWID();
IF EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N'FMSC_QuickRegistrationScope')
 EXEC sys.sp_updateextendedproperty @name=N'FMSC_QuickRegistrationScope',@value=@scope;
ELSE
 EXEC sys.sp_addextendedproperty @name=N'FMSC_QuickRegistrationScope',@value=@scope;
IF SQL_VARIANT_PROPERTY((SELECT value FROM sys.extended_properties WHERE class=0 AND name=N'FMSC_QuickRegistrationScope'),'BaseType')<>'uniqueidentifier'
 THROW 51003,'Registration GUID has wrong native type',1;
IF SCHEMA_ID(N'comm') IS NOT NULL
BEGIN
 IF OBJECT_ID(N'comm.Module',N'U') IS NULL OR OBJECT_ID(N'comm.Settings',N'U') IS NULL
   THROW 51004,'Communication bootstrap tables missing',1;
 IF NOT EXISTS(SELECT 1 FROM comm.Module) INSERT comm.Module(Version) VALUES(1);
 IF NOT EXISTS(SELECT 1 FROM comm.Settings)
   INSERT comm.Settings(Id,Mode,Paused,MaxBatch,ApprovalThreshold,HourLimit,DayLimit,
    DailyBudget,MonthlyBudget,SmsUnitCost,WhatsAppUnitCost,Currency,QuietStart,QuietEnd,
    UtcOffsetMinutes,RegistrationConfirmed,NextSendUtc,UpdatedBy,UpdatedUtc)
   VALUES(1,'Disabled',1,100,25,60,200,10,100,NULL,NULL,'USD',20,8,300,0,
    SYSUTCDATETIME(),NULL,SYSUTCDATETIME());
END;
'@
  $core=Get-Content -LiteralPath (Join-Path $source 'Installer/core.ps1') -Raw
  $versionMatch=[regex]::Match($core,'(?m)^\$DatabaseVersion = ''([0-9]+)''\r?$')
  if (-not $versionMatch.Success) { throw 'Cannot determine current required schema.' }
  $target=[int]$versionMatch.Groups[1].Value
  if ($target -lt 7) { throw 'Target schema unexpectedly below permanent v7 baseline.' }
  if ($Schema -lt $target) {
    for ($v=$Schema+1;$v -le $target;$v++) {
      $file=Join-Path $source "Migrations/$v.sql"
      $script=Get-Content -LiteralPath $file -Raw -ErrorAction Stop
      # Each batch uses the same SQL session via a single connection.
      $cn=[System.Data.SqlClient.SqlConnection]::new("Data Source=(localdb)\MSSQLLocalDB;Initial Catalog=$db;Integrated Security=True;Encrypt=False")
      try {
        $cn.Open()
        foreach ($batch in [regex]::Split($script,'(?im)^\s*GO\s*(?:--[^\r\n]*)?$')) {
          if ([string]::IsNullOrWhiteSpace($batch)) { continue }
          $cmd=$cn.CreateCommand()
          $cmd.CommandText=$batch
          $cmd.CommandTimeout=180
          [void]$cmd.ExecuteNonQuery()
        }
      } finally { $cn.Dispose() }
      $after=Query $db 'SELECT TOP(1) TRY_CONVERT(int,VersionNumber) FROM dbo.DatabaseVersion ORDER BY VersionId DESC;'
      if ([int]$after.Tables[0].Rows[0][0] -ne $v) { throw "Migration $v did not record expected version." }
      Write-Host "Schema $Schema migration $v PASS"
    }
  }
  # Exact production structural SQL/JSON, including all indexes, FKs,
  # checks, trigger events, parameters and typed recovery identity.
  $compat=Get-Content -LiteralPath (Join-Path $source 'Core/DatabaseCompatibility.cs') -Raw
  $m=[regex]::Match($compat,'(?s)using var command = new SqlCommand\("""\s*(.*?)\s*""", connection\)')
  if (-not $m.Success) { throw 'Production SQL compatibility query missing.' }
  $requirements=Get-Content -LiteralPath (Join-Path $source 'Core/DatabaseCompatibilityRequirements.json') -Raw
  $result=Query $db $m.Groups[1].Value $requirements
  if ($result.Tables.Count -lt 2 -or [int]$result.Tables[0].Rows[0][0] -ne 0) {
    throw "Complete base schema contract failed for schema-$Schema copy."
  }
  # Validate durable messaging safety contracts against the upgraded disposable
  # database. Do not require a historical C# class/file or parse its SQL text:
  # implementation files and UI layouts are not database acceptance contracts.
  if ($target -ge 9) {
    $structure=Query $db @'
SET NOCOUNT ON;
SELECT CASE WHEN
  SCHEMA_ID(N'msg') IS NOT NULL
  AND SCHEMA_ID(N'comm') IS NULL
  AND OBJECT_ID(N'dbo.StudentGuardianCommunication',N'U') IS NULL
  AND COL_LENGTH(N'dbo.Students',N'SchoolMessageConsent') IS NOT NULL
  AND OBJECT_ID(N'msg.ChannelSettings',N'U') IS NOT NULL
  AND OBJECT_ID(N'msg.Batch',N'U') IS NOT NULL
  AND OBJECT_ID(N'msg.Recipient',N'U') IS NOT NULL
  AND OBJECT_ID(N'msg.Attempt',N'U') IS NOT NULL
  AND OBJECT_ID(N'msg.Receipt',N'U') IS NOT NULL
  AND OBJECT_ID(N'msg.RecordAdmissionConsent',N'P') IS NOT NULL
  AND OBJECT_ID(N'msg.ConfirmBatch',N'P') IS NOT NULL
  AND OBJECT_ID(N'msg.ClaimRecipient',N'P') IS NOT NULL
THEN 1 ELSE 0 END;
'@
    if ([int]$structure.Tables[0].Rows[0][0] -ne 1) {
      throw 'Required schema-9 messaging/consent contracts are missing or legacy communication survived.'
    }
    $defaults=Query $db @'
SET NOCOUNT ON;
SELECT
  (SELECT COUNT(*) FROM msg.ChannelSettings WHERE Channel IN ('Sms','WhatsApp') AND Enabled=0) AS DisabledChannels,
  (SELECT COUNT(*) FROM msg.ChannelSettings WHERE Enabled<>0) AS ActiveChannels,
  (SELECT COUNT(*) FROM msg.Batch) AS Batches,
  (SELECT COUNT(*) FROM msg.Recipient) AS Recipients,
  (SELECT COUNT(*) FROM msg.Attempt) AS Attempts,
  (SELECT COUNT(*) FROM msg.Receipt) AS Receipts,
  (SELECT COUNT(*) FROM dbo.Students WHERE SchoolMessageConsent=1) AS ImpliedConsents;
'@
    $row=$defaults.Tables[0].Rows[0]
    if ([int]$row['DisabledChannels'] -ne 2 -or [int]$row['ActiveChannels'] -ne 0 -or
        [int]$row['Batches'] -ne 0 -or [int]$row['Recipients'] -ne 0 -or
        [int]$row['Attempts'] -ne 0 -or [int]$row['Receipts'] -ne 0 -or
        [int]$row['ImpliedConsents'] -ne 0) {
      throw 'Migration must not enable sending, create outbound work, or imply Admission consent.'
    }
    Write-Host "Schema $Schema -> $target messaging safety contracts PASS"
  }
  Run $db 'DBCC CHECKDB WITH NO_INFOMSGS;'
  Write-Host "PASS: immutable schema $Schema -> production schema $target; complete base and communication contracts"
} finally {
  try {
    if ($attached) {
      Run master "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; EXEC sys.sp_detach_db @dbname=N'$db';"
    }
  } finally {
    [System.Data.SqlClient.SqlConnection]::ClearAllPools()
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
  }
}
