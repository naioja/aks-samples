#!/bin/bash

# prep work
az provider register --namespace Microsoft.ContainerService
az extension add --name aks-preview
az extension update --name aks-preview

# AZWI
az feature register --namespace "Microsoft.ContainerService" --name "EnableWorkloadIdentityPreview"
