# This script might take about 10 minutes

# Please check the variables
tenant_guid=**Your tenant id for Identities**
main_subscription=**Your Main subscription**
AKS_ENDUSER_NAME=aksuser1@contosobicycle.com
AKS_ENDUSER_PASSWORD=**Your valid password**

APPGW_APP_URL=app.bicycle.contoso.com
PFX_PASSWORD=contoso

# Cluster Parameters. 
# Copy from pre-cluster-stump.sh output
CLUSTER_VNET_RESOURCE_ID=
RGNAMECLUSTER=
RGLOCATION=
FIREWALL_SUBNET_RESOURCEID=
GATEWAY_SUBNET_RESOURCE_ID=
k8sRbacAadProfileAdminGroupObjectID=
k8sRbacAadProfileTenantId=
clusterLoadBalancerIpAddress=

# Used for services that support native geo-redundancy (Azure Container Registry)
# Ideally should be the paired region of $RGLOCATION
GEOREDUNDANCY_LOCATION=centralus

# User Parameters. 
# Copy from pre-cluster-stump.sh output
APP_ID=
APP_PASS=
APP_TENANT_ID=

# Login with the service principal created with minimum privilege. It is a demo approach.
# A real user with the correct privilege should login
az login --service-principal --username $APP_ID --password $APP_PASS --tenant $APP_TENANT_ID

echo ""
echo "# Deploying AKS Cluster"
echo ""

## Cluster Certificate - AKS Internal Load Balancer
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -out traefik-ingress-internal-bicycle-contoso-com-tls.crt \
        -keyout traefik-ingress-internal-bicycle-contoso-com-tls.key \
        -subj "/CN=*.bicycle.contoso.com/O=Contoso Bicycle"
AKS_BALANCER_CERT_DATA=$(cat traefik-ingress-internal-bicycle-contoso-com-tls.crt | base64 | tr -d '\n' | tr -d '\r')

# App Gateway Certificate
openssl pkcs12 -export -out appgw_std.pfx -in traefik-ingress-internal-bicycle-contoso-com-tls.crt -inkey traefik-ingress-internal-bicycle-contoso-com-tls.key -passout pass:$PFX_PASSWORD
APPGW_CERT_DATA=$(cat appgw_std.pfx | base64 | tr -d '\n' | tr -d '\r')

#AKS Cluster Creation. Advance Networking. AAD identity integration. This might take about 8 minutes
az deployment group create --resource-group "${RGNAMECLUSTER}" --template-file "cluster-stamp.json" --name "cluster-0001" --parameters \
               location=$RGLOCATION \
               geoRedundancyLocation=$GEOREDUNDANCY_LOCATION \
               targetVnetResourceId=$CLUSTER_VNET_RESOURCE_ID \
               k8sRbacAadProfileAdminGroupObjectID=$k8sRbacAadProfileAdminGroupObjectID \
               k8sRbacAadProfileTenantId=$k8sRbacAadProfileTenantId \
               keyvaultAclAllowedSubnetResourceIds="['$FIREWALL_SUBNET_RESOURCEID', '$GATEWAY_SUBNET_RESOURCE_ID']" \
               appGatewayCertificateData=$APPGW_CERT_DATA \
               aksLoadBalancerData=$AKS_BALANCER_CERT_DATA

AKS_CLUSTER_NAME=$(az deployment group show -g $RGNAMECLUSTER -n cluster-0001 --query properties.outputs.aksClusterName.value -o tsv)

echo ""
echo "# Creating AAD Groups and users for the created cluster"
echo ""

# We are going to use a the new tenant which manage the cluster identity
az login  --allow-no-subscriptions -t $tenant_guid

#Creating AAD groups which will be associated to k8s out of the box cluster roles
k8sClusterAdminAadGroupName="k8s-cluster-admin-clusterrole-${AKS_CLUSTER_NAME}"
k8sClusterAdminAadGroup=$(az ad group create --display-name ${k8sClusterAdminAadGroupName} --mail-nickname ${k8sClusterAdminAadGroupName} --query objectId -o tsv)
k8sAdminAadGroupName="k8s-admin-clusterrole-${AKS_CLUSTER_NAME}"
k8sAdminAadGroup=$(az ad group create --display-name ${k8sAdminAadGroupName} --mail-nickname ${k8sAdminAadGroupName} --query objectId -o tsv)
k8sEditAadGroupName="k8s-edit-clusterrole-${AKS_CLUSTER_NAME}"
k8sEditAadGroup=$(az ad group create --display-name ${k8sEditAadGroupName} --mail-nickname ${k8sEditAadGroupName} --query objectId -o tsv)
k8sViewAadGroupName="k8s-view-clusterrole-${AKS_CLUSTER_NAME}"
k8sViewAadGroup=$(az ad group create --display-name ${k8sViewAadGroupName} --mail-nickname ${k8sViewAadGroupName} --query objectId -o tsv)

#EXAMPLE of an User in View Group 
AKS_ENDUSR_OBJECTID=$(az ad user create --display-name $AKS_ENDUSER_NAME --user-principal-name $AKS_ENDUSER_NAME --password $AKS_ENDUSER_PASSWORD --query objectId -o tsv)
az ad group member add --group k8s-view-clusterrole --member-id $AKS_ENDUSR_OBJECTID

cat << EOF

NEXT STEPS
---- -----
# Your AKS Internal Load Balancer should be 
$clusterLoadBalancerIpAddress

You already have generated the following dertificate files for your ingress controller
   -traefik-ingress-internal-bicycle-contoso-com-tls.crt 
   -keyout traefik-ingress-internal-bicycle-contoso-com-tls.key 

# Deploy application

az login
az account set -s  $main_subscription
az aks get-credentials -n ${AKS_CLUSTER_NAME} -g ${RGNAMECLUSTER} --admin
kubectl create ns a0008

'cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: bicycle-contoso-com-tls-secret
  namespace: a0008
data:
  tls.crt: $(cat traefik-ingress-internal-bicycle-contoso-com-tls.crt | base64 -w 0)
  tls.key: $(cat traefik-ingress-internal-bicycle-contoso-com-tls.key | base64 -w 0)
type: kubernetes.io/tls
EOF'

kubectl apply -f ../workload/traefik.yaml
kubectl apply -f ../workload/aspnetapp.yaml

# the ASPNET Core webapp sample is all setup. Wait until is ready to process requests running:
kubectl wait --namespace a0008 \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=aspnetapp \
  --timeout=90s
#you must see the address 10.240.4.4
kubectl get ingress aspnetapp-ingress -n a0008

# Temporary section. It is going to be deleted in the future. Testing k8sRBAC-AAD Groups

k8s-cluster-admin-clusterrole ${k8sClusterAdminAadGroup}
k8s-admin-clusterrole ${k8sAdminAadGroup}
k8s-edit-clusterrole ${k8sEditAadGroup}
k8s-view-clusterrole ${k8sViewAadGroup}
User Name:${AKS_ENDUSER_NAME} Pass:${AKS_ENDUSER_PASSWORD} objectId:${AKS_ENDUSR_OBJECTID}

Testing role after update yaml file (cluster-settings/user-facing-cluster-role-aad-group.yaml). Execute:

kubectl apply -f ./cluster-settings/user-facing-cluster-role-aad-group.yaml
az aks get-credentials -n ${AKS_CLUSTER_NAME} -g ${RGNAMECLUSTER} --overwrite-existing
kubectl get all

->Kubernetes will ask you to login. You will need to use the ${AKS_ENDUSER_NAME} user

# Clean up resources. Execute:

deleteResourceGroups.sh

EOF

