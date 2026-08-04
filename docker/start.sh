#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Required environment variables
#
# AZP_URL                 Example: https://dev.azure.com/my-organization
#
# Optional environment variables
#
# AZP_POOL                Agent-pool name. Default: Default
# AZP_AGENT_NAME          Agent name. Default: container hostname
# AZP_WORK                Work directory. Default: _work
# AZP_AGENT_ONCE          true or false. Default: false
#
# AZP_CLIENT_ID           Client ID of a user-assigned managed identity.
#                         Leave unset for a system-assigned managed identity.
###############################################################################

: "${AZP_URL:?error: AZP_URL environment variable is required}"

AZP_POOL="${AZP_POOL:-Default}"
AZP_WORK="${AZP_WORK:-_work}"
AZP_AGENT_ONCE="${AZP_AGENT_ONCE:-false}"

AGENT_ROOT="/azp"
AGENT_DIR="${AGENT_ROOT}/agent"
TOKEN_FILE="${AGENT_ROOT}/.azdo-mi-token"

# Azure DevOps Microsoft Entra resource / application ID.
AZDO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"

print_header() {
  printf '\033[1;36m%s\033[0m\n' "\$1"
}

fail() {
  echo >&2 "error: $*"
  exit 1
}

###############################################################################
# Gets a fresh Microsoft Entra token from Azure IMDS.
#
# This uses:
# - system-assigned MI when AZP_CLIENT_ID is absent
# - user-assigned MI when AZP_CLIENT_ID is set
###############################################################################
get_azdo_managed_identity_token() {
  local imds_url response token

  imds_url="http://169.254.169.254/metadata/identity/oauth2/token"
  imds_url+="?api-version=2019-08-01"
  imds_url+="&resource=${AZDO_RESOURCE}"

  if [[ -n "${AZP_CLIENT_ID:-}" ]]; then
    imds_url+="&client_id=${AZP_CLIENT_ID}"
  fi

  response="$(
    curl --silent --show-error --fail \
      --connect-timeout 5 \
      --max-time 15 \
      -H "Metadata: true" \
      "$imds_url"
  )" || return 1

  token="$(jq --raw-output '.access_token // empty' <<<"$response")"

  [[ -n "$token" ]] || return 1

  printf '%s' "$token"
}

remove_agent() {
  local token=""

  if [[ ! -f "${AGENT_DIR}/config.sh" ]]; then
    return 0
  fi

  print_header "Cleanup. Attempting to remove Azure Pipelines agent..."

  # Acquire a NEW token. Entra / managed-identity tokens are short-lived,
  # so do not depend on the token acquired during initial registration.
  token="$(get_azdo_managed_identity_token 2>/dev/null || true)"

  if [[ -z "$token" ]]; then
    echo >&2 "warning: could not acquire a managed-identity token during cleanup."
    echo >&2 "warning: agent was not explicitly removed; --replace handles stale registration on next start."
    return 0
  fi

  # `PAT` is the agent CLI's historical auth-mode name.
  # The supplied token here is an Entra managed-identity access token,
  # NOT a Personal Access Token.
  "${AGENT_DIR}/config.sh" remove --unattended \
    --auth PAT \
    --token "$token" || true

  unset token
}

cleanup() {
  local result=$?

  rm -f "$TOKEN_FILE" 2>/dev/null || true
  remove_agent || true

  exit "$result"
}

trap cleanup INT TERM

###############################################################################
# 1. Obtain a short-lived Azure DevOps Entra token using managed identity
###############################################################################
print_header "1. Acquiring Azure DevOps token through Azure Managed Identity..."

AZP_TOKEN="$(get_azdo_managed_identity_token)" ||
  fail "Could not get an Azure DevOps token from Azure IMDS.

Ensure that:
  - the workload runs on an Azure resource with an assigned managed identity;
  - IMDS is reachable from the container;
  - AZP_CLIENT_ID is the Client ID of the user-assigned MI, when applicable."

printf '%s' "$AZP_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
unset AZP_TOKEN

echo "Managed identity token acquired successfully."

###############################################################################
# 2. Select the correct agent package
###############################################################################
print_header "2. Determining matching Azure Pipelines agent..."

CPU_ARCH="$(uname -m)"

case "$CPU_ARCH" in
  aarch64|arm64)
    ARCH="linux-arm64"
    ;;
  x86_64|amd64)
    ARCH="linux-x64"
    ;;
  armv7l|armv6l)
    ARCH="linux-arm"
    ;;
  *)
    fail "Unsupported CPU architecture: ${CPU_ARCH}"
    ;;
esac

# Alpine requires musl-specific packages where available.
if [[ -f /etc/alpine-release ]]; then
  case "$ARCH" in
    linux-x64) ARCH="linux-musl-x64" ;;
    linux-arm64) ARCH="linux-musl-arm64" ;;
  esac
fi

echo "Selected agent architecture: ${ARCH}"

###############################################################################
# 3. Download and install latest matching agent
###############################################################################
REPO="microsoft/azure-pipelines-agent"

RELEASE_JSON="$(
  curl --silent --show-error --fail \
    --connect-timeout 10 \
    --max-time 30 \
    "https://api.github.com/repos/${REPO}/releases/latest"
)" || fail "Could not retrieve the latest Azure Pipelines agent release."

VERSION="$(jq --raw-output '.tag_name // empty' <<<"$RELEASE_JSON")"
VERSION="${VERSION#v}"

[[ -n "$VERSION" ]] ||
  fail "Could not determine the Azure Pipelines agent version."

AGENT_FILE="vsts-agent-${ARCH}-${VERSION}.tar.gz"
AGENT_URL="https://download.agent.dev.azure.com/agent/${VERSION}/${AGENT_FILE}"

print_header "3. Downloading Azure Pipelines agent ${VERSION}..."

rm -rf "$AGENT_DIR"
mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

curl --location --silent --show-error --fail \
  "$AGENT_URL" | tar -xz

source ./env.sh

export AGENT_ALLOW_RUNASROOT="1"

###############################################################################
# Diagnostics
###############################################################################
print_header "4. Agent diagnostics..."

echo "Debug: uname -m = $(uname -m)"
echo "Debug: uname -s = $(uname -s)"
echo "Debug: Selected ARCH = ${ARCH}"

if command -v file >/dev/null 2>&1; then
  echo "Debug: Agent.Listener file information:"
  file ./bin/Agent.Listener || true
fi

if command -v ldd >/dev/null 2>&1; then
  echo "Debug: Agent.Listener shared-library dependencies:"
  ldd ./bin/Agent.Listener || true
fi

###############################################################################
# 5. Register the agent
#
# Important:
# The token is a Microsoft Entra access token issued to the Azure managed
# identity. It is not a PAT. Azure DevOps must already know this managed
# identity and it must have permission to administer/register agents in AZP_POOL.
###############################################################################
print_header "5. Configuring Azure Pipelines agent..."

./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "$AZP_URL" \
  --auth PAT \
  --token "$(cat "$TOKEN_FILE")" \
  --pool "$AZP_POOL" \
  --work "$AZP_WORK" \
  --once "$AZP_AGENT_ONCE" \
  --replace \
  --acceptTeeEula

# Do not leave the registration token on disk.
rm -f "$TOKEN_FILE"

###############################################################################
# 6. Run the agent
###############################################################################
print_header "6. Running Azure Pipelines agent..."

if [[ "$AZP_AGENT_ONCE" == "true" ]]; then
  ./externals/node/bin/node ./bin/AgentService.js interactive --once

  # Explicit cleanup after the one job completes.
  remove_agent
  trap - INT TERM
  exit 0
fi

# AgentService handles Azure Pipelines agent restart/update behavior.
exec ./externals/node/bin/node ./bin/AgentService.js interactive
