# Running a self-hosted build agent on Azure Container Instance

This document gives an example of using Azure Container Instance as Azure DevOps pipelines build agent. **Detailed instruction how-to run you can find** [here](https://github.com/groovy-sky/azure/tree/master/devops-docker-build-00).

---

## Authentication Modes

The agent startup script selects an authentication mode based on which environment variables are provided:

| Condition | Mode selected |
|---|---|
| `AZP_CLIENT_ID` is set (non-empty) | **Managed identity** — token is fetched from Azure IMDS using that client ID. If IMDS fails, the container exits with an error (no PAT fallback). |
| `AZP_TOKEN` is set (non-empty) | **PAT** — the Personal Access Token is used directly. |
| Neither is set | **Error** — the container exits immediately with a clear message. |

If both `AZP_CLIENT_ID` and `AZP_TOKEN` are set, **managed identity takes precedence** and `AZP_TOKEN` is ignored.

---

## Managed Identity Authentication (Recommended)

Managed identity is only available when the container is deployed on an **Azure resource that has an assigned managed identity** (e.g. Azure Container Instance, AKS node pool) and the identity has been granted permissions in Azure DevOps.

### How It Works

At startup, when `AZP_CLIENT_ID` is provided the container:
1. Calls the Azure Instance Metadata Service (IMDS) endpoint inside the container:
   ```
   http://169.254.169.254/metadata/identity/oauth2/token
     ?api-version=2019-08-01
     &resource=499b84ac-1321-427f-aa17-267ca6975798
     &client_id=<AZP_CLIENT_ID>
   ```
2. Extracts the `access_token` from the response.
3. Uses that Microsoft Entra access token to query the Azure DevOps agent package API and then registers the agent via `config.sh --auth PAT --token <token>`. The `PAT` flag name is the Azure Pipelines agent's historical CLI label; the supplied value in managed-identity mode is an Entra access token, not a personal access token.

If IMDS is unavailable or the identity is not configured, the container exits with an error. There is no automatic fallback to PAT.

---

## Azure Configuration

### Step 1: Assign a Managed Identity

**Azure Container Instance:**
- In the Azure Portal, open your Container Instance (or Container Group).
- Under **Settings → Identity**, enable **System-assigned** identity, or attach a **User-assigned** identity.

**AKS:**
- Enable the managed identity on the node pool, or attach a user-assigned identity to it.

### Step 2: Grant Permissions in Azure DevOps

1. Open your **Azure DevOps Organization Settings**.
2. Navigate to **Users** (under *General*) → **Add Users**.
3. Add the managed identity as a user in Azure DevOps (for example by display name for system-assigned identities, or by the backing service principal/user-assigned identity details in Microsoft Entra ID).
4. Assign an access level that allows agent registration and job execution.
5. Grant the identity permission to use the target agent pool and any project resources the builds require (repositories, variable groups, service connections, feeds, and so on).

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `AZP_URL` | ✅ | Azure DevOps organization URL, e.g. `https://dev.azure.com/myorg` |
| `AZP_CLIENT_ID` | ⚠️ | Client ID of a **user-assigned** managed identity. When set, managed identity mode is used exclusively (no PAT fallback). |
| `AZP_TOKEN` | ⚠️ | Personal Access Token. Used when `AZP_CLIENT_ID` is not set. |
| `AZP_POOL` | ❌ | Agent pool name (default: `Default`). |
| `AZP_AGENT_NAME` | ❌ | Agent display name (default: container hostname). |
| `AZP_WORK` | ❌ | Agent work directory (default: `_work`). |
| `AZP_AGENT_ONCE` | ❌ | Set to `true` to run a single job and exit (default: `false`). |

> ⚠️ At least one of `AZP_CLIENT_ID` or `AZP_TOKEN` must be provided; the container exits with an error if neither is set.

---

## Build & Run

### Build the Docker image

```bash
docker build -f docker/Dockerfile -t devops-agent:latest .
```

### Run with User-Assigned Managed Identity (Recommended)

> Important: a local Docker or Podman host outside Azure cannot reach Azure IMDS at `169.254.169.254`, so managed identity works only when the container runs on Azure compute that has the identity assigned.

```bash
docker run -e AZP_URL=https://dev.azure.com/myorg \
           -e AZP_POOL=Default \
           -e AZP_CLIENT_ID=<user-assigned-identity-client-id> \
           devops-agent:latest
```

### Run with PAT (local/non-Azure environment)

```bash
docker run -e AZP_URL=https://dev.azure.com/myorg \
           -e AZP_TOKEN=<your-pat> \
           -e AZP_POOL=Default \
           devops-agent:latest
```

---

## Deploy to Azure Container Instance

```bash
az deployment group create \
  --resource-group myResourceGroup \
  --template-file azure/azuredeploy.json \
  --parameters containerName=my-agent \
               imageName=gr00vysky/devops-agent:latest \
               AZP_URL=https://dev.azure.com/myorg \
               AZP_POOL=Default \
               AZP_CLIENT_ID=<user-assigned-identity-client-id>
```

The ARM template (`azure/azuredeploy.json`) enables a **system-assigned managed identity** on the Container Instance automatically.

---

## Deploy to AKS

See [`aks/deploy.sh`](aks/deploy.sh) and [`aks/build-agent.yml`](aks/build-agent.yml) for a full example.

```bash
cd aks
# Edit build-agent.yml: set AZP_URL and AZP_CLIENT_ID
bash deploy.sh
```

---

## Migration from PAT

If you previously configured `AZP_TOKEN`:

- **Managed identity mode (recommended):** Remove `AZP_TOKEN` from your container/pod configuration. Assign a managed identity to your Azure resource, grant it Azure DevOps permissions as described above, and set `AZP_CLIENT_ID` to the managed identity's client ID.
- **PAT mode:** Keep `AZP_TOKEN` set (and do not set `AZP_CLIENT_ID`). The agent will continue to work exactly as before.

`AZP_TOKEN_FILE` is no longer a supported input. If you previously relied on it, switch to `AZP_TOKEN` or managed identity.

---

## Testing

Lightweight shell tests are provided in [`tests/test_managed_identity.sh`](tests/test_managed_identity.sh). They validate the auth-mode selection logic and do **not** require live Azure credentials:

```bash
bash tests/test_managed_identity.sh
```

