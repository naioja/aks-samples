# Create an Azure AD group
az ad group create --display-name myAKSAdminGroup --mail-nickname myAKSAdminGroup

az aks create \
-g <resource-group> \
-n <cluster-name> \
--enable-aad \
--aad-admin-group-object-ids <aad-group-id> \
--disable-local-accounts

# Disable local accounts on an existing cluster
az aks update \
    -g <resource-group> \
    -n <cluster-name> \
    --enable-aad \
    --aad-admin-group-object-ids <aad-group-id> \
    --disable-local-accounts