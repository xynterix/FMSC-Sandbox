# Hydrate only one immutable synthetic MDF/LDF pair after a credential-free checkout.
# No credentials are written to Git config, and the original fixture is never modified.
param(
    [Parameter(Mandatory)][ValidateSet(3, 7)][int]$Schema,
    [Parameter(Mandatory)][string]$FixtureRoot
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:GITHUB_REPOSITORY_ID -cne '1449162585' -or
    $env:GITHUB_REPOSITORY_OWNER_ID -cne '316891609' -or
    -not $env:FMSC_FIXTURE_READ_TOKEN) {
    throw 'Fixture hydration requires a private GitHub-hosted Windows Sandbox job and a scoped read token.'
}
$root = [IO.Path]::GetFullPath($FixtureRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not $root.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture checkout must be an isolated directory inside the runner workspace.'
}
$pin = '7d225d2b8e38aecd4a1c3cfa7ccfaf56685149b9'
$head = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne $pin) { throw 'Refusing unpinned fixture checkout.' }
$manifest = Get-Content -LiteralPath (Join-Path $root 'Tests/manifest.json') -Raw | ConvertFrom-Json
if ($manifest.format -cne 'fmsc-sandbox-fixtures/v1') { throw 'Unrecognized fixture manifest.' }
$entries = @($manifest.fixtures | Where-Object { $_.schema -eq $Schema })
if ($entries.Count -ne 1) { throw 'Expected exactly one pinned schema fixture.' }
$entry = $entries[0]
if ($entry.mdf -cne "Database/v$Schema/FMSC_DB.mdf" -or
    $entry.ldf -cne "Database/v$Schema/FMSC_DB_log.ldf") {
    throw 'Unexpected fixture paths.'
}
# Checkout has lfs:false and persist-credentials:false. The temporary -c header
# is process-scoped, never persisted in the repo for later untrusted source steps.
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$env:FMSC_FIXTURE_READ_TOKEN"))
try {
    & git -C $root -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic" lfs pull --include="Database/v$Schema/*" --exclude=''
    if ($LASTEXITCODE -ne 0) { throw 'Selective Git LFS download failed.' }
} finally {
    $basic = $null
}
foreach ($file in @(
    @{Path=$entry.mdf; Sha=$entry.mdfSha256; Bytes=8388608},
    @{Path=$entry.ldf; Sha=$entry.ldfSha256; Bytes=75497472}
)) {
    $path = Join-Path $root $file.Path
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.Length -ne $file.Bytes -or
        $file.Sha -cnotmatch '^[0-9a-f]{64}$' -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $file.Sha) {
        throw "Pinned schema-$Schema fixture failed SHA-256 or file-size verification."
    }
}
# A different baseline must remain an unhydrated LFS pointer.
$other = if ($Schema -eq 7) { 3 } else { 7 }
foreach ($name in @('FMSC_DB.mdf','FMSC_DB_log.ldf')) {
    $item = Get-Item -LiteralPath (Join-Path $root "Database/v$other/$name") -ErrorAction Stop
    if ($item.Length -gt 1024) { throw 'Unexpected hydration of another historical SQL fixture.' }
}
Write-Host "Downloaded and SHA-256 verified only immutable schema-$Schema MDF/LDF."
