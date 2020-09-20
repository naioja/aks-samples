# Azure Application Gateway how to get an "A+" on ssllabs.com

The objective of this article is to setup Azure Application Gateway in order to pass the ssllabs.com tests and get an "A+" grade.

## Install and configure nginx on a linux virtual machine
First of all we are going to install a linux web server as a backend. For this we will need a resource group, subnets and NSG rules as well as a nginx to serve as the webserver.

1. Using az cli in a bash shell I'm first preparing a couple of variables that I'm going to use during the deployment:
```bash
DOMAIN_NAME="MY_CUSTOM_COMAINE_NAME"

LOCATION="eastus"
RG_NAME="app-gw-demo-rg"

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
```
The script that deploys and configures everything can be found :
https://github.com/naioja/aks-samples/blob/master/application-gateway/appgw-ssl-labs.sh

2. Creating a resource group
```bash
az group create --resource-group $RG_NAME --location $LOCATION
```

3. Creating a Vnet with two subnets one for the linux backend webserver and one for the Application Gateway itself
```bash
# Create APP GW Subnet
az network vnet create \
    --resource-group $RG_NAME \
    --location $LOCATION \
    --name $VNET_NAME \
    --subnet-name $APP_GW_SUBNET_NAME \
    --address-prefixes $VNET_ADDRESS_PREFIXES \
    --subnet-prefix $APP_GW_SUBNET_PREFIX

# Create WEB VM Subnet
az network vnet subnet create \
    --address-prefixes $WEB_VM_SUBNET_PREFIX \
    --name $WEB_VM_SUBNET_NAME \
    --resource-group $RG_NAME \
    --vnet-name $VNET_NAME
```

4. In my case I took the decision that the linux virtual machine will have a public IP address for me to ssh, this is totally optional and there are other ways to connect to the server.
```bash
az network public-ip create --resource-group $RG_NAME --name $WEB_VM_PUBLIC_IP_NAME
az network public-ip update --resource-group $RG_NAME --name $WEB_VM_PUBLIC_IP_NAME --allocation-method static
```

5. In the steps below I'm creating an NSG and adding rules to allow me to ssh to virtual machine from my home IP address only and allow the webserver to be accessed from the Application Gateway subnet.
Additinally I'm creating the virtual network interface where I attach the just created NSG. In the next step that virtual network interface will be assigned to the webserver itself. 
```bash
# Create the NSG
az network nsg create \
    --name myNetworkSecurityGroup \
    --resource-group $RG_NAME \
    --location $LOCATION

# Add a rule to allow SSH management from the current IP address
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name myNetworkSecurityGroup \
    --name allow_ssh \
    --priority 101 \
    --protocol Tcp \
    --source-address-prefixes $USER_IP \ 
    --destination-port-ranges 22

# Add a rule to allow WEB traffic from the Application Gateway's subnet
az network nsg rule create \
    --resource-group $RG_NAME \
    --nsg-name myNetworkSecurityGroup \
    --name allow_web \
    --priority 102 \
    --protocol Tcp \
    --source-address-prefixes $APP_GW_SUBNET_PREFIX \ 
    --destination-port-ranges 80

# Create the network interface myNic1 and assign the NSG 
az network nic create \
    --resource-group $RG_NAME \
    --name myNic1 \
    --vnet-name $VNET_NAME \
    --subnet $WEB_VM_SUBNET_NAME \
    --network-security-group myNetworkSecurityGroup
```
6. At this point we are ready to create our virtual machine with the necessary nginx webserver and assing it a primary interface that has a public IP address accesible from your own location only.
The virtual machine has a custom username and an ssh keypair only as a login option.
```bash
# Executed a VM creatin cloud-init will install the nginx webserver
cat << EOF > cloud-init.txt
#cloud-config
package_upgrade: true
packages:
  - nginx
EOF

# Creating the VM
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

# Making myNic1 the primary interface
az network nic ip-config update -g $RG_NAME --nic-name myNic1 \
    -n ipconfig1 --make-primary

# Assigning the pre-created static public IP to the VM
az network nic ip-config update \
  --name ipconfig1 \
  --nic-name myNic1 \
  --resource-group $RG_NAME \
  --public-ip-address $WEB_VM_PUBLIC_IP_NAME

# Determine the public IP address of the VM and store it in a variable
SSH_IP=$(az network public-ip show --resource-group $RG_NAME --name $WEB_VM_PUBLIC_IP_NAME --query ipAddress -o tsv)

# Determine the private IP address of the VM and store it in a variable as well
WEB_VM_address1=$(az network nic show --name myNic1 --resource-group $RG_NAME | grep "\"privateIpAddress\":" | grep -oE '[^ ]+$' | tr -d '",')

# Checking if we can manage the VM using ansible
export ANSIBLE_HOST_KEY_CHECKING="False"
ansible all -i "$SSH_IP," -m ping -u admn
```

## Configure and secure Azure Application Gateway
Since we are done with the linux web server we can move on to the Application Gateway steps.

1. The first step here is to have a valid SSL certificate issued by a trusted Certificate Authority. In my case I have a wilcard certificate issued by LetsEncrypt that I use for my own personal domain. It's out of this article's scope to describe how to generate an SSL certificate, but in order to use as it is my case a LetsEncrypt certificate of for that mather of fact any certificate we will need to convert it to PFX format. The command below will require a password to be set for the generated PFX file.

```bash
# Convert existing cert to PFX
openssl pkcs12 -export -out appgwcert.pfx -inkey privateKey.key -in appgwcert.crt
```

2. Create the public IP address to be used by our Application Gateway
```bash
az network public-ip create \
    --resource-group $RG_NAME \
    --sku $APP_GW_PUBLIC_IP_SKU \
    --name $APP_GW_PUBLIC_IP_NAME

az network public-ip update \
    --resource-group $RG_NAME \
    --name $APP_GW_PUBLIC_IP_NAME \
    --allocation-method static

APPGW_IP=$(az network public-ip show --resource-group $RG_NAME --name $APP_GW_PUBLIC_IP_NAME --query ipAddress -o tsv)
```

3. Creating the actual Application Gateway instance is done as follows. The `az cli application-gateway create` command takes a few parameters the ones worth mentioning are the public IP address and the private IP address of our webserver as well as the password used to create the PFX certificate file. The creation time may vary but could take up to 15 minutes to finish.
   
```bash
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
```

4. The first step we are going to take after the creation is finished is to customize the SSL cipher suites and the minimum TLS version and set those to something very secure. This has potentially will impact older clients trying to access our website.

```bash
# The following Cipher Suites will enable Forward Secrecy
az network application-gateway ssl-policy set \
    -g $RG_NAME \
    --gateway-name $APP_GW_NAME \
    --policy-type Custom --min-protocol-version TLSv1_2 \
    --cipher-suites TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256  TLS_DHE_RSA_WITH_AES_128_GCM_SHA256
```

5. Next step in securing our Azure Application Gateway is to enable HSTS via a rewrite rule.
```bash

# Create the rewrite set
az network application-gateway rewrite-rule set create \
    -g $RG_NAME \
    --gateway-name $APP_GW_NAME \
    -n HSTS-rule-set001

# Create the actual rule setting HSTS and a value
az network application-gateway rewrite-rule create \
    -g $RG_NAME \
    --gateway-name $APP_GW_NAME \
    --rule-set-name HSTS-rule-set001 \
    -n rule1 \
    --sequence 1 \
    --response-headers Strict-Transport-Security="max-age=31536000"

# Update the already created route rule to use the new HSTS-rule-set001 rule set
az network application-gateway rule update \
    -g $RG_NAME \
    --gateway-name $APP_GW_NAME \
    --name rule1 \
    --rewrite-rule-set HSTS-rule-set001
```
## DNS Configuration
6. Up to this point if we would do a test on `ssllabs.com` the result will be just an `A`.
To last step that we need to take is enable CAA for your domain and point it to the Certificate authority. This is independent of Azure Application Gateway and needs to be done where you host your domain.
    
    The end result can be verified by simply running a `dig` query.
```bash
dig caa $DOMAIN_NAME +short
[output below]
0 issue "comodoca.com"
0 issue "digicert.com"
0 issue "letsencrypt.org"
0 issuewild "comodoca.com"
0 issuewild "digicert.com"
0 issuewild "letsencrypt.org"
```
For example if you host your domain in Azure, creating a CAA record will look something like this:

```bash
az network dns record-set caa add-record \
    --resource-group $RG_NAME\
    --zone-name $DOMAIN_NAME \
    --record-set-name test-caa \
    --flags 0 \
    --tag "issue" \
    --value "letsencrypt.org"
```

7. We now need to create a dns record entry for the public IP linked to Azure Application Gateway that will match our certificate. In my case I'm using a wilcard certificate so any name will be work. Again this is done where the domain is hosted and as before if the domain is in Azure then creating an `A record` will be something like:

```bash
az network dns record-set a add-record \
    -g $RG_NAME \
    -z $DOMAIN_NAME \
    -n ssltest01 \
    -a $APPGW_IP
```
## Testing on ssllabs.com
1. At this point we are done with the configuration phase and we are ready to test our deployment. This can be done on Qualys website ssllabs.com or using their own command line tool. The below sections exemplfies running the tests using the command line and outputing just the hostname and the results of the test.

```bash
ssllabs-scan --grade --quiet "ssltest01.$DOMAIN_NAME"

[output]
HostName:"ssltest01.XXXX.XX"
"40.XX.XX.XX":"A+"
```

## Cleaning everything 
Simply delete the resource group and everything else should be deleted as well by running
```bash
az group delete --resource-group $RG_NAME
```