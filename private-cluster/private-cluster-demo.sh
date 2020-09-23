#/bin/bash

#
# Script to quickly install a fully private AKS cluster
# with a linux box to server as a gateway
# and another linux box to server as a bastion host
#


echo "This script is a demo and comes AS-IS without any support. This should NOT be for any production purposes"
sleep 5;

set -x

RAND="$(openssl rand -hex 5)"

LOCATION="westeurope"
RG_NAME="aks-demo-rg-${RAND}"
SP_NAME="aks-demo-sp-${RAND}"

UDR_NAME="custom-udr"
PUBLIC_IP_NAME="gw-public-ip"

VNET_NAME="demo-vnet"
VNET_ADDRESS_PREFIXES="192.168.0.0/16"

GW_SUBNET_NAME="gw-subnet"
GW_SSH='~/.ssh/id_rsa.pub'
GW_USERNAME="admn"
GW_VM_NAME="gw-linux01"
GW_SUBNET_PREFIX="192.168.2.0/24"
GW_SUBNET_NAME="gw-subnet"
GW_VM_SIZE="Standard_B2s"

AKS_NAME="aks-demo-cluster"
AKS_USERVM_SIZE="Standard_B2ms"
AKS_SYSVM_SIZE="Standard_B2s"
AKS_SUBNET_NAME="aks-subnet"
AKS_SUBNET_PREFIX="192.168.1.0/24"
AKS_VERSION="1.16.13"
AKS_NETWORK_PLUGIN="kubenet"
AKS_NETWORK_POLICY_PLUGIN="calico"
AKS_NODEPOOL_NAME="nodepool1"
AKS_MC_NAME="MC-$AKS_NAME"

#
# Development VM that can execute kubectl commands on the cluster
#
TEST_VM_SUBNET_NAME="test-vm-subnet"
TEST_VM_SSH='~/.ssh/id_rsa.pub'
TEST_VM_USERNAME="admn"
TEST_VM_NAME="test-vm-linux01"
TEST_VM_SUBNET_PREFIX="192.168.3.0/24"
TEST_VM_VM_SIZE="Standard_B2s"
TEST_VM_PUBLIC_IP_NAME="test-vm-public-ip"


#1. resource group
az group create --resource-group $RG_NAME --location $LOCATION

#2. VNet
#3. Subnets
az network vnet create \
    --resource-group $RG_NAME \
    --location $LOCATION \
    --name $VNET_NAME \
    --address-prefixes $VNET_ADDRESS_PREFIXES \
    --subnet-name $GW_SUBNET_NAME \
    --subnet-prefix $GW_SUBNET_PREFIX

#4. UDR
az network route-table create \
    --name $UDR_NAME \
    --resource-group $RG_NAME \
    --location $LOCATION

#4a. ADD 0.0.0.0/0
az network route-table route create \
    --resource-group $RG_NAME \
    --route-table-name $UDR_NAME \
    --name Quad0 \
    --next-hop-type VirtualAppliance --address-prefix 0.0.0.0/0 --next-hop-ip-address 192.168.1.4

#4b. ADD UDR to subnet
az network vnet subnet create \
    --address-prefixes $AKS_SUBNET_PREFIX \
    --name $AKS_SUBNET_NAME \
    --resource-group $RG_NAME \
    --vnet-name $VNET_NAME \
    --route-table $UDR_NAME

#4c. ADD TEST VM to subnet
az network vnet subnet create \
    --address-prefixes $TEST_VM_SUBNET_PREFIX \
    --name $TEST_VM_SUBNET_NAME \
    --resource-group $RG_NAME \
    --vnet-name $VNET_NAME

VNET_ID=$(az network vnet show --resource-group $RG_NAME --name $VNET_NAME --query id -o tsv)
UDR_ID=$(az network route-table show --resource-group $RG_NAME --name $UDR_NAME --query id -o tsv)
AKS_SUBNET_ID=$(az network vnet subnet show --resource-group  $RG_NAME --vnet-name $VNET_NAME --name $AKS_SUBNET_NAME --query id -o tsv)
GW_SUBNET_ID=$(az network vnet subnet show --resource-group  $RG_NAME --vnet-name $VNET_NAME --name $GW_SUBNET_NAME --query id -o tsv)

#5. SP
az ad sp create-for-rbac --name $SP_NAME --skip-assignment > $SP_NAME-$RG_NAME-output.txt
AZURE_CLIENT_ID=$(grep appId $SP_NAME-$RG_NAME-output.txt | cut -f4 -d"\"")
AZURE_CLIENT_SECRET=$(grep password $SP_NAME-$RG_NAME-output.txt | cut -f4 -d"\"")

echo "Waiting 30 seconds for the SP to be propagated"
sleep 30

#6. SP rights on VNet + UDR
az role assignment create --assignee $AZURE_CLIENT_ID --scope $VNET_ID --role "Network Contributor"
az role assignment create --assignee $AZURE_CLIENT_ID --scope $UDR_ID --role "Contributor"

#7. Linux VM + static Public IP
#7a. add second interface in AKS subnet
#7b. Kernel network forward
#7c. iptables rules + persistancy
az network public-ip create --resource-group $RG_NAME --name $PUBLIC_IP_NAME --location $LOCATION
az network public-ip update --resource-group $RG_NAME --name $PUBLIC_IP_NAME --allocation-method static

az network nsg create \
    --name myNetworkSecurityGroup \
    --resource-group $RG_NAME \
    --location $LOCATION

az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name myNetworkSecurityGroup \
    --name allow_ssh \
    --priority 101 \
    --destination-port-ranges 22

az network nic create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name myNic1 \
    --vnet-name $VNET_NAME \
    --subnet $GW_SUBNET_NAME \
    --network-security-group myNetworkSecurityGroup

az network nic create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name myNic2 \
    --vnet-name $VNET_NAME \
    --subnet $AKS_SUBNET_NAME \
    --network-security-group myNetworkSecurityGroup

cat << EOF > cloud-init.txt
#cloud-config
package_upgrade: true
packages:
  -  nload
  - iptables-persistent
EOF

az vm create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name $GW_VM_NAME \
    --nics myNic1 myNic2 \
    --size $GW_VM_SIZE \
    --admin-username $GW_USERNAME \
    --authentication-type ssh \
    --custom-data cloud-init.txt \
    --ssh-key-values $GW_SSH \
    --image UbuntuLTS

az network nic ip-config update -g $RG_NAME --nic-name myNic1 \
    -n ipconfig1 --make-primary

az network nic ip-config update \
  --name ipconfig1 \
  --nic-name myNic1 \
  --resource-group $RG_NAME \
  --public-ip-address $PUBLIC_IP_NAME

SSH_IP=$(az network public-ip show --resource-group $RG_NAME --name $PUBLIC_IP_NAME --query ipAddress -o tsv)

export ANSIBLE_HOST_KEY_CHECKING="False"

ansible all -i "$SSH_IP," -m ping -u admn
ansible all -i "$SSH_IP," -m shell -b -u admn -a "sysctl -w net.ipv4.ip_forward=1; echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"
ansible all -i "$SSH_IP," -m shell -b -u admn -a "iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ansible all -i "$SSH_IP," -m raw -b -u admn -a "iptables-save > /etc/iptables/rules.v4"
ansible all -i "$SSH_IP," -m shell -b -u admn -a 'echo "/sbin/iptables-restore < /etc/iptables/rules.v4" >> /etc/rc.local'

echo "Please allow upto 15 minutes for the creation of the AKS cluster"

#8. AKS cluster
az aks create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name $AKS_NAME \
    --enable-aad \
    --enable-private-cluster \
    --enable-cluster-autoscaler \
    --node-count 1 \
    --min-count 1 \
    --max-count 3 \
    --nodepool-name $AKS_NODEPOOL_NAME \
    --node-resource-group $AKS_MC_NAME \
    --node-vm-size $AKS_USERVM_SIZE \
    --kubernetes-version $AKS_VERSION \
    --network-plugin $AKS_NETWORK_PLUGIN \
    --network-policy $AKS_NETWORK_POLICY_PLUGIN \
    --service-cidr 10.0.0.0/16 \
    --dns-service-ip 10.0.0.10 \
    --pod-cidr 10.244.0.0/16 \
    --docker-bridge-address 172.17.0.1/16 \
    --vnet-subnet-id $AKS_SUBNET_ID \
    --outbound-type userDefinedRouting \
    --generate-ssh-keys \
    --vm-set-type VirtualMachineScaleSets \
    --service-principal $AZURE_CLIENT_ID \
    --client-secret $AZURE_CLIENT_SECRET

#9. Linux VM + static Public IP
#9a. add second interface in AKS subnet
#9b. Kernel network forward
#9c. iptables rules + persistancy
az network public-ip create --resource-group $RG_NAME --name $TEST_VM_PUBLIC_IP_NAME --location $LOCATION
az network public-ip update --resource-group $RG_NAME --name $TEST_VM_PUBLIC_IP_NAME --allocation-method static

az network nsg create \
    --name ${TEST_VM_NAME}-NSG \
    --resource-group $RG_NAME \
    --location $LOCATION

az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name ${TEST_VM_NAME}-NSG \
    --name allow_ssh \
    --priority 101 \
    --destination-port-ranges 22

az network nic create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name ${TEST_VM_NAME}-Nic1 \
    --vnet-name $VNET_NAME \
    --subnet $TEST_VM_SUBNET_NAME \
    --network-security-group ${TEST_VM_NAME}-NSG

az vm create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name $TEST_VM_NAME \
    --nics ${TEST_VM_NAME}-Nic1 \
    --size $TEST_VM_VM_SIZE \
    --admin-username $TEST_VM_USERNAME \
    --authentication-type ssh \
    --ssh-key-values $TEST_VM_SSH \
    --image UbuntuLTS

TEST_VM_SSH_IP=$(az network public-ip show --resource-group $RG_NAME --name $PUBLIC_IP_NAME --query ipAddress -o tsv)
export ANSIBLE_HOST_KEY_CHECKING="False"
ansible all -i "$TEST_VM_SSH_IP," -m ping -u admn
ansible all -i "$TEST_VM_SSH_IP," -m shell -b -u admn -a 'curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"'
ansible all -i "$TEST_VM_SSH_IP," -m shell -b -u admn -a 'mv kubectl /bin/kubectl ; chmod +x /bin/kubectl'
ansible all -i "$TEST_VM_SSH_IP," -m shell -b -u admn -a 'curl -sL https://aka.ms/InstallAzureCLIDeb | bash'
##### Login to your VM
ansible all -i "$TEST_VM_SSH_IP," -m shell -u admn -a "az aks get-credentials -n $AKS_NAME -g $RG_NAME --admin"
ansible all -i "$TEST_VM_SSH_IP," -m shell -u admn -a "/bin/kubectl get nodes"

read -n1 -r -p "Press SPACE to finish the deployment or ANY OTHER KEY TO DELETE" key

if [ "$key" = '' ]; then
    # Space pressed, do something
    # echo [$key] is empty when SPACE is pressed # uncomment to trace
    echo -e "\n Done"
    exit 0
else
    # Anything else pressed, do whatever else.
    # echo [$key] not empty
    az group delete -n $AKS_MC_NAME --yes --no-wait
    az group delete -n $RG_NAME --yes --no-wait
    az ad sp delete --id $AZURE_CLIENT_ID
    rm $SP_NAME-$RG_NAME-output.txt
fi
