$ErrorActionPreference = "Continue"
try {
  & "$PSScriptRoot/bootstrap/bootstrap.ps1" -Mode Up -Yes -NonInteractive -OutputFormat Text
  Write-Output "EXIT_OK"
} catch {
  Write-Output ("EX=" + $_.Exception.Message)
  exit 1
}
