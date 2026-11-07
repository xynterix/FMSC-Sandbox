# Synthetic-only release chaos rehearsal. Never use with a real FMSC installation.
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -cne 'farhan2166-creator/FMSC-Sandbox' -or
    $env:FMSC_DISPOSABLE_INSTALL -cne 'approved-synthetic-only') {
    throw 'CHAOS REFUSED: private synthetic GitHub-hosted Windows runner required.'
}
$workspace=[IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\')
$source=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$fixtures=[IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')
if ($source -ine (Join-Path $workspace 'fmsc-source') -or
    $fixtures -ine (Join-Path $workspace 'fmsc-sandbox')) {
    throw 'CHAOS REFUSED: unrecognized Source or fixture checkout.'
}
$manifest=Get-Content (Join-Path $fixtures 'Tests/manifest.json') -Raw | ConvertFrom-Json
$entry=@($manifest.fixtures | Where-Object { $_.schema -eq 3 })
if ($manifest.format -cne 'fmsc-sandbox-fixtures/v1' -or $entry.Count -ne 1 -or
    $entry[0].mdf -cne 'Database/v3/FMSC_DB.mdf' -or
    $entry[0].ldf -cne 'Database/v3/FMSC_DB_log.ldf') {
    throw 'CHAOS REFUSED: unexpected immutable schema-3 fixture.'
}
$files=@(
    @{path=$entry[0].mdf;sha=$entry[0].mdfSha256;size=8388608},
    @{path=$entry[0].ldf;sha=$entry[0].ldfSha256;size=75497472}
)
foreach ($f in $files) {
    $p=Join-Path $fixtures $f.path
    $item=Get-Item -LiteralPath $p -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.Length -ne $f.size -or $f.sha -notmatch '^[a-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ine $f.sha) {
        throw 'CHAOS REFUSED: original fixture checksum, size or location invalid.'
    }
}
$version=[regex]::Match((Get-Content (Join-Path $source 'DatabaseHelper.cs') -Raw),
    'RequiredDatabaseSchemaVersion\s*=\s*"([0-9]+)"')
if (-not $version.Success -or [int]$version.Groups[1].Value -ne 7) {
    throw 'CHAOS REFUSED: this fixed test requires Source schema 7.'
}
$id=[guid]::NewGuid().ToString('N')
$db='FMSC_Chaos_'+$id
$restore=$db+'_Restored'
$root=Join-Path $env:LOCALAPPDATA ('FMSC_Chaos_'+$id)
$harness=Join-Path $env:RUNNER_TEMP ('fmsc-chaos-harness-'+$id)
$backups=Join-Path $root 'Backups'
$ownsRoot=$false;$ownsHarness=$false;$attached=$false;$restored=$false
Add-Type -AssemblyName System.Data
function Need([bool]$OK,[string]$Why) { if (-not $OK) { throw ('CHAOS FAIL: '+$Why) } }
function Quote([string]$s) { return $s.Replace("'","''") }
function Sql([string]$dbName,[string]$text,[string]$requirements='') {
    $cn=[System.Data.SqlClient.SqlConnection]::new(
        "Data Source=(localdb)\MSSQLLocalDB;Initial Catalog=$dbName;Integrated Security=True;Encrypt=False;Connect Timeout=30")
    try {
        $cn.Open();$cmd=$cn.CreateCommand();$cmd.CommandText=$text;$cmd.CommandTimeout=180
        if ($requirements) {
            [void]$cmd.Parameters.Add('@Requirements',[System.Data.SqlDbType]::NVarChar,-1)
            $cmd.Parameters['@Requirements'].Value=$requirements
        }
        $ds=[System.Data.DataSet]::new()
        $da=[System.Data.SqlClient.SqlDataAdapter]::new($cmd)
        [void]$da.Fill($ds)
        return ,$ds
    } finally { $cn.Dispose() }
}
function DoSql([string]$d,[string]$q) { [void](Sql $d $q) }
function DbVersion([string]$d) {
    $ds=Sql $d 'SELECT TOP(1) TRY_CONVERT(int,VersionNumber) FROM dbo.DatabaseVersion ORDER BY VersionId DESC;'
    Need ($ds.Tables.Count -eq 1 -and $ds.Tables[0].Rows.Count -eq 1 -and
        $ds.Tables[0].Rows[0][0] -ne [DBNull]::Value) 'Database schema version unreadable.'
    return [int]$ds.Tables[0].Rows[0][0]
}
function ProbeExists {
    return [int](Sql $db "SELECT CASE WHEN OBJECT_ID(N'dbo.FMSC_ChaosTransient',N'U') IS NULL THEN 0 ELSE 1 END;").Tables[0].Rows[0][0]
}
function AssertOwned([string]$catalog) {
    Need ($catalog -ceq $db -or $catalog -ceq $restore) 'Attempted SQL cleanup of an unowned catalog.'
    $data=Sql master "SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID(N'$catalog');"
    Need ($data.Tables[0].Rows.Count -eq 2) 'Cannot prove two owned SQL files.'
    foreach ($row in $data.Tables[0].Rows) {
        $full=[IO.Path]::GetFullPath([string]$row[0])
        Need ($full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) 'Database outside disposable directory.'
    }
    $marker=Sql $catalog "SELECT CONVERT(nvarchar(200),value) FROM sys.extended_properties WHERE class=0 AND name=N'FMSC_DisposableFixture';"
    Need ($marker.Tables[0].Rows.Count -eq 1 -and
        [string]$marker.Tables[0].Rows[0][0] -ceq 'approved-synthetic-only') 'Synthetic ownership marker missing.'
}
function DropOwned([string]$catalog) {
    AssertOwned $catalog
    [System.Data.SqlClient.SqlConnection]::ClearAllPools()
    DoSql master "ALTER DATABASE [$catalog] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$catalog];"
}
function Apply([string]$scenario) {
    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output=@(& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:applier
        -SqlInstance $script:pipe -DatabaseName $db -BackupRoot $backups
        -SqlCmdPath $script:sqlcmd -Apply 2>&1 | ForEach-Object { [string]$_ })
    $exitCode=[int]$LASTEXITCODE
    Write-Host "CHAOS SCENARIO: $scenario / migration runner exit $exitCode"
    return [pscustomobject]@{ExitCode=$exitCode;Output=($output -join [Environment]::NewLine)}
}
function VerifyBackup([string]$path) {
    Need ((Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Item -LiteralPath $path).Length -gt 0) 'Recovery backup missing or empty.'
    DoSql master ("RESTORE VERIFYONLY FROM DISK=N'"+(Quote $path)+"' WITH CHECKSUM;")
}
try {
    Need (-not (Test-Path $root) -and -not (Test-Path $harness)) 'Disposable workspace already exists.'
    New-Item -ItemType Directory -Path $root,$harness,$backups,(Join-Path $harness 'Migrations'),(Join-Path $harness 'Installer') -Force | Out-Null
    $ownsRoot=$true;$ownsHarness=$true
    foreach ($f in $files) {
        $origin=Join-Path $fixtures $f.path
        $target=Join-Path $root ([IO.Path]::GetFileName($origin))
        Copy-Item -LiteralPath $origin -Destination $target
        (Get-Item $target).IsReadOnly=$false
        Need ((Get-FileHash $target -Algorithm SHA256).Hash -ieq $f.sha) 'Writable copy differs from verified immutable source.'
    }
    Copy-Item (Join-Path $source 'DatabaseHelper.cs') -Destination $harness
    Copy-Item (Join-Path $source 'Installer/core.ps1') -Destination (Join-Path $harness 'Installer/core.ps1')
    Copy-Item (Join-Path $source 'Migrations/Apply-Migrations.ps1') -Destination (Join-Path $harness 'Migrations/Apply-Migrations.ps1')
    foreach ($v in 4..7) { Copy-Item (Join-Path $source "Migrations/$v.sql") -Destination (Join-Path $harness "Migrations/$v.sql") }
    $script:applier=Join-Path $harness 'Migrations/Apply-Migrations.ps1'
    $script:sqlcmd=Join-Path $harness 'sqlcmd.exe'
    & (Join-Path $source 'Tools/PrepareBundledSqlCmd.ps1') -DestinationFile $script:sqlcmd
    Need ((Test-Path $script:sqlcmd -PathType Leaf) -and (Get-Item $script:sqlcmd).Length -gt 100000) 'Pinned sqlcmd not installed.'
    $local=Get-Command SqlLocalDB.exe -ErrorAction SilentlyContinue
    $localExe=if ($local) {$local.Source} else {Join-Path $env:ProgramFiles 'Microsoft SQL Server\160\Tools\Binn\SqlLocalDB.exe'}
    Need (Test-Path $localExe) 'SQL LocalDB missing.'
    & $localExe start MSSQLLocalDB | Out-Null
    Need ($LASTEXITCODE -eq 0) 'LocalDB failed to start.'
    $info=@(& $localExe info MSSQLLocalDB 2>&1)
    $pipeMatch=[regex]::Match(($info -join [Environment]::NewLine),
        '(?:np:)?(\\\.\\pipe\\LOCALDB#[A-Za-z0-9]+\\tsql\\query)')
    Need $pipeMatch.Success 'Could not resolve LocalDB named pipe.'
    $script:pipe='np:'+$pipeMatch.Groups[1].Value
    $mdf=Quote (Join-Path $root 'FMSC_DB.mdf')
    $ldf=Quote (Join-Path $root 'FMSC_DB_log.ldf')
    DoSql master "CREATE DATABASE [$db] ON (FILENAME=N'$mdf'),(FILENAME=N'$ldf') FOR ATTACH;"
    $attached=$true
    AssertOwned $db
    Need ((DbVersion $db) -eq 3) 'Source fixture does not have schema 3.'
    DoSql $db @'
SET NOCOUNT ON;
IF EXISTS(SELECT 1 FROM dbo.Students) OR EXISTS(SELECT 1 FROM dbo.Users)
 THROW 51001,'Non-synthetic data detected',1;
DBCC CHECKDB WITH NO_INFOMSGS;
DECLARE @scope uniqueidentifier=NEWID();
IF EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N'FMSC_QuickRegistrationScope')
 EXEC sys.sp_updateextendedproperty @name=N'FMSC_QuickRegistrationScope',@value=@scope;
ELSE EXEC sys.sp_addextendedproperty @name=N'FMSC_QuickRegistrationScope',@value=@scope;
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
    Write-Host 'CHAOS: checksum-verified historical schema 3 copied and validated; original fixture untouched.'
    # Missing numbered SQL must not run anything, or even create a recovery backup.
    $four=Join-Path $harness 'Migrations/4.sql'
    Move-Item -LiteralPath $four -Destination "$four.held"
    $missing=Apply 'missing migration 4'
    Need ($missing.ExitCode -ne 0 -and $missing.Output.Contains('Missing required migration 4.sql')) 'Missing migration was not correctly refused.'
    Need ((DbVersion $db) -eq 3 -and @(Get-ChildItem $backups -Filter '*.bak' -File).Count -eq 0) 'Missing SQL changed version or created backup.'
    Move-Item -LiteralPath "$four.held" -Destination $four
    # Break inside the per-migration SQL transaction AFTER a DDL statement.
    [IO.File]::WriteAllText($four,("CREATE TABLE dbo.FMSC_ChaosTransient(Id int NOT NULL);"+[Environment]::NewLine+
        "THROW 51000,'Deliberate sandbox migration 4 failure',1;"),[Text.UTF8Encoding]::new($false))
    $bad4=Apply 'transactional SQL failure at migration 4'
    Need ($bad4.ExitCode -ne 0 -and $bad4.Output.Contains('Migration 4 failed')) 'Injected migration 4 SQL failure was not reached.'
    Need ((DbVersion $db) -eq 3 -and (ProbeExists) -eq 0) 'Failed migration 4 left DDL or changed schema marker.'
    $first=@(Get-ChildItem $backups -Filter '*.bak' -File | Sort-Object CreationTimeUtc | Select-Object -First 1)
    Need ($first.Count -eq 1) 'Failed migration 4 did not preserve its pre-migration backup.'
    VerifyBackup $first[0].FullName
    $backupHash=(Get-FileHash $first[0].FullName -Algorithm SHA256).Hash
    Copy-Item (Join-Path $source 'Migrations/4.sql') -Destination $four -Force
    # Commit true migration 4, then fail migration 5; no partial 5 may survive.
    $five=Join-Path $harness 'Migrations/5.sql'
    [IO.File]::WriteAllText($five,("CREATE TABLE dbo.FMSC_ChaosTransient(Id int NOT NULL);"+[Environment]::NewLine+
        "THROW 51000,'Deliberate sandbox migration 5 failure',1;"),[Text.UTF8Encoding]::new($false))
    $bad5=Apply 'real migration 4 then failing migration 5'
    Need ($bad5.ExitCode -ne 0 -and $bad5.Output.Contains('Migration 5 failed')) 'Injected migration 5 SQL failure was not reached.'
    Need ((DbVersion $db) -eq 4 -and (ProbeExists) -eq 0) 'Fault after genuine migration 4 left partial migration 5.'
    VerifyBackup $first[0].FullName
    Need ((Get-FileHash $first[0].FullName -Algorithm SHA256).Hash -eq $backupHash) 'Original backup changed.'
    Copy-Item (Join-Path $source 'Migrations/5.sql') -Destination $five -Force
    $resume=Apply 'resume official migrations 5 through 7'
    Need ($resume.ExitCode -eq 0 -and (DbVersion $db) -eq 7) 'Original migrations did not recover to schema 7.'
    $raw=Get-Content (Join-Path $source 'Core/DatabaseCompatibility.cs') -Raw
    $sqlContract=[regex]::Match($raw,'(?s)using var command = new SqlCommand\("""\s*(.*?)\s*""", connection\)')
    Need $sqlContract.Success 'Production SQL contract not found.'
    $requirements=Get-Content (Join-Path $source 'Core/DatabaseCompatibilityRequirements.json') -Raw
    $result=Sql $db $sqlContract.Groups[1].Value $requirements
    Need ($result.Tables.Count -ge 2 -and [int]$result.Tables[0].Rows[0][0] -eq 0) 'Post-recovery production compatibility failed.'
    DoSql $db 'DBCC CHECKDB WITH NO_INFOMSGS;'
    # Restore original checksum-verified backup into a SECOND unique catalog.
    $list=Sql master ("RESTORE FILELISTONLY FROM DISK=N'"+(Quote $first[0].FullName)+"';")
    $data=@($list.Tables[0].Rows | Where-Object { [string]$_['Type'] -eq 'D' })
    $log=@($list.Tables[0].Rows | Where-Object { [string]$_['Type'] -eq 'L' })
    Need ($data.Count -eq 1 -and $log.Count -eq 1) 'Backup has unexpected logical file count.'
    $restoreMdf=Quote (Join-Path $root 'restored.mdf')
    $restoreLdf=Quote (Join-Path $root 'restored_log.ldf')
    $sqlRestore="RESTORE DATABASE [$restore] FROM DISK=N'"+(Quote $first[0].FullName)+
        "' WITH MOVE N'"+(Quote ([string]$data[0]['LogicalName']))+"' TO N'$restoreMdf', MOVE N'"+
        (Quote ([string]$log[0]['LogicalName']))+"' TO N'$restoreLdf', CHECKSUM, RECOVERY;"
    DoSql master $sqlRestore
    $restored=$true
    AssertOwned $restore
    Need ((DbVersion $restore) -eq 3 -and (DbVersion $db) -eq 7) 'Backup restore did not reproduce schema 3 independently.'
    DoSql $restore 'DBCC CHECKDB WITH NO_INFOMSGS;'
    Write-Host 'PASS: missing file refused, migration 4 and 5 faults rolled back, original scripts resumed, production contract passed, original backup restored at schema 3.'
    if ($env:GITHUB_STEP_SUMMARY) {
        @('# Historical private migration chaos: PASS','',
          '- Missing intermediate migration rejected before backup/mutation',
          '- Injected schema-4 DDL fault rolled back; schema marker remained 3',
          '- Genuine schema 4 committed; injected schema-5 fault rolled back',
          '- Original scripts resumed through schema 7; full compatibility/DBCC passed',
          '- Original SHA-256-verified backup restored to distinct schema-3 catalog',
          '- No attestation, release publication or permanent fixture mutation') |
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }
} finally {
    try {
        if ($restored) { DropOwned $restore }
        if ($attached) { DropOwned $db }
        foreach ($f in $files) {
            Need ((Get-FileHash (Join-Path $fixtures $f.path) -Algorithm SHA256).Hash -ieq $f.sha) 'Original LFS fixture checksum changed.'
        }
        if ($ownsRoot) { Remove-Item -LiteralPath $root -Recurse -Force }
        if ($ownsHarness) { Remove-Item -LiteralPath $harness -Recurse -Force }
    } catch {
        throw ('CHAOS CLEANUP FAILED; no unowned SQL database was touched: '+$_.Exception.Message)
    }
}