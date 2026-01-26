#!/bin/bash
set -e

if [ -z "$AZP_URL" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi

if [ -z "$AZP_TOKEN_FILE" ]; then
  AZP_TOKEN_FILE="/azp/.token"
fi

if [ -z "$AZP_TOKEN" ]; then
  if ! command -v az >/dev/null 2>&1; then
    echo 1>&2 "error: missing AZP_TOKEN and Azure CLI is not installed"
    exit 1
  fi

  az login --identity --allow-no-subscriptions >/dev/null 2>&1 || true
  AZP_TOKEN=$(az account get-access-token \
    --resource 499b84ac-1321-427f-aa17-267ca6975798 \
    --query accessToken -o tsv 2>/dev/null) || true

  if [ -z "$AZP_TOKEN" ]; then
    echo 1>&2 "error: failed to obtain Azure DevOps access token using managed identity"
    exit 1
  fi
fi

echo -n "$AZP_TOKEN" > "$AZP_TOKEN_FILE"

unset AZP_TOKEN

if [ -n "$AZP_WORK" ]; then
  mkdir -p "$AZP_WORK"
fi

rm -rf /azp/agent
mkdir /azp/agent
cd /azp/agent

export AGENT_ALLOW_RUNASROOT="1"

cleanup() {
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    ./config.sh remove --unattended \
      --auth PAT \
      --token $(cat "$AZP_TOKEN_FILE")
  fi
}

print_header() {
  lightcyan='\033[1;36m'
  nocolor='\033[0m'
  echo -e "${lightcyan}$1${nocolor}"
}

# Let the agent ignore the token env variables
export VSO_AGENT_IGNORE=AZP_TOKEN,AZP_TOKEN_FILE

print_header "1. Downloading Azure Pipelines agent via Azure CLI..."

if ! az extension show --name azure-devops >/dev/null 2>&1; then
  az extension add --name azure-devops -y >/dev/null 2>&1
fi

export AZURE_DEVOPS_EXT_PAT="$AZP_TOKEN"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) AZP_PLATFORM="linux-x64" ;;
  aarch64|arm64) AZP_PLATFORM="linux-arm64" ;;
  armv7l|armv6l) AZP_PLATFORM="linux-arm" ;;
  *) AZP_PLATFORM="linux-x64" ;;
esac

AZP_ORG_NAME="${AZP_URL##*/}"

AZP_AGENT_RESPONSE=$(az devops invoke \
  --route-parameters organization="$AZP_ORG_NAME" \
  --area distributedtask \
  --resource packages \
  --route-parameters packageType=agent \
  --http-method GET \
  --api-version 7.1 \
  -o json 2>/dev/null) || true

if ! echo "$AZP_AGENT_RESPONSE" | jq . >/dev/null 2>&1; then
  echo 1>&2 "error: invalid response from Azure DevOps when requesting agent packages"
  echo 1>&2 "$AZP_AGENT_RESPONSE"
  exit 1
fi

AZP_AGENT_MATCHES=$(echo "$AZP_AGENT_RESPONSE" \
  | jq -r --arg platform "$AZP_PLATFORM" \
    '[.value[] | select(.platform == $platform)]')

if [ -z "$AZP_AGENT_MATCHES" ] || [ "$AZP_AGENT_MATCHES" = "null" ] \
  || [ "$(echo "$AZP_AGENT_MATCHES" | jq 'length')" -eq 0 ]; then
  echo 1>&2 "error: no agent packages returned for platform '${AZP_PLATFORM}'"
  echo 1>&2 "available platforms:"
  echo 1>&2 "$(echo "$AZP_AGENT_RESPONSE" | jq -r '.value[].platform' | sort -u)"
  exit 1
fi

AZP_AGENTPACKAGE_URL=$(echo "$AZP_AGENT_MATCHES" \
  | jq -r 'map([.version.major,.version.minor,.version.patch,.downloadUrl])
           | sort
           | .[length-1]
           | .[3]')

if [ -z "$AZP_AGENTPACKAGE_URL" ] || [ "$AZP_AGENTPACKAGE_URL" = "null" ]; then
  echo 1>&2 "error: could not determine a matching Azure Pipelines agent"
  exit 1
fi

curl -LsS "$AZP_AGENTPACKAGE_URL" | tar -xz

print_header "2. Installing Azure Pipelines agent..."

source ./env.sh

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

print_header "3. Configuring Azure Pipelines agent..."

./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "$AZP_URL" \
  --auth PAT \
  --token $(cat "$AZP_TOKEN_FILE") \
  --pool "${AZP_POOL:-Default}" \
  --work "${AZP_WORK:-_work}" \
  --replace \
  --acceptTeeEula & wait $!

# remove the administrative token before accepting work
rm $AZP_TOKEN_FILE

print_header "4. Running Azure Pipelines agent..."

# `exec` the node runtime so it's aware of TERM and INT signals
# AgentService.js understands how to handle agent self-update and restart
exec ./externals/node/bin/node ./bin/AgentService.js interactive
