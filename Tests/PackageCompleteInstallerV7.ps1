# Private Sandbox-only packager. Never runs in the public Source workflow.
# Inputs: the DB-free Source Workflow 03 artifact and frozen LFS fixture checkout.
param(
    [Parameter(Mandatory = $true)][string]$ArtifactRoot,
    [Parameter(Mandatory = $true)][string]$FixtureRoot,
    [Parameter(Mandatory = $true)][string]$SourceSha
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_REPOSITORY_ID -ne '1449162585') {
    throw 'Private v7 packaging is restricted to the FMSC-Sandbox repository.'
}
if ($SourceSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid pinned Source commit SHA.' }
$artifact = (Resolve-Path -LiteralPath $ArtifactRoot).Path
$fixture = (Resolve-Path -LiteralPath $FixtureRoot).Path
$manifestFile = Join-Path $fixture 'Tests/manifest.json'
if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) { throw 'Private fixture manifest missing.' }
$manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
if ($manifest.format -cne 'fmsc-sandbox-fixtures/v1') { throw 'Unknown fixture manifest format.' }
$matches = @($manifest.fixtures | Where-Object { $_.schema -eq 7 })
if ($matches.Count -ne 1) { throw 'Exactly one historical v7 fixture is required.' }
$entry = $matches[0]
if ($entry.id -cne 'fictional-v7' -or $entry.status -cne 'validated-schema-only' -or
    $entry.mdf -cne 'Database/v7/FMSC_DB.mdf' -or
    $entry.ldf -cne 'Database/v7/FMSC_DB_log.ldf') {
    throw 'Unexpected historical v7 fixture identity or status.'
}
$dbDir = Join-Path $artifact 'Database'
if (-not (Test-Path -LiteralPath $dbDir -PathType Container)) {
    throw 'Database placeholder directory is missing from Workflow 03.'
}
$readmeFile = Join-Path $artifact 'READ_ME_FIRST.txt'
if (-not (Test-Path -LiteralPath $readmeFile -PathType Leaf)) { throw 'Package README missing.' }
$readme = Get-Content -LiteralPath $readmeFile -Raw
if (-not $readme.Contains("Source commit: $SourceSha")) {
    throw 'Base artifact Source SHA differs from the exact pinned Source commit.'
}
$existing = @(Get-ChildItem -LiteralPath $artifact -Recurse -File |
    Where-Object { $_.Extension.ToLowerInvariant() -in @('.mdf','.ldf','.ndf','.bak','.bacpac','.dacpac') })
if ($existing.Count -ne 0) { throw 'Base artifact unexpectedly contains database files.' }

$pairs = @(
    @{ Path = 'Database/v7/FMSC_DB.mdf'; Name = 'FMSC_DB.mdf'; Sha = [string]$entry.mdfSha256 },
    @{ Path = 'Database/v7/FMSC_DB_log.ldf'; Name = 'FMSC_DB_log.ldf'; Sha = [string]$entry.ldfSha256 }
)
foreach ($pair in $pairs) {
    if ($pair.Sha -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid expected fixture checksum.' }
    $src = Join-Path $fixture $pair.Path
    $dst = Join-Path $dbDir $pair.Name
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Missing hydrated LFS file: $($pair.Name)" }
    if ((Get-Item -LiteralPath $src).Length -lt 4096) {
        throw "Git LFS pointer or truncated fixture detected: $($pair.Name)"
    }
    $actual = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $pair.Sha) { throw "Private fixture checksum mismatch: $($pair.Name)" }
    Copy-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pair.Sha) {
        throw "Copied fixture checksum mismatch: $($pair.Name)"
    }
    if ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pair.Sha) {
        throw "Frozen master changed during packaging: $($pair.Name)"
    }
}
$placeholder = Join-Path $dbDir 'PUT_MDF_AND_LDF_HERE.txt'
if (-not (Test-Path -LiteralPath $placeholder -PathType Leaf)) {
    throw 'Unexpected base installer packaging contract.'
}
Remove-Item -LiteralPath $placeholder -Force

$start = $readme.IndexOf('HOW TO PREPARE A FRESH INSTALL', [System.StringComparison]::Ordinal)
$end = $readme.IndexOf('APPLICATION UPDATE WITHOUT REPLACING A SCHOOL DATABASE', [System.StringComparison]::Ordinal)
if ($start -lt 0 -or $end -le $start) { throw 'Source installer instructions changed unexpectedly.' }
$readme = $readme.Replace(
    'FMSC_SMS - FULL Windows x64 installer folder (database files not included)',
    'FMSC_SMS - PRIVATE Windows x64 installer (frozen synthetic v7 database included)')
$start = $readme.IndexOf('HOW TO PREPARE A FRESH INSTALL', [System.StringComparison]::Ordinal)
$end = $readme.IndexOf('APPLICATION UPDATE WITHOUT REPLACING A SCHOOL DATABASE', [System.StringComparison]::Ordinal)
$instructions = @'
HOW TO INSTALL ON A FRESH PC
1. Extract this private GitHub Actions ZIP completely.
2. Both checksum-verified, DETACHED synthetic schema-7 files are already in
   Database\FMSC_DB.mdf and Database\FMSC_DB_log.ldf.
3. Double-click "FMSC.Setup.exe" and approve the administrator prompt.
4. The installer upgrades the v7 database through consecutive Source migrations.
5. Verify the resulting current schema and first-run school setup before use.

These are fictional EMPTY-SCHOOL test fixtures, not a school production backup.
This artifact must remain private. Never overwrite an existing school database.

'@
$readme = $readme.Substring(0, $start) + $instructions + $readme.Substring($end)
$readme = $readme.Replace(
    'For a fresh install, supply the latest compatible detached database pair.',
    'For a fresh install, the included synthetic v7 pair is migrated to the required schema.')
Set-Content -LiteralPath $readmeFile -Value $readme -Encoding utf8
@(
    'FMSC - frozen synthetic schema-v7 detached database pair'
    ''
    'This pair contains no real school records or account credentials.'
    'The pinned Sandbox fixture files were verified against Tests/manifest.json.'
    'They remain unchanged in the private Sandbox repository.'
    'Installer migrations initialize fresh-school reference data as required.'
    'Never replace the MDF/LDF of an existing FMSC installation with these files.'
    "Exact checked-out FMSC-Source commit: $SourceSha"
) | Set-Content -LiteralPath (Join-Path $dbDir 'README_SYNTHETIC_V7.txt') -Encoding utf8

$dbFiles = @(Get-ChildItem -LiteralPath $artifact -Recurse -File |
    Where-Object { $_.Extension.ToLowerInvariant() -in @('.mdf','.ldf','.ndf','.bak','.bacpac','.dacpac') })
if ($dbFiles.Count -ne 2) { throw 'Final installer contains an unexpected number of database files.' }
$names = @($dbFiles | ForEach-Object { [System.IO.Path]::GetRelativePath($artifact, $_.FullName).Replace('\','/') })
# PowerShell's culture-aware Sort-Object can put '_' before '.', so membership
# must be checked as an exact set, not by positions in a sorted array.
if ($names.Count -ne 2 -or
    -not ($names -ccontains 'Database/FMSC_DB.mdf') -or
    -not ($names -ccontains 'Database/FMSC_DB_log.ldf')) {
    throw 'Final installer database paths are not exactly the two expected files.'
}
$checksumFile = Join-Path $artifact 'SHA256SUMS.txt'
if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) { throw 'Base installer checksum file missing.' }
Remove-Item -LiteralPath $checksumFile -Force
$lines = @(Get-ChildItem -LiteralPath $artifact -Recurse -File | Sort-Object FullName | ForEach-Object {
    $relative = [System.IO.Path]::GetRelativePath($artifact, $_.FullName).Replace('\','/')
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
})
$lines | Set-Content -LiteralPath $checksumFile -Encoding utf8
Write-Host "PASS: private complete installer includes immutable synthetic v7 MDF/LDF at Source $SourceSha."
"Private installer: exact Source $SourceSha; frozen v7 MDF/LDF SHA-256 verified; files included only in Sandbox artifact." |
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
