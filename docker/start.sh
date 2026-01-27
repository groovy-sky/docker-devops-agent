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
  # Attempt managed identity token retrieval to validate IMDS availability
  MI_TOKEN_RESPONSE=$(curl -sS \
    -H "Metadata: true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=499b84ac-1321-427f-aa17-267ca6975798") || true

  if ! echo "$MI_TOKEN_RESPONSE" | jq -e '.access_token' >/dev/null 2>&1; then
    echo 1>&2 "error: missing AZP_TOKEN environment variable and managed identity endpoint is not available"
    exit 1
  fi

  AZP_TOKEN=$(echo "$MI_TOKEN_RESPONSE" | jq -r '.access_token')
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

print_header "1. Determining matching Azure Pipelines agent..."

REPO="microsoft/azure-pipelines-agent"
ARCH="linux-x64"   # linux-x64, linux-arm64, osx-x64, win-x64

VERSION=$(
  curl -s "https://api.github.com/repos/$REPO/releases/latest" \
    | jq -r '.tag_name'
)

VERSION="${VERSION#v}"

if [ -z "$VERSION" ] || [ "$VERSION" == "null" ]; then
  echo 1>&2 "error: could not determine a matching Azure Pipelines agent version from GitHub releases"
  exit 1
fi

BASE_URL="https://download.agent.dev.azure.com/agent/$VERSION"
FILE="vsts-agent-$ARCH-$VERSION.tar.gz"
AZP_AGENTPACKAGE_URL="$BASE_URL/$FILE"

print_header "2. Downloading and installing Azure Pipelines agent..."

curl -LsS "$AZP_AGENTPACKAGE_URL" | tar -xz & wait $!

source ./env.sh

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

print_header "3. Configuring Azure Pipelines agent..."

echo "Debug: uname -m = $(uname -m)"
echo "Debug: uname -s = $(uname -s)"
echo "Debug: OS release = $(cat /etc/os-release 2>/dev/null | tr '\n' ' ')"
echo "Debug: Agent.Listener file info:"
file ./bin/Agent.Listener || true
echo "Debug: Agent.Listener ldd output (if available):"
ldd ./bin/Agent.Listener 2>/dev/null || true

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
