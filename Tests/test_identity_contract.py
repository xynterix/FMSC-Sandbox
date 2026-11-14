"""Offline guard for immutable GitHub identity and exact-commit release acceptance.

Only examines workflow source; never opens a private fixture or calls GitHub.
"""
from pathlib import Path
from os import environ
from re import search

root = Path(__file__).resolve().parent.parent
accept = (root / ".github/workflows/private-release-acceptance.yml").read_text(encoding="utf-8")
chaos = (root / ".github/workflows/private-migration-chaos.yml").read_text(encoding="utf-8")
retention = (root / ".github/workflows/actions-run-retention.yml").read_text(encoding="utf-8")
harness = (root / "Tests/RunHistoricalMigrationChaos.ps1").read_text(encoding="utf-8")

for name, content in (("acceptance", accept), ("chaos", chaos),
                      ("retention", retention), ("harness", harness)):
    # Only immutable repository IDs are allowed in identity-sensitive checks.
    assert not search(r"https://api\.github\.com/repos/[^/]+/FMSC-(?:Source|Sandbox)", content), f"Mutable GitHub API path in {name}"
    assert "1449162585" in content, f"Missing immutable Sandbox repository ID in {name}"

for value in ("https://api.github.com/user/316891609",
              ".id == 1412760928", ".owner.id == 316891609",
              "source_repo=$source_repo", "source_repo: ${{ steps.source.outputs.source_repo }}",
              "repository: ${{ needs.resolve.outputs.source_repo }}",
              "repository: ${{ github.repository }}",
              "ref: 7d225d2b8e38aecd4a1c3cfa7ccfaf56685149b9",
              "needs: [resolve, sql-contract, real-installer]",
              "fmsc/sandbox-mdf-ldf/v2",
              "SOURCE_SHA", "SQL_RESULT", "INSTALL_RESULT",
              "FMSC_SOURCE_ATTEST_TOKEN"):
    assert value in accept, f"Required exact-commit release boundary missing: {value}"

for value in ("https://api.github.com/user/316891609", ".id == 1412760928",
              "repository: ${{ needs.resolve-source.outputs.source_repo }}",
              "repository: ${{ github.repository }}"):
    assert value in chaos, f"Source resolver or fixture isolation lost: {value}"

# A resolver failure must reach the trusted attestor (rather than leaving
# Workflow 04 polling for its full timeout), but success still requires all
# required suites and an independently resolved exact Source commit.
assert "if: ${{ always()" in accept
assert "SOURCE_SHA: ${{ needs.resolve.outputs.source_sha || inputs.source_sha }}" in accept
assert "RESOLVE_RESULT: ${{ needs.resolve.result }}" in accept
assert 'if [[ "$RESOLVE_RESULT" == \'success\' &&' in accept
assert '"$SQL_RESULT" == \'success\'' in accept
assert '"$INSTALL_RESULT" == \'success\'' in accept
assert '[[ "$SOURCE_SHA" != "$main" ]]' in accept
assert 'state=\'failure\'' in accept
assert '-H "Authorization: Bearer $GITHUB_TOKEN"' in accept

assert "1449162585" in retention and "316891609" in retention
assert "GITHUB_REPOSITORY_OWNER_ID" in harness
# The publication gate now validates the latest supported historical baseline (v7).
# v3 failure/restore rehearsals remain a separately invoked workflow.
assert accept.count("schema: [7]") == 2
assert "matrix.schema" in accept
assert "migration-chaos:" not in accept
assert "workflow_dispatch:" in chaos
assert "RunHistoricalMigrationChaos.ps1" in chaos
assert "FetchPinnedFixture.ps1 -Schema 7" in accept
assert accept.count("lfs: false") == 2
assert "lfs: true" not in accept

fixture_hydrator = (root / "Tests/FetchPinnedFixture.ps1").read_text(encoding="utf-8")
for required in (
    "FMSC_FIXTURE_READ_TOKEN", "GITHUB_REPOSITORY_ID",
    "7d225d2b8e38aecd4a1c3cfa7ccfaf56685149b9",
    "lfs pull --include=", "Get-FileHash", "SHA256",
    "FMSC_DB.mdf", "FMSC_DB_log.ldf",
):
    assert required in fixture_hydrator, f"Pinned selective-LFS verification missing: {required}"
assert "persist-credentials: false" in accept
assert "GIT_LFS_SKIP_SMUDGE: '1'" in accept
print("PASS: immutable IDs, exact-commit v7 SQL/installer gate and separate manual v3 chaos.")

private_bundle = (root / ".github/workflows/private-complete-installer-v7.yml").read_text(encoding="utf-8")
private_packager = (root / "Tests/PackageCompleteInstallerV7.ps1").read_text(encoding="utf-8")
for required in (
    "workflow_dispatch:", "github.repository_id == '1449162585'",
    "github.repository_owner_id == '316891609'",
    "GITHUB_REPOSITORY_OWNER",
    "source_sha: ${{ needs.resolve-source.outputs.sha }}",
    "ref: 7d225d2b8e38aecd4a1c3cfa7ccfaf56685149b9",
    "lfs: false", "actions/download-artifact@v7",
    "actions/upload-artifact@v7",
    "FMSC_SMS-Complete-Windows-x64-Synthetic-v7-Included",
):
    assert required in private_bundle, f"Private v7 packaging boundary missing: {required}"

# GitHub requires a literal owner in a cross-repository reusable-workflow
# 'uses:' reference. Check against the current Actions owner, not a frozen
# historical username; offline checks validate syntax without binding a name.
reusable = "FMSC-Source/.github/workflows/fmsc-complete-installer.yml@main"
owner = environ.get("GITHUB_REPOSITORY_OWNER")
if owner:
    assert f"uses: {owner}/{reusable}" in private_bundle, "Reusable workflow must point at the current account"
else:
    assert search(r"(?m)^    uses: [A-Za-z0-9-]+/" + reusable.replace(".", r"\.") + r"$", private_bundle), "Reusable workflow reference missing"
assert 'api="https://api.github.com/repos/${GITHUB_REPOSITORY_OWNER}/FMSC-Source"' in private_bundle
assert '$api = "https://api.github.com/repos/$env:GITHUB_REPOSITORY_OWNER/FMSC-Source"' in private_bundle
# Runner GitHub API calls must use the automatically issued token, otherwise
# unauthenticated calls can fail with HTTP 403 under public IP rate limits.
assert private_bundle.count('GITHUB_TOKEN: ${{ github.token }}') >= 2
assert private_bundle.count('-H "Authorization: Bearer $GITHUB_TOKEN"') == 2
assert 'Invoke-RestMethod -Uri $api -Headers $authHeaders' in private_bundle
assert 'Invoke-RestMethod -Uri "$api/branches/main" -Headers $authHeaders' in private_bundle
assert "https://api.github.com/repositories/1412760928" not in private_bundle
for required in (
    "GITHUB_REPOSITORY_ID", "1449162585", "fmsc-sandbox-fixtures/v1",
    "validated-schema-only", "Get-FileHash", "SHA256",
    "FMSC_DB.mdf", "FMSC_DB_log.ldf",
    "Source commit: $SourceSha", "SHA256SUMS.txt",
):
    assert required in private_packager, f"Private fixture validation missing: {required}"
assert "-ccontains 'Database/FMSC_DB.mdf'" in private_packager
assert "-ccontains 'Database/FMSC_DB_log.ldf'" in private_packager
assert "$names[0]" not in private_packager, "Do not compare culture-sorted file positions"
assert "'Tests/PackageCompleteInstallerV7.ps1'" in private_bundle
assert "FMSC_GOOGLE_DESKTOP_JSON" not in private_bundle, "Removed Google credentials must not be required by private packaging"
assert "GoogleClientId" not in private_bundle, "Removed Google providers must not block private packaging"
assert "FetchPinnedFixture.ps1 -Schema 7" in private_bundle
assert "deleteArtifact" in private_bundle
assert "compression-level: 6" in private_bundle
assert "pull_request:" not in private_bundle, "Private fixture bundle must never run for PR code"
assert "repository_dispatch:" not in private_bundle, "Private bundle must remain manually dispatched"
print("PASS: private v7 package is restricted to Sandbox, frozen LFS checksums and exact Source SHA.")
