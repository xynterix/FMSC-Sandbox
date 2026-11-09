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
              "ref: 5a8c5130c9d7b76552bb73a753cd44c4d192d2d0",
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
