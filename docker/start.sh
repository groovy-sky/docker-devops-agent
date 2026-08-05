#!/usr/bin/env bash
set -Eeuo pipefail

: "${AZP_URL:?error: AZP_URL environment variable is required}"

AZP_POOL="${AZP_POOL:-Default}"
AZP_WORK="${AZP_WORK:-_work}"
AZP_AGENT_ONCE="${AZP_AGENT_ONCE:-false}"
AZP_AGENT_NAME="${AZP_AGENT_NAME:-$(hostname)}"

AGENT_ROOT="/azp"
AGENT_DIR="${AGENT_ROOT}/agent"
TOKEN_FILE="${AGENT_ROOT}/.token"
AUTH_MODE=""

AZDO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"
IMDS_API_VERSION="2019-08-01"

print_header() {
  printf '\033[1;36m%s\033[0m\n' "$1"
}

fail() {
  echo >&2 "error: $*"
  exit 1
}

get_azdo_managed_identity_token() {
  local imds_url response token

  imds_url="http://169.254.169.254/metadata/identity/oauth2/token"
  imds_url+="?api-version=${IMDS_API_VERSION}"
  imds_url+="&resource=${AZDO_RESOURCE}"

  if [[ -n "${AZP_CLIENT_ID:-}" ]]; then
    imds_url+="&client_id=${AZP_CLIENT_ID}"
  fi

  response="$({
    curl --silent --show-error --fail \
      --connect-timeout 5 \
      --max-time 15 \
      -H "Metadata: true" \
      "$imds_url"
  })" || return 1

  token="$(jq --raw-output '.access_token // empty' <<<"$response")"
  [[ -n "$token" ]] || return 1

  printf '%s' "$token"
}

write_token_file() {
  local token="$1"
  umask 177
  printf '%s' "$token" > "$TOKEN_FILE"
}

remove_token_file() {
  rm -f "$TOKEN_FILE" 2>/dev/null || true
}

remove_agent() {
  local token="${1:-}"

  if [[ ! -x "${AGENT_DIR}/config.sh" ]]; then
    return 0
  fi

  if [[ -z "$token" && "$AUTH_MODE" == "managed_identity" ]]; then
    token="$(get_azdo_managed_identity_token 2>/dev/null || true)"
  fi

  if [[ -z "$token" ]]; then
    echo >&2 "warning: skipping agent removal because no authentication token is available."
    return 0
  fi

  print_header "Cleanup. Removing Azure Pipelines agent..."
  "${AGENT_DIR}/config.sh" remove --unattended --auth PAT --token "$token" || true
}

cleanup() {
  local exit_code="${1:-$?}"
  local cleanup_token=""

  if [[ -f "$TOKEN_FILE" ]]; then
    cleanup_token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
  fi

  remove_token_file
  remove_agent "$cleanup_token"

  exit "$exit_code"
}

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

export VSO_AGENT_IGNORE=AZP_TOKEN,AZP_TOKEN_FILE

print_header "1. Selecting Azure DevOps authentication..."

if managed_identity_token="$(get_azdo_managed_identity_token 2>/dev/null)"; then
  AUTH_MODE="managed_identity"
  write_token_file "$managed_identity_token"
  unset managed_identity_token
  echo "Managed identity token acquired successfully."
else
  if [[ -n "${AZP_TOKEN:-}" ]]; then
    AUTH_MODE="pat"
    write_token_file "$AZP_TOKEN"
    unset AZP_TOKEN
    echo "Managed identity unavailable; using AZP_TOKEN fallback."
  else
    fail "Could not acquire an Azure DevOps token from Azure IMDS and AZP_TOKEN fallback was not provided.

Ensure that:
  - the workload runs on an Azure resource with an assigned managed identity;
  - IMDS is reachable from the container (local Docker/Podman hosts outside Azure cannot reach IMDS);
  - AZP_CLIENT_ID is set when selecting a user-assigned identity; or
  - AZP_TOKEN is deliberately provided as a legacy fallback."
  fi
fi

print_header "2. Determining matching Azure Pipelines agent..."

case "$(uname -m)" in
  x86_64|amd64)
    agent_platform="linux-x64"
    ;;
  aarch64|arm64)
    agent_platform="linux-arm64"
    ;;
  armv7l|armv6l)
    agent_platform="linux-arm"
    ;;
  *)
    fail "Unsupported CPU architecture: $(uname -m)"
    ;;
esac

rm -rf "$AGENT_DIR"
mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

if [[ "$AUTH_MODE" == "managed_identity" ]]; then
  agent_packages="$({
    curl --silent --show-error --fail \
      -H 'Accept: application/json' \
      -H "Authorization: ****** "$TOKEN_FILE")" \
      "$AZP_URL/_apis/distributedtask/packages/agent?platform=${agent_platform}&top=1"
  })" || fail "Could not determine a matching Azure Pipelines agent package from Azure DevOps."
else
  agent_packages="$({
    curl --silent --show-error --fail \
      --user "user:$(cat "$TOKEN_FILE")" \
      -H 'Accept: application/json' \
      "$AZP_URL/_apis/distributedtask/packages/agent?platform=${agent_platform}&top=1"
  })" || fail "Could not determine a matching Azure Pipelines agent package from Azure DevOps."
fi

agent_download_url="$(jq --raw-output '.value[0].downloadUrl // empty' <<<"$agent_packages")"
[[ -n "$agent_download_url" ]] || fail "Azure DevOps did not return a matching Azure Pipelines agent package."

print_header "3. Downloading and extracting Azure Pipelines agent..."
curl --location --silent --show-error --fail "$agent_download_url" | tar -xz --no-overwrite-dir

set +u
source ./env.sh
set -u

print_header "4. Configuring Azure Pipelines agent..."
./config.sh --unattended \
  --agent "$AZP_AGENT_NAME" \
  --url "$AZP_URL" \
  --auth PAT \
  --token "$(cat "$TOKEN_FILE")" \
  --pool "$AZP_POOL" \
  --work "$AZP_WORK" \
  --replace \
  --acceptTeeEula

remove_token_file

print_header "5. Running Azure Pipelines agent..."

if [[ "$AZP_AGENT_ONCE" == "true" ]]; then
  ./run.sh --once
  remove_agent
  exit 0
fi

trap 'cleanup 0' EXIT
./run.sh "$@"
