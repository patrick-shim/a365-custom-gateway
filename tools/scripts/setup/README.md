# Linux development prerequisites

`install-linux-dependencies.sh` prepares Ubuntu **22.04, 24.04 or 26.04 on x86-64**. Intel 13th-generation processors use this architecture. Installation requires a normal login user with sudo access, systemd and internet access to Microsoft, Docker, Node.js and Ubuntu package services.

From the repository root:

```bash
bash tools/scripts/setup/install-linux-dependencies.sh --docker-group
```

The optional `--docker-group` flag grants this login user Docker access without sudo. Docker group membership gives root-equivalent host access. Omit it if you manage Docker access separately. Reconnect SSH after adding group membership, then run:

```bash
source ~/.config/a365-gateway/devtools.env
bash tools/scripts/setup/install-linux-dependencies.sh --verify-only
```

Source that environment file in each development shell; add the source line to your own shell startup configuration if desired. The installer does not edit shell startup files. Do not run the whole script with sudo: user-local SDK, Node and Bicep files belong to the login user.

## Installed and verified

- Git, PowerShell 7+, Azure CLI, Bicep, Docker Engine, Compose and Buildx.
- .NET SDK at the exact `global.json` pin, currently 10.0.400. Verification accepts newer 10.0.4xx patches allowed by that file. An unavailable SDK is an error; no silent version substitution occurs.
- Latest available Node.js 20 patch and bundled npm, matching the Console build image. The archive is checked against the SHA-256 published by Node.js.
- Supporting native libraries and download/verification utilities.

.NET and Node install under `~/.local/share/a365-gateway/devtools`; system copies are not replaced. Bicep uses Azure CLI's current-user installation. System packages use Microsoft and Docker repositories for the detected Ubuntu release, with package signature verification enabled. Existing conflicting Docker distribution packages cause a clear stop; they are not uninstalled automatically. The script starts and enables the Docker service.

Verification checks every command, the repository's resolved SDK version and Docker daemon access from the current login. Exit 0 means checks passed; exit 1 means installation failed; exit 2 means verification or a session/access action remains. It can be rerun after fixing a reported problem.

## Scope

This installs local tools. It does not sign in, deploy the gateway, create cloud resources, or prove Purview enforcement. The current gateway's Purview catalog/assignment implementation still requires Windows. A successful tool check does not remove that application limitation.

Installation recipes follow the official [Docker Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/), [PowerShell Ubuntu instructions](https://learn.microsoft.com/en-us/powershell/scripting/install/install-ubuntu), [Azure CLI instructions](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux), and [.NET install script](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-install-script).
