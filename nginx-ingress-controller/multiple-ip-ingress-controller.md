# This is an example of one nginx ingress controller installation in AKS using two different IP classes

1. Create the static public IP address in the AKS managed resource group using the Standard SKU:

```bash
#The above commands create an IP address that will be deleted if you delete your AKS cluster. 
#Alternatively, you can create an IP address in a different resource group which can be 
#managed separately from your AKS cluster. If you create an IP address in a different resource group, 
#ensure the service principal used by the AKS cluster has delegated permissions to the other resource group, 
#such as Network Contributor.

az network public-ip create \
    --resource-group MC_myResourceGroup_myAKSCluster_eastus \
    --name ingress-pub-ipaddress \
    --sku Standard \
    --allocation-method static \
    --query publicIp.ipAddress -o tsv
```
2. Create your AKS ingress namespace:

```
kubectl create namespace ingress-basic
```

3. Deploy the ingress controller using a static pre-provisioned public IP address as well as a secondary internal IP located on an Azure ILB:

```bash
# The specified IP address must reside in the same subnet as the AKS cluster and 
# must not already be assigned to a resource
STATIC_PRV_IP='10.240.0.4'

# Populating the variable with the value of the public IP address created earlier
STATIC_PUB_IP=$(az network public-ip show \
  --resource-group MC_policy-rg_policy-aks_westeurope \
  --name ingress-pub-ipaddress --query ipAddress -o tsv)

# Meaningful dns name for your project
DNS_LABEL='fta-team'

# Contents of internal-ingress.yaml file is a bit different when deploying as a secondary IP 
cat <<EOF > internal-ingress2.yaml
controller:
  loadBalancerIP: $STATIC_PRV_IP
  service:
    internal:
      enabled: true
      annotations:
        service.beta.kubernetes.io/azure-load-balancer-internal: "true"
EOF

helm install nginx-ingress ingress-nginx/ingress-nginx \
    --namespace ingress-basic \
    --set controller.replicaCount=1 \
    --set controller.service.externalTrafficPolicy=Local \
    --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux  \
    --set controller.service.loadBalancerIP="$STATIC_PUB_IP" \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"="$DNS_LABEL"
    -f internal-ingress.yaml
```

4. Resouces :
- https://docs.microsoft.com/en-us/azure/aks/ingress-internal-ip
- https://docs.microsoft.com/en-us/azure/aks/ingress-static-ip
- https://docs.microsoft.com/en-us/azure/aks/static-ip