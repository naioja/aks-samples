#/bin/bash

#
# Script to quickly install a fully private AKS cluster
# with a linux box to server as a gateway
# and another linux box to server as a development host
#

set -x

echo "This script is a demo and comes AS-IS without any support. This should NOT be for any production purposes"
sleep 5;

#
# General Resource Group settings
#
RAND="$(python3 -c "LENGTH=5;from secrets import choice;from string import ascii_lowercase; print(''.join([choice(ascii_lowercase.strip()) for i in range(LENGTH)]))")"
LOCATION="switzerlandnorth"
RG_NAME="aks-private-rg-${RAND}"
SP_NAME="aks-private-sp-${RAND}"

UDR_NAME="custom-quad0-udr"
PUBLIC_IP_NAME="gw-public-ip"

HUB_VNET_NAME="hub-vnet"
HUB_VNET_ADDRESS_PREFIXES="10.43.0.0/16"

SPOKE_AKS_VNET_NAME="spoke-aks-vnet"
SPOKE_AKS_ADDRESS_PREFIXES="10.42.0.0/16"

#
# Linux NAT Gateway settings
#
GW_SUBNET_NAME="gw-subnet"
GW_SSH='~/.ssh/id_rsa.pub'
GW_USERNAME="admn"
GW_VM_NAME="gw-linux01"
GW_SUBNET_PREFIX="10.43.1.0/24"
GW_SUBNET_NAME="gw-subnet"
GW_VM_SIZE="Standard_B2s"

#
# AKS Cluster settings
#
AKS_NAME="aks-private-cluster"
AKS_USERVM_SIZE="Standard_B2ms"
AKS_SYSVM_SIZE="Standard_B2s"
AKS_SUBNET_NAME="aks-subnet"
AKS_SUBNET_PREFIX="10.42.1.0/24"
AKS_VERSION="1.16.13"
AKS_NETWORK_PLUGIN="kubenet"
AKS_NETWORK_POLICY_PLUGIN="calico"
AKS_NODEPOOL_NAME="nodepool1"
AKS_MC_NAME="MC-$AKS_NAME"

#
# Development VM settings
# (can execute kubectl commands on the private cluster)
#
TEST_VM_SUBNET_NAME="test-vm-subnet"
TEST_VM_SSH='~/.ssh/id_rsa.pub'
TEST_VM_USERNAME="admn"
TEST_VM_NAME="dev-linux01"
TEST_VM_SUBNET_PREFIX="10.42.2.0/24"
TEST_VM_VM_SIZE="Standard_B2s"


#1. Create resource group
az group create --resource-group $RG_NAME --location $LOCATION

#2. VNet
#2a. Create Hub Vnet and Gw Subnet
az network vnet create \
    --resource-group $RG_NAME \
    --location $LOCATION \
    --name $HUB_VNET_NAME \
    --address-prefixes $HUB_VNET_ADDRESS_PREFIXES \
    --subnet-name $GW_SUBNET_NAME \
    --subnet-prefix $GW_SUBNET_PREFIX

#3. Create Custom UDR
az network route-table create \
    --name $UDR_NAME \
    --resource-group $RG_NAME \
    --location $LOCATION

#3a. Add 0.0.0.0/0 route to Custom UDR (next hop Linux NAT Gw)
az network route-table route create \
    --resource-group $RG_NAME \
    --route-table-name $UDR_NAME \
    --name Quad0 \
    --next-hop-type VirtualAppliance --address-prefix 0.0.0.0/0 --next-hop-ip-address 10.43.1.4

#4. Create Spoke Vnet and AKS Subnets
az network vnet create \
    --resource-group $RG_NAME \
    --location $LOCATION \
    --name $SPOKE_AKS_VNET_NAME \
    --address-prefixes $SPOKE_AKS_ADDRESS_PREFIXES \
    --subnet-name $AKS_SUBNET_NAME \
    --subnet-prefix $AKS_SUBNET_PREFIX

#4a. Add UDR to AKS Subnet
az network vnet subnet update \
    --resource-group $RG_NAME \
    --name $AKS_SUBNET_NAME \
    --vnet-name $SPOKE_AKS_VNET_NAME \
    --route-table $UDR_NAME

#4b. Create Dev VM Subnet with custom UDR
az network vnet subnet create \
    --address-prefixes $TEST_VM_SUBNET_PREFIX \
    --name $TEST_VM_SUBNET_NAME \
    --resource-group $RG_NAME \
    --route-table $UDR_NAME \
    --vnet-name $SPOKE_AKS_VNET_NAME

#4c. Create Hub Vnet to Spoke Vnet peering
az network vnet peering create \
    --name hub-to-spoke-peering \
    --resource-group $RG_NAME \
    --vnet-name $HUB_VNET_NAME \
    --remote-vnet $SPOKE_AKS_VNET_NAME \
    --allow-vnet-access

#4d. Create Spoke Vnet to Hub Vnet peering
az network vnet peering create \
    --name spoke-to-hub-peering \
    --resource-group $RG_NAME \
    --vnet-name $SPOKE_AKS_VNET_NAME \
    --remote-vnet $HUB_VNET_NAME \
    --allow-vnet-access

#
# Set working variables
#
HUB_VNET_ID=$(az network vnet show --resource-group $RG_NAME --name $HUB_VNET_NAME --query id -o tsv)
SPOKE_AKS_VNET_ID=$(az network vnet show --resource-group $RG_NAME --name $SPOKE_AKS_VNET_NAME --query id -o tsv)
UDR_ID=$(az network route-table show --resource-group $RG_NAME --name $UDR_NAME --query id -o tsv)
AKS_SUBNET_ID=$(az network vnet subnet show --resource-group  $RG_NAME --vnet-name $SPOKE_AKS_VNET_NAME --name $AKS_SUBNET_NAME --query id -o tsv)
GW_SUBNET_ID=$(az network vnet subnet show --resource-group  $RG_NAME --vnet-name $HUB_VNET_NAME --name $GW_SUBNET_NAME --query id -o tsv)

#5. Create SP
az ad sp create-for-rbac --name $SP_NAME --skip-assignment > $SP_NAME-$RG_NAME-output.txt
AZURE_CLIENT_ID=$(grep appId $SP_NAME-$RG_NAME-output.txt | cut -f4 -d"\"")
AZURE_CLIENT_SECRET=$(grep password $SP_NAME-$RG_NAME-output.txt | cut -f4 -d"\"")

echo "Waiting 30 seconds for the SP to be propagated"
sleep 30

#6. Assign SP rights on VNet + UDR
az role assignment create --assignee $AZURE_CLIENT_ID --scope $SPOKE_AKS_VNET_ID --role "Network Contributor"
az role assignment create --assignee $AZURE_CLIENT_ID --scope $UDR_ID --role "Contributor"

#7. Create Static Public IP for Linux NAT Gw
az network public-ip create --resource-group $RG_NAME --name $PUBLIC_IP_NAME --location $LOCATION
az network public-ip update --resource-group $RG_NAME --name $PUBLIC_IP_NAME --allocation-method static

#8. Create NSG for Linux NAT Gw
az network nsg create \
    --name myNetworkSecurityGroup \
    --resource-group $RG_NAME \
    --location $LOCATION

#8a. Create NSG rule to allow Spoke Subnet to communicate with the Linux NAT Gw
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name myNetworkSecurityGroup \
    --name allow_spoke_aks_vnet_addr_pref \
    --priority 100 \
    --access Allow \
    --destination-address-prefixes '*' \
    --destination-port-ranges '*' \
    --direction Inbound \
    --protocol '*' \
    --source-address-prefixes "$SPOKE_AKS_ADDRESS_PREFIXES" \
    --description 'Allow inbound access to our firewall box from the AKS spoke vnet address prefix' \
    --source-port-ranges '*'

#8a. Create NSG rule to allow port 22 for management
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name myNetworkSecurityGroup \
    --name allow_ssh \
    --priority 101 \
    --destination-port-ranges 22

#8b. Create NSG rule to allow port 2222 used for DNAT to our Dev VM
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name myNetworkSecurityGroup \
    --name allow_ssh_to_test_vm \
    --priority 102 \
    --destination-port-ranges 2222

#8c. Create Nic with NSG and IP Forward
az network nic create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name myNic1 \
    --ip-forwarding true \
    --vnet-name $HUB_VNET_NAME \
    --subnet $GW_SUBNET_NAME \
    --network-security-group myNetworkSecurityGroup

#9. Create cloud-init file
cat << EOF > cloud-init.txt
#cloud-config
package_upgrade: true
packages:
  - nload
  - iptables-persistent
EOF

#10. Create Linux NAT Gw VM
az vm create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name $GW_VM_NAME \
    --nics myNic1 \
    --size $GW_VM_SIZE \
    --admin-username $GW_USERNAME \
    --authentication-type ssh \
    --custom-data cloud-init.txt \
    --ssh-key-values $GW_SSH \
    --image UbuntuLTS

#10a. Update the NIC and attach Public IP
az network nic ip-config update \
  --name ipconfig1 \
  --nic-name myNic1 \
  --resource-group $RG_NAME \
  --public-ip-address $PUBLIC_IP_NAME

#10b. Set working variable
SSH_IP=$(az network public-ip show --resource-group $RG_NAME --name $PUBLIC_IP_NAME --query ipAddress -o tsv)

#11. Configure Linux NAT Gw as firewall
export ANSIBLE_HOST_KEY_CHECKING="False"
ansible all -i "$SSH_IP," -m ping -u admn
ansible all -i "$SSH_IP," -m shell -b -u admn -a "sysctl -w net.ipv4.ip_forward=1; echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"
ansible all -i "$SSH_IP," -m shell -b -u admn -a "iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ansible all -i "$SSH_IP," -m shell -b -u admn -a "iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 2222 -j DNAT --to-destination 10.42.2.4:22"
ansible all -i "$SSH_IP," -m shell -b -u admn -a "iptables -A FORWARD -i eth0 -o eth0 -p tcp --syn --dport 2222 -m conntrack --ctstate NEW -j ACCEPT"
ansible all -i "$SSH_IP," -m raw -b -u admn -a "iptables-save > /etc/iptables/rules.v4"
ansible all -i "$SSH_IP," -m shell -b -u admn -a 'echo "/sbin/iptables-restore < /etc/iptables/rules.v4" >> /etc/rc.local'

echo "Please allow upto 15 minutes for the creation of the AKS cluster"

#12. Create AKS cluster
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
    --service-cidr 10.41.0.0/16 \
    --dns-service-ip 10.41.0.10 \
    --docker-bridge-address 172.17.0.1/16 \
    --vnet-subnet-id $AKS_SUBNET_ID \
    --outbound-type userDefinedRouting \
    --generate-ssh-keys \
    --vm-set-type VirtualMachineScaleSets \
    --service-principal $AZURE_CLIENT_ID \
    --client-secret $AZURE_CLIENT_SECRET

#13. Create NSG for Dev VM
az network nsg create \
    --name ${TEST_VM_NAME}-NSG \
    --resource-group $RG_NAME \
    --location $LOCATION

#13a. Add rules to Dev VM NSG
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name ${TEST_VM_NAME}-NSG \
    --name allow_ssh \
    --priority 101 \
    --destination-port-ranges 22

#14. Create Dev VM Nic with NSG
az network nic create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name ${TEST_VM_NAME}-Nic1 \
    --vnet-name $SPOKE_AKS_VNET_NAME \
    --subnet $TEST_VM_SUBNET_NAME \
    --network-security-group ${TEST_VM_NAME}-NSG

cat << EOF > cloud-init-dev.txt
#cloud-config
package_upgrade: true
packages:
  - docker.io
EOF

#15. Spawn Linux Dev VM
az vm create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name $TEST_VM_NAME \
    --nics ${TEST_VM_NAME}-Nic1 \
    --size $TEST_VM_VM_SIZE \
    --admin-username $TEST_VM_USERNAME \
    --authentication-type ssh \
    --ssh-key-values $TEST_VM_SSH \
    --custom-data cloud-init-dev.txt \
    --image UbuntuLTS

#16. Configure Linux Dev VM
export ANSIBLE_HOST_KEY_CHECKING="False"
ansible all -i "$SSH_IP:2222," -m ping -u admn
ansible all -i "$SSH_IP:2222," -m shell -b -u admn -a 'curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"'
ansible all -i "$SSH_IP:2222," -m shell -b -u admn -a 'mv kubectl /bin/kubectl ; chmod +x /bin/kubectl'
ansible all -i "$SSH_IP:2222," -m shell -b -u admn -a 'curl -sL https://aka.ms/InstallAzureCLIDeb | bash'
ansible all -i "$SSH_IP:2222," -m shell -b -u admn -a 'usermod -aG docker admn'
ansible all -i "$SSH_IP:2222," -m shell -u admn -a 'docker pull nginx;docker pull hello-world'
##### Login from the vm user account to your azure subscription
# az login
# az account set --subscription "Azure CXP FTA Internal Subscription AJOIAN"
# ansible all -i "$TEST_VM_SSH_IP," -m shell -u admn -a "az aks get-credentials -n $AKS_NAME -g $RG_NAME --admin"
# ansible all -i "$TEST_VM_SSH_IP," -m shell -u admn -a "/bin/kubectl get nodes"

# https://docs.microsoft.com/en-us/azure/aks/cluster-container-registry-integration
# https://docs.microsoft.com/en-us/azure/container-registry/container-registry-private-link
# https://docs.microsoft.com/en-us/azure/container-registry/container-registry-get-started-docker-cli

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

