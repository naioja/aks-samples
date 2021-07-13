# Quick document to describe how to start and stop an Application Gateway resource

Running continuously an Application Gateway in a Dev subscription can be costly but there's a way to start and stop it as required. 

```bash
# set the name of the resource group where Application Gateway is installed
RG_NAME='rg-wp-002'

# get the name of the Application Gateway from the resource group above
APPGW_NAME=$(az network application-gateway list -g $RG_NAME --query '[].name' -o tsv)

# Start Application Gateway
az network application-gateway start -g $RG_NAME -n $APPGW_NAME

# Stop Application Gateway and save $$$
az network application-gateway stop -g $RG_NAME -n $APPGW_NAME

# Check the new state of Application Gateway
az network application-gateway show -g $RG_NAME -n $APPGW_NAME --query 'operationalState'
```