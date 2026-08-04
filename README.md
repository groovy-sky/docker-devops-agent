# Running a self-hosted build agent on Azure Container Instance

This document gives an example of using Azure Container Instance as Azure DevOps pipelines build agent. **Detailed instruction how-to run you can find** [here](https://github.com/groovy-sky/azure/tree/master/devops-docker-build-00).

---

## Managed Identity Authentication (Recommended)

Starting with the current version, the agent supports **Azure Managed Identity** for authentication with Azure DevOps, eliminating the need to manage Personal Access Tokens (PATs).

Managed identity is only available when the container is deployed on an **Azure resource that has an assigned managed identity** (e.g. Azure Container Instance, AKS node pool) and the identity has been granted permissions in Azure DevOps.

### How It Works

At startup, if `AZP_TOKEN` is not set, the agent automatically:
1. Calls the Azure Instance Metadata Service (IMDS) endpoint inside the container:
   ```
   http://169.254.169.254/metadata/identity/oauth2/token
     ?api-version=2018-02-01
     &resource=499b84ac-1321-427f-aa17-267ca6975798
   ```
2. Extracts the `access_token` from the response.
3. Uses the token as `Authorization: ****** for Azure DevOps API calls.

If `AZP_TOKEN` **is** set, the PAT is used instead (backward-compatible).

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
3. Search for your managed identity by name (for system-assigned) or by client ID (for user-assigned).
4. Assign **Basic** (or **Stakeholder**) access level.
5. Add to the project and configure granular permissions (e.g. read/write pipelines, repositories).

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `AZP_URL` | ✅ | Azure DevOps organization URL, e.g. `https://dev.azure.com/myorg` |
| `AZP_TOKEN` | ❌ | Personal Access Token. If set, used instead of managed identity. |
| `AZP_CLIENT_ID` | ❌ | Client ID of a **user-assigned** managed identity. If omitted, the system-assigned identity is used. |
| `AZP_POOL` | ❌ | Agent pool name (default: `Default`). |
| `AZP_AGENT_NAME` | ❌ | Agent display name (default: container hostname). |
| `AZP_WORK` | ❌ | Agent work directory (default: `_work`). |
| `AZP_AGENT_ONCE` | ❌ | Set to `true` to run a single job and exit (default: `false`). |

---

## Build & Run

### Build the Docker image

```bash
docker build -f docker/Dockerfile -t devops-agent:latest .
```

### Run with Managed Identity (Azure-hosted only)

```bash
docker run -e AZP_URL=https://dev.azure.com/myorg \
           -e AZP_POOL=Default \
           devops-agent:latest
```

### Run with User-Assigned Managed Identity

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
               AZP_POOL=Default
  # AZP_TOKEN and AZP_CLIENT_ID default to empty (managed identity mode)
```

The ARM template (`azure/azuredeploy.json`) enables a **system-assigned managed identity** on the Container Instance automatically.

---

## Deploy to AKS

See [`aks/deploy.sh`](aks/deploy.sh) and [`aks/build-agent.yml`](aks/build-agent.yml) for a full example.

```bash
cd aks
# Edit build-agent.yml: set AZP_URL and optionally AZP_CLIENT_ID
bash deploy.sh
```

---

## Migration from PAT

If you previously configured `AZP_TOKEN`:

- **Managed identity mode (recommended):** Remove `AZP_TOKEN` from your container/pod configuration. Assign a managed identity to your Azure resource and grant it Azure DevOps permissions as described above.
- **PAT mode (legacy):** Keep `AZP_TOKEN` set. The agent will continue to work exactly as before.

No changes to the Docker image or scripts are required for the PAT fallback path.

---

## Testing

Lightweight shell tests are provided in [`tests/test_managed_identity.sh`](tests/test_managed_identity.sh). They use mocked IMDS responses and do **not** require live Azure credentials:

```bash
bash tests/test_managed_identity.sh
```

