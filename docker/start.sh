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

AZP_ARTIFACT_ORG="${AZP_ARTIFACT_ORG:-$AZP_URL}"

if [ -z "$AZP_ARTIFACT_FEED" ] || [ -z "$AZP_ARTIFACT_NAME" ] || [ -z "$AZP_ARTIFACT_TARBALL" ]; then
  echo 1>&2 "error: set AZP_ARTIFACT_FEED, AZP_ARTIFACT_NAME, and AZP_ARTIFACT_TARBALL"
  exit 1
fi

AZP_ARTIFACT_PROJECT_ARG=()
if [ -n "$AZP_ARTIFACT_PROJECT" ]; then
  AZP_ARTIFACT_PROJECT_ARG=(--project "$AZP_ARTIFACT_PROJECT")
fi

AZP_ROUTE_PARAMS=(feedId="$AZP_ARTIFACT_FEED")
if [ -n "$AZP_ARTIFACT_PROJECT" ]; then
  AZP_ROUTE_PARAMS+=(project="$AZP_ARTIFACT_PROJECT")
fi

AZP_PKG_LIST=$(az devops invoke \
  --organization "$AZP_ARTIFACT_ORG" \
  --area packaging \
  --resource packages \
  --route-parameters "${AZP_ROUTE_PARAMS[@]}" \
  --query-parameters packageNameQuery="$AZP_ARTIFACT_NAME" protocolType=upack \
  --api-version 7.1-preview.1 \
  -o json 2>/dev/null) || true

if ! echo "$AZP_PKG_LIST" | jq . >/dev/null 2>&1; then
  echo 1>&2 "error: invalid response from Azure DevOps when querying artifact packages"
  echo 1>&2 "$AZP_PKG_LIST"
  exit 1
fi

AZP_PACKAGE_ID=$(echo "$AZP_PKG_LIST" \
  | jq -r --arg name "$AZP_ARTIFACT_NAME" '.value[] | select(.name == $name) | .id' \
  | head -n 1)

if [ -z "$AZP_PACKAGE_ID" ]; then
  echo 1>&2 "error: package '$AZP_ARTIFACT_NAME' not found in feed '$AZP_ARTIFACT_FEED'"
  exit 1
fi

AZP_PKG_VERSIONS=$(az devops invoke \
  --organization "$AZP_ARTIFACT_ORG" \
  --area packaging \
  --resource versions \
  --route-parameters "${AZP_ROUTE_PARAMS[@]}" packageId="$AZP_PACKAGE_ID" \
  --query-parameters isDeleted=false \
  --api-version 7.1-preview.1 \
  -o json 2>/dev/null) || true

if ! echo "$AZP_PKG_VERSIONS" | jq . >/dev/null 2>&1; then
  echo 1>&2 "error: invalid response from Azure DevOps when querying artifact versions"
  echo 1>&2 "$AZP_PKG_VERSIONS"
  exit 1
fi

if [ -z "$AZP_ARTIFACT_VERSION" ]; then
  AZP_ARTIFACT_VERSION=$(echo "$AZP_PKG_VERSIONS" \
    | jq -r '.value[].version' \
    | sort -V \
    | tail -n 1)

  if [ -z "$AZP_ARTIFACT_VERSION" ]; then
    echo 1>&2 "error: no versions found for package '$AZP_ARTIFACT_NAME'"
    exit 1
  fi
else
  if ! echo "$AZP_PKG_VERSIONS" | jq -e --arg v "$AZP_ARTIFACT_VERSION" '.value[] | select(.version == $v)' >/dev/null 2>&1; then
    echo 1>&2 "error: version '$AZP_ARTIFACT_VERSION' not found for package '$AZP_ARTIFACT_NAME'"
    exit 1
  fi
fi

az artifacts universal download \
  --organization "$AZP_ARTIFACT_ORG" \
  "${AZP_ARTIFACT_PROJECT_ARG[@]}" \
  --feed "$AZP_ARTIFACT_FEED" \
  --name "$AZP_ARTIFACT_NAME" \
  --version "$AZP_ARTIFACT_VERSION" \
  --path /azp/agent

print_header "2. Installing Azure Pipelines agent..."

tar -xzf "/azp/agent/$AZP_ARTIFACT_TARBALL" -C /azp/agent

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
