# Azure CNI V2

resourceGroup="myResourceGroup"
vnet="myVirtualNetwork"
location="westcentralus"

# Create the resource group
az group create --name $resourceGroup --location $location

# Create our two subnet network 
az network vnet create \
    -g $resourceGroup \
    --location $location \
    --name $vnet \
    --address-prefixes 10.0.0.0/8 \
    -o none

az network vnet subnet create \
    -g $resourceGroup \
    --vnet-name $vnet \
    --name nodesubnet \
    --address-prefixes 10.240.0.0/16 \
    -o none

az network vnet subnet create \
    -g $resourceGroup \
    --vnet-name $vnet \
    --name podsubnet \
    --address-prefixes 10.241.0.0/16 \
    -o none

clusterName="myAKSCluster"
subscription="aaaaaaa-aaaaa-aaaaaa-aaaa"

az aks create \
    -n $clusterName \
    -g $resourceGroup \
    -l $location \
    --max-pods 250 \
    --node-count 2 \
    --network-plugin azure \
    --vnet-subnet-id /subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnet/subnets/nodesubnet \
    --pod-subnet-id /subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnet/subnets/podsubnet

az network vnet subnet create \
    -g $resourceGroup \
    --vnet-name $vnet \
    --name node2subnet \
    --address-prefixes 10.242.0.0/16 \
    -o none

az network vnet subnet create \
    -g $resourceGroup \
    --vnet-name $vnet \
    --name pod2subnet \
    --address-prefixes 10.243.0.0/16 \
    -o none 

az aks nodepool add \
    --cluster-name $clusterName \
    -g $resourceGroup \
    -n newnodepool \
    --max-pods 250 \
    --node-count 2 \
    --vnet-subnet-id /subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnet/subnets/node2subnet \
    --pod-subnet-id /subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnet/subnets/pod2subnet \
    --no-wait