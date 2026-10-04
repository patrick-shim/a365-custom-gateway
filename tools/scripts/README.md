# Standalone operator and development scripts

These scripts are not part of normal Gateway startup. Run them explicitly from
the repository root. They retain their existing authentication and safety checks.

| Directory | Purpose |
| --- | --- |
| `setup/install-linux-dependencies.sh` | Installs and verifies development tools on Ubuntu 22.04/24.04/26.04 x86-64; see [Linux setup](setup/README.md). |
| `diagnostics/Get-PurviewSensitiveInformationTypes.ps1` | Read-only, interactive Purview classifier discovery; never creates classifiers. |
| `diagnostics/PurviewDiagnostics.psm1` | Connection and inventory helpers owned by the classifier-discovery diagnostic. |
| `diagnostics/Test-GatewayAgentDlp.ps1` | Live normal/synthetic-sensitive gateway probe using an explicitly supplied test-agent key file. |
| `diagnostics/Test-GatewayApiDocumentation.ps1` | Read-only checks for the live OpenAPI contract and interactive reference. |
| `maintenance/Test-RepositoryLayout.ps1` | Offline source layout, project-reference and PowerShell syntax checks. |

Bootstrap entry points/modules stay in `bootstrap/`. Provider scripts executed by
C# stay beside their owning project in `src/*/Automation` or the catalog host.
Reusable diagnostics belong here. Generated credentials, checkpoints and published
runtime binaries in `.bootstrap/` are ignored installation state, not source
utilities. Preserve the active installation state when cleaning source files.
