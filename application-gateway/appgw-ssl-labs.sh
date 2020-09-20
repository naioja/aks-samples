#/bin/bash

DOMAIN_NAME="MY_CUSTOM_COMAINE_NAME"

LOCATION="eastus"
RG_NAME="app-gw-demo-rg$1"

APP_GW_PUBLIC_IP_NAME="app-gw-public-ip"
APP_GW_PUBLIC_IP_SKU="Standard"

WEB_VM_PUBLIC_IP_NAME="web-vm-public-ip"

VNET_NAME="demo-vnet"
VNET_ADDRESS_PREFIXES="10.0.0.0/16"

APP_GW_SUBNET_PREFIX="10.0.2.0/24"
APP_GW_SUBNET_NAME="appgw-subnet"
APP_GW_VM_SIZE="Standard_v2"
APP_GW_NAME="app-gw001"
APP_GW_CERT_PW='SUPER_SECURE_PASSWORD_HERE'


WEB_VM_NAME="web001"
WEB_VM_SIZE="Standard_B2s"
WEB_VM_SUBNET_NAME="web-subnet"
WEB_VM_SUBNET_PREFIX="10.0.1.0/24"
WEB_VM_SSH='~/.ssh/id_rsa.pub'
WEB_VM_USERNAME="admn"

USER_IP="$(curl https://hazip.azurewebsites.net)"


#1. resource group
az group create --resource-group $RG_NAME --location $LOCATION

#2. VNet Create

#3. Subnets create APP GW VM Subnet
az network vnet create \
    --resource-group $RG_NAME \
    --location $LOCATION \
    --name $VNET_NAME \
    --subnet-name $APP_GW_SUBNET_NAME \
    --address-prefixes $VNET_ADDRESS_PREFIXES \
    --subnet-prefix $APP_GW_SUBNET_PREFIX

#4. Subnet create WEB VM Subnet
az network vnet subnet create \
    --address-prefixes $WEB_VM_SUBNET_PREFIX \
    --name $WEB_VM_SUBNET_NAME \
    --resource-group $RG_NAME \
    --vnet-name $VNET_NAME

#7. Linux VM + static Public IP for management
az network public-ip create --resource-group $RG_NAME --name $WEB_VM_PUBLIC_IP_NAME
az network public-ip update --resource-group $RG_NAME --name $WEB_VM_PUBLIC_IP_NAME --allocation-method static

az network nsg create \
    --name myNetworkSecurityGroup \
    --resource-group $RG_NAME \
    --location $LOCATION

az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name myNetworkSecurityGroup \
    --name allow_ssh \
    --priority 101 \
    --protocol Tcp \
    --source-address-prefixes $USER_IP \ 
    --destination-port-ranges 22

az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name myNetworkSecurityGroup \
    --name allow_web \
    --priority 102 \
    --protocol Tcp \
    --source-address-prefixes $APP_GW_SUBNET_PREFIX \ 
    --destination-port-ranges 80

az network nic create \
    --resource-group $RG_NAME \
    --name myNic1 \
    --vnet-name $VNET_NAME \
    --subnet $WEB_VM_SUBNET_NAME \
    --network-security-group myNetworkSecurityGroup

cat << EOF > cloud-init.txt
#cloud-config
package_upgrade: true
packages:
  - nginx
EOF

az vm create \
    --location $LOCATION \
    --resource-group $RG_NAME \
    --name $WEB_VM_NAME \
    --nics myNic1 \
    --size $WEB_VM_SIZE \
    --admin-username $WEB_VM_USERNAME \
    --authentication-type ssh \
    --ssh-key-values $WEB_VM_SSH \
    --custom-data cloud-init.txt \
    --image UbuntuLTS

az network nic ip-config update -g $RG_NAME --nic-name myNic1 \
    -n ipconfig1 --make-primary

az network nic ip-config update \
  --name ipconfig1 \
  --nic-name myNic1 \
  --resource-group $RG_NAME \
  --public-ip-address $WEB_VM_PUBLIC_IP_NAME

SSH_IP=$(az network public-ip show --resource-group $RG_NAME --name $WEB_VM_PUBLIC_IP_NAME --query ipAddress -o tsv)
WEB_VM_address1=$(az network nic show --name myNic1 --resource-group $RG_NAME | grep "\"privateIpAddress\":" | grep -oE '[^ ]+$' | tr -d '",')

export ANSIBLE_HOST_KEY_CHECKING="False"
ansible all -i "$SSH_IP," -m ping -u admn

#
# Install APP GW
# 

#7. App Gw static Public IP
az network public-ip create --resource-group $RG_NAME --sku $APP_GW_PUBLIC_IP_SKU --name $APP_GW_PUBLIC_IP_NAME
az network public-ip update --resource-group $RG_NAME --name $APP_GW_PUBLIC_IP_NAME --allocation-method static

# Convert existing cert to PFX
openssl pkcs12 -export -out appgwcert.pfx -inkey privateKey.key -in appgwcert.crt

az network application-gateway create \
  --name $APP_GW_NAME \
  --location $LOCATION \
  --resource-group $RG_NAME \
  --vnet-name $VNET_NAME \
  --subnet $APP_GW_SUBNET_NAME \
  --capacity 2 \
  --sku $APP_GW_VM_SIZE \
  --http-settings-cookie-based-affinity Disabled \
  --frontend-port 443 \
  --http-settings-port 80 \
  --http-settings-protocol Http \
  --cert-file appgwcert.pfx \
  --public-ip-address $APP_GW_PUBLIC_IP_NAME \
  --cert-password $APP_GW_CERT_PW \
  --servers "$WEB_VM_address1" 

az network application-gateway ssl-policy set -g $RG_NAME --gateway-name $APP_GW_NAME \
    --policy-type Custom --min-protocol-version TLSv1_2 \
    --cipher-suites TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256  TLS_DHE_RSA_WITH_AES_128_GCM_SHA256

az network application-gateway rewrite-rule set create \
    -g $RG_NAME \
    --gateway-name $APP_GW_NAME \
    -n HSTS-rule-set001

az network application-gateway rewrite-rule create \
    -g $RG_NAME \
    --gateway-name $APP_GW_NAME \
    --rule-set-name HSTS-rule-set001 \
    -n rule1 \
    --sequence 1 \
    --response-headers Strict-Transport-Security="max-age=31536000"

az network application-gateway rule update \
    -g $RG_NAME \
    --gateway-name $APP_GW_NAME \
    --name rule1 \
    --rewrite-rule-set HSTS-rule-set001