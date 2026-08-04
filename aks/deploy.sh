#!/bin/bash
# Deploy a self-hosted Azure DevOps build agent on AKS using Managed Identity.
#
# Managed Identity (recommended):
#   - Enable the managed identity on the AKS node pool (system-assigned) or attach a
#     user-assigned managed identity to it.
#   - Add the identity to the Azure DevOps organization under Organization Settings > Users
#     and grant it the required project/pipeline permissions.
#   - Set AZP_CLIENT_ID in build-agent.yml to the client ID if using a user-assigned identity.
#
# PAT fallback (optional):
#   - To use a Personal Access Token instead, uncomment and set AZP_TOKEN below, then
#     uncomment the AZP_TOKEN env var section in build-agent.yml.
#   - AZP_TOKEN=<your-pat-here>

AKS_NAME="build-agents-aks"
AKS_GROUP="Test-AKS"
AKS_REGION="westeurope"

echo "Resource Group deploy"

az group create --location $AKS_REGION --name $AKS_GROUP

echo "AKS deploy"

az deployment group create --resource-group $AKS_GROUP -f azure/azuredeploy.json --parameters aksClusterName=$AKS_NAME

echo "Storing new credentials"

rm ~/.kube/config

az aks get-credentials --resource-group $AKS_GROUP --name $AKS_NAME

# Uncomment the following lines if using PAT authentication instead of managed identity:
# echo "Secret deploy"
# kubectl create secret generic devops-secrets --from-literal=AZP_TOKEN=$AZP_TOKEN

echo "Pod deploy"

kubectl apply -f build-agent.yml

kubectl logs --follow deployments/devops-agent