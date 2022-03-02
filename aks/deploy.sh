#!/bin/bash
AKS_NAME="build-agents-aks"
AKS_GROUP="Test-AKS"
AKS_REGION="westeurope"
AZP_TOKEN=put-pat-value-here

echo "Resource Group deploy"

az group create --location $AKS_REGION --name $AKS_GROUP

echo "AKS deploy"

az deployment group create --resource-group $AKS_GROUP -f azure/azuredeploy.json --parameters aksClusterName=$AKS_NAME

echo "Storing new credentials"

rm ~/.kube/config

az aks get-credentials --resource-group $AKS_GROUP --name $AKS_NAME

echo "Secret deploy"

kubectl create secret generic devops-secrets --from-literal=AZP_TOKEN=$AZP_TOKEN

echo "Pod deploy"

kubectl apply -f build-agent.yml

kubectl logs --follow deployments/devops-agent