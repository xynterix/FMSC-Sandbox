"""Offline guard for immutable GitHub identity and exact-commit release acceptance.

Only examines workflow source; never opens a private fixture or calls GitHub.
"""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
accept = (root / ".github/workflows/private-release-acceptance.yml").read_text(encoding="utf-8")
chaos = (root / ".github/workflows/private-migration-chaos.yml").read_text(encoding="utf-8")
retention = (root / ".github/workflows/actions-run-retention.yml").read_text(encoding="utf-8")
harness = (root / "Tests/RunHistoricalMigrationChaos.ps1").read_text(encoding="utf-8")

for name, content in (("acceptance", accept), ("chaos", chaos),
                      ("retention", retention), ("harness", harness)):
    assert "farhan2166-creator" not in content, f"Mutable GitHub username in {name}"
    assert "1449162585" in content, f"Missing immutable Sandbox repository ID in {name}"

for value in ("https://api.github.com/user/316891609",
              ".id == 1412760928", ".owner.id == 316891609",
              "source_repo=$source_repo", "source_repo: ${{ steps.source.outputs.source_repo }}",
              "repository: ${{ needs.resolve.outputs.source_repo }}",
              "repository: ${{ github.repository }}",
              "ref: 7d225d2b8e38aecd4a1c3cfa7ccfaf56685149b9",
              "needs: [resolve, sql-contract, real-installer, migration-chaos]",
              "fmsc/sandbox-mdf-ldf/v2",
              "SOURCE_SHA", "SQL_RESULT", "INSTALL_RESULT", "CHAOS_RESULT",
              "FMSC_SOURCE_ATTEST_TOKEN"):
    assert value in accept, f"Required exact-commit release boundary missing: {value}"

for value in ("https://api.github.com/user/316891609", ".id == 1412760928",
              "repository: ${{ needs.resolve-source.outputs.source_repo }}",
              "repository: ${{ github.repository }}"):
    assert value in chaos, f"Source resolver or fixture isolation lost: {value}"

assert "1449162585" in retention and "316891609" in retention
assert "GITHUB_REPOSITORY_OWNER_ID" in harness
print("PASS: Sandbox workflows bind to immutable IDs, preserve fixtures and exact-commit SQL/installer/chaos gate.")

private_bundle = (root / ".github/workflows/private-complete-installer-v7.yml").read_text(encoding="utf-8")
private_packager = (root / "Tests/PackageCompleteInstallerV7.ps1").read_text(encoding="utf-8")
for required in (
    "workflow_dispatch:", "github.repository_id == '1449162585'",
    "github.repository_owner_id == '316891609'",
    "uses: farhan2166-creator/FMSC-Source/.github/workflows/fmsc-complete-installer.yml@main",
    "source_sha: ${{ needs.resolve-source.outputs.sha }}",
    "ref: 7d225d2b8e38aecd4a1c3cfa7ccfaf56685149b9",
    "lfs: true", "actions/download-artifact@v7",
    "actions/upload-artifact@v7",
    "FMSC_SMS-Complete-Windows-x64-Synthetic-v7-Included",
):
    assert required in private_bundle, f"Private v7 packaging boundary missing: {required}"
for required in (
    "GITHUB_REPOSITORY_ID", "1449162585", "fmsc-sandbox-fixtures/v1",
    "validated-schema-only", "Get-FileHash", "SHA256",
    "FMSC_DB.mdf", "FMSC_DB_log.ldf",
    "Source commit: $SourceSha", "SHA256SUMS.txt",
):
    assert required in private_packager, f"Private fixture validation missing: {required}"
assert "pull_request:" not in private_bundle, "Private fixture bundle must never run for PR code"
assert "repository_dispatch:" not in private_bundle, "Private bundle must remain manually dispatched"
print("PASS: private v7 package is restricted to Sandbox, frozen LFS checksums and exact Source SHA.")
