#Deploy a cluster

az group create \
    -l <Region> \
    -n <ResourceGroupName>

az aks create \
    -l <Region> \
    -g <ResourceGroupName> \
    -n <ClusterName> \
    --network-plugin none

# Deploy a CNI plugin
# Install cilium cli
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz{,.sha256sum}

# Install CNI
cilium install --azure-resource-group rg-aks-byo-cni --datapath-mode vxlan --ipam=cluster-pool --config cluster-pool-ipv4-cidr=10.240.0.0/16 --config cluster-pool-ipv4-mask-size=24

cilium status --wait

