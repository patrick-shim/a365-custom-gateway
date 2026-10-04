#!/usr/bin/env bash
# Install development prerequisites, not the gateway or tenant resources.
# Supported install targets: Ubuntu 22.04/24.04/26.04, x86-64, systemd.
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage: bash tools/scripts/setup/install-linux-dependencies.sh [OPTIONS]
  --verify-only    Check tools and Docker access without installing anything
  --docker-group   Add this user to the Docker group (root-equivalent access)
  --help          Show this help

Run as your normal login user, not with sudo. The installer elevates only system
package/service operations. It installs .NET pinned by this checkout's global.json
and Node 20 into ~/.local/share/a365-gateway/devtools, leaving system copies alone.
Source ~/.config/a365-gateway/devtools.env afterward to select those versions.
Exit codes: 0 verified; 1 installation/error; 2 verification/action still required.
HELP
}
verify_only=false
docker_group=false
for argument in "$@"; do
  case "$argument" in
    --verify-only) verify_only=true ;;
    --docker-group) docker_group=true ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$argument" >&2; usage; exit 1 ;;
  esac
done
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n== %s ==\n' "$*"; }
trap 'printf "\nFailed at line %s. Resolve the reported error and rerun; no gateway resources were provisioned.\n" "$LINENO" >&2' ERR
[[ $(uname -s) == Linux ]] || fail 'Run this script on Linux.'
repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
[[ -f "$repository/global.json" ]] || fail 'Keep this script in tools/scripts/setup inside the repository.'
[[ -r /etc/os-release ]] || fail '/etc/os-release is missing.'
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}:$(uname -m)" in
  ubuntu:22.04:x86_64|ubuntu:24.04:x86_64|ubuntu:26.04:x86_64) ;;
  *) fail "Unsupported install target: ${ID:-unknown} ${VERSION_ID:-unknown} $(uname -m). Supported: Ubuntu 22.04/24.04/26.04 x86-64. No changes made." ;;
esac

tool_root="$HOME/.local/share/a365-gateway/devtools"
environment_file="$HOME/.config/a365-gateway/devtools.env"
export DOTNET_ROOT="$tool_root/dotnet"
export PATH="$tool_root/powershell:$tool_root/node/bin:$DOTNET_ROOT:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export AZURE_CORE_COLLECT_TELEMETRY=false

read_sdk_version() {
  python3 - "$repository/global.json" <<'PY'
import json, re, sys
sdk = json.load(open(sys.argv[1]))['sdk']
version = sdk['version']
if not re.fullmatch(r'10\.0\.4\d{2}', version) or sdk.get('rollForward') != 'latestPatch':
    sys.exit('Unsupported SDK pin: review the installer against global.json before proceeding.')
print(version)
PY
}

verify() {
  local failures=0 actual expected
  check() {
    local label=$1
    shift
    if "$@"; then printf '[PASS] %s\n' "$label"; else printf '[FAIL] %s\n' "$label"; failures=$((failures+1)); fi
  }
  log 'Verify development tools'
  check Git git --version
  if command -v python3 >/dev/null && expected=$(read_sdk_version); then
    if actual=$(cd "$repository" && dotnet --version) && [[ "$actual" =~ ^10\.0\.4[0-9]{2}$ ]] && [[ ! "$actual" < "$expected" ]]; then
      printf '[PASS] .NET SDK %s (repository requires %s or same-band newer patch)\n' "$actual" "$expected"
    else
      printf '[FAIL] .NET cannot resolve the SDK required by global.json\n'; failures=$((failures+1))
    fi
  else
    printf '[FAIL] Cannot read SDK requirement; Python 3 is required\n'; failures=$((failures+1))
  fi
  # PowerShell must receive its own variable expressions literally.
  # shellcheck disable=SC2016
  check PowerShell pwsh -NoLogo -NoProfile -Command 'if ($PSVersionTable.PSVersion.Major -lt 7) { exit 1 }; $PSVersionTable.PSVersion.ToString()'
  check 'Node.js 20' node -e 'console.log(process.version);process.exit(process.versions.node.split(".")[0] === "20" ? 0 : 1)'
  check npm npm --version
  check 'Azure CLI' az version --query '"azure-cli"' -o tsv
  check Bicep az bicep version
  check 'Docker CLI' docker --version
  check 'Docker Compose plugin' docker compose version
  check 'Docker Buildx plugin' docker buildx version
  check 'Docker daemon access from this login' docker info --format 'Server {{.ServerVersion}} / {{.OSType}}'
  if (( failures )); then
    printf '\n%s check(s) failed. For Docker permission errors, reconnect after --docker-group, or configure rootless Docker.\n' "$failures"
    return 2
  fi
  printf '\nAll prerequisite checks passed. This does not verify gateway deployment or Microsoft tenant access.\n'
  printf 'Purview catalog/assignment still requires Windows in the current application.\n'
}

if "$verify_only"; then
  if verify; then exit 0; else exit 2; fi
fi
(( EUID != 0 )) || fail 'Run as a normal login user with sudo access; do not sudo the whole script.'
command -v sudo >/dev/null || fail 'sudo is required for system packages.'
[[ -d /run/systemd/system ]] || fail 'Docker service setup requires a systemd host. Use a Linux server/VM, not an unprivileged container.'
sudo -v

# Never uninstall a pre-existing Docker/container runtime as part of dependency setup.
conflicts=()
for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
  if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) == 'install ok installed' ]]; then conflicts+=("$package"); fi
done
((${#conflicts[@]} == 0)) || fail "Existing packages conflict with Docker CE: ${conflicts[*]}. Review your existing runtime before changing packages."

log 'Install base tools'
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git python3 xz-utils tar libicu-dev libssl-dev zlib1g libgcc-s1 libstdc++6
sdk_version=$(read_sdk_version)
temporary_dir=$(mktemp -d /tmp/a365-devtools.XXXXXXXX)
# Invoked by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  case "${temporary_dir:-}" in /tmp/a365-devtools.*) rm -rf -- "$temporary_dir" ;; esac
}
trap cleanup EXIT
download() { curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' --retry 3 "$1" -o "$2"; }

install_powershell_archive() {
  # Reviewed stable Microsoft release; checksum from its published hashes.sha256.
  local version=7.6.6
  local checksum=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc
  local archive="powershell-$version-linux-x64.tar.gz"
  local destination="$tool_root/powershell-$version"
  log "No APT candidate: install official PowerShell $version archive"
  download "https://github.com/PowerShell/PowerShell/releases/download/v$version/$archive" "$temporary_dir/$archive"
  (cd "$temporary_dir"; printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check -)
  mkdir -p "$destination"
  tar -xzf "$temporary_dir/$archive" -C "$destination" --no-same-owner
  chmod +x "$destination/pwsh"
  # Verify the binary before activating the user-local command.
  # shellcheck disable=SC2016
  "$destination/pwsh" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  [[ ! -e "$tool_root/powershell" || -L "$tool_root/powershell" ]] || fail 'PowerShell activation path is not an installer symlink.'
  ln -sfn "powershell-$version" "$tool_root/powershell"
  hash -r
}

log 'Ensure PowerShell 7+'
# shellcheck disable=SC2016
if command -v pwsh >/dev/null && pwsh -NoLogo -NoProfile -Command 'if ($PSVersionTable.PSVersion.Major -lt 7) { exit 1 }'; then
  printf 'Existing PowerShell 7+ works; keeping it.\n'
else
  download "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb" "$temporary_dir/microsoft-prod.deb"
  sudo dpkg -i "$temporary_dir/microsoft-prod.deb"
  sudo apt-get update
  candidate=$(LC_ALL=C apt-cache policy powershell | awk '/Candidate:/ { print $2; exit }')
  if [[ -n "$candidate" && "$candidate" != '(none)' ]]; then
    sudo apt-get install -y powershell
  else
    install_powershell_archive
  fi
fi

log 'Install Azure CLI from Microsoft packages'
sudo install -d -m 0755 /etc/apt/keyrings
download https://packages.microsoft.com/keys/microsoft.asc "$temporary_dir/microsoft.asc"
gpg --batch --yes --dearmor -o "$temporary_dir/microsoft.gpg" "$temporary_dir/microsoft.asc"
sudo install -m 0644 "$temporary_dir/microsoft.gpg" /etc/apt/keyrings/a365-microsoft.gpg
printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/a365-microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ %s main\n' "$VERSION_CODENAME" > "$temporary_dir/azure-cli.list"
# Refuse a second signing configuration for an existing Azure CLI repository.
existing_azure=$(grep -rl 'https://packages.microsoft.com/repos/azure-cli' /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null || true)
if [[ -n "$existing_azure" ]]; then
  while IFS= read -r source_file; do
    grep -Eq "(^Suites:.*\b$VERSION_CODENAME\b|repos/azure-cli/?[[:space:]]+${VERSION_CODENAME}[[:space:]])" "$source_file" || fail "Review existing Azure CLI source for this Ubuntu release: $source_file"
  done <<< "$existing_azure"
fi
if [[ -z "$existing_azure" ]]; then sudo install -m 0644 "$temporary_dir/azure-cli.list" /etc/apt/sources.list.d/a365-azure-cli.list; fi
sudo apt-get update
sudo apt-get install -y azure-cli
az bicep install

log "Install repository-pinned .NET SDK $sdk_version"
mkdir -p "$tool_root/dotnet"
if [[ ! -d "$tool_root/dotnet/sdk/$sdk_version" ]]; then
  download https://dot.net/v1/dotnet-install.sh "$temporary_dir/dotnet-install.sh"
  if ! bash "$temporary_dir/dotnet-install.sh" --version "$sdk_version" --architecture x64 --install-dir "$tool_root/dotnet" --no-path; then
    fail "Microsoft's installer could not install SDK $sdk_version. Check network access and version availability; global.json was not relaxed."
  fi
fi

log 'Install Node.js 20 and bundled npm from nodejs.org'
# Keep the host version aligned with the current frontend container build.
download https://nodejs.org/dist/index.json "$temporary_dir/node-index.json"
node_version=$(python3 - "$temporary_dir/node-index.json" <<'PY'
import json, re, sys
for release in json.load(open(sys.argv[1])):
    if re.fullmatch(r'v20\.\d+\.\d+', release['version']) and 'linux-x64' in release['files']:
        print(release['version']); break
else:
    sys.exit('No Node.js 20 Linux x64 release found.')
PY
)
node_archive="node-$node_version-linux-x64.tar.xz"
if [[ ! -x "$tool_root/node-$node_version-linux-x64/bin/node" ]]; then
  download "https://nodejs.org/dist/$node_version/$node_archive" "$temporary_dir/$node_archive"
  download "https://nodejs.org/dist/$node_version/SHASUMS256.txt" "$temporary_dir/SHASUMS256.txt"
  (cd "$temporary_dir"; awk -v file="$node_archive" '$2 == file {print}' SHASUMS256.txt > node.sha256; [[ $(wc -l < node.sha256) == 1 ]]; sha256sum --check node.sha256)
  tar -xJf "$temporary_dir/$node_archive" -C "$tool_root" --no-same-owner
fi
[[ ! -e "$tool_root/node" || -L "$tool_root/node" ]] || fail "$tool_root/node is not an installer symlink; refusing to replace it."
ln -sfn "node-$node_version-linux-x64" "$tool_root/node"
mkdir -p "$(dirname "$environment_file")"
{
  printf '# Source this file before developing the A365 Gateway.\n'
  printf 'export DOTNET_ROOT=%q\n' "$tool_root/dotnet"
  # Expand PATH when the generated file is sourced, not while it is written.
  # shellcheck disable=SC2016
  printf 'export PATH=%q:%q:%q:$PATH\n' "$tool_root/powershell" "$tool_root/node/bin" "$tool_root/dotnet"
  printf 'export DOTNET_CLI_TELEMETRY_OPTOUT=1\n'
} > "$environment_file"

log 'Install Docker Engine, Buildx and Compose from Docker packages'
download https://download.docker.com/linux/ubuntu/gpg "$temporary_dir/docker.asc"
sudo install -m 0644 "$temporary_dir/docker.asc" /etc/apt/keyrings/a365-docker.asc
printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/a365-docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "$VERSION_CODENAME" > "$temporary_dir/docker.list"
existing_docker=$(grep -rl 'https://download.docker.com/linux/ubuntu' /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null || true)
if [[ -n "$existing_docker" ]]; then
  while IFS= read -r source_file; do
    grep -Eq "(^Suites:.*\b$VERSION_CODENAME\b|linux/ubuntu/?[[:space:]]+${VERSION_CODENAME}[[:space:]])" "$source_file" || fail "Review existing Docker source for this Ubuntu release: $source_file"
  done <<< "$existing_docker"
fi
if [[ -z "$existing_docker" ]]; then sudo install -m 0644 "$temporary_dir/docker.list" /etc/apt/sources.list.d/a365-docker.list; fi
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker info --format 'Docker daemon: {{.ServerVersion}} / {{.OSType}}'
if "$docker_group"; then
  log 'Grant requested Docker group access (root-equivalent)'
  sudo usermod -aG docker "$(id -un)"
  printf 'Reconnect your SSH session to activate newly added group membership.\n'
fi
hash -r
printf '\nFor this and future shells, run:\n  source %q\n' "$environment_file"
printf 'Then verify again:\n  bash %q --verify-only\n' "$repository/tools/scripts/setup/install-linux-dependencies.sh"
if verify; then exit 0; else exit 2; fi
