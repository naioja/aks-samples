# 1. BYO Kublet Identity

# Create an Azure resource group
az group create --name myResourceGroup --location westus2

az identity create --name myIdentity --resource-group myResourceGroup
az identity create --name kubeletIdentity --resource-group myResourceGroup

az aks create \
    --resource-group myResourceGroup \
    --name myManagedCluster \
    --network-plugin azure \
    --enable-managed-identity \
    --assign-identity <identity-resource-id> \
    --assign-kubelet-identity <kubelet-identity-resource-id>
