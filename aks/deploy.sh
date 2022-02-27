#!/bin/bash
AKS_NAME="build-agents-aks"
AKS_GROUP="Test-AKS"
AKS_REGION="westeurope"

az group create --location $AKS_REGION --name $AKS_GROUP

az deployment group create --resource-group $AKS_GROUP -f azure/azuredeploy.json --parameters aksClusterName=$AKS_NAME

cat ~/.kube/config

az aks get-credentials --resource-group $AKS_GROUP --name $AKS_NAME

kubectl get service

# az aks command invoke -g <resourceGroup> -n <clusterName> -c "kubectl get pods -n kube-system"
# az aks command invoke -g <resourceGroup> -n <clusterName> -c "kubectl apply -f deployment.yaml -n default" -f deployment.yaml