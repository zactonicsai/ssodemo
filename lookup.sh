# Find the cluster name and resource group matching your FQDN
AKS_INFO=$(az aks list --query "[?contains(fqdn, 'dns-2140830213-sq5fnod1')].[name, resourceGroup]" -o tsv)
AKS_NAME=$(echo $AKS_INFO | awk '{print $1}')
AKS_RG=$(echo $AKS_INFO | awk '{print $2}')
echo "Cluster: $AKS_NAME | Resource Group: $AKS_RG"

# Enable the external Istio ingress gateway add-on
az aks mesh enable-ingress-gateway \
  --resource-group "$AKS_RG" \
  --name "$AKS_NAME" \
  --ingress-gateway-type external