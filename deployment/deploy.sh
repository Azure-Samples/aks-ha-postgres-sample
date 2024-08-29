#!/bin/bash

# Create a state for the deployment -- usefule when we deploy the app and for clean up later
if [ -f ./deployment/deploy.state ]; then
    echo ${YELLOW} "Detected a deployment state file. Overwriting..."
    rm -f ./deployment/deploy.state
fi

# Set the environment variables
export SUFFIX=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | fold -w 8 | head -n 1)
echo "SUFFIX=$SUFFIX" >> ./deployment/deploy.state
export LOCAL_NAME="cnpg"
echo "LOCAL_NAME=$LOCAL_NAME" >> ./deployment/deploy.state
export TAGS="owner=cnpg"
echo "TAGS=$TAGS" >> ./deployment/deploy.state
export RESOURCE_GROUP_NAME="rg-${LOCAL_NAME}-${SUFFIX}"
echo "RESOURCE_GROUP_NAME=$RESOURCE_GROUP_NAME" >> ./deployment/deploy.state
export PRIMARY_CLUSTER_REGION="westus"
echo "PRIMARY_CLUSTER_REGION=$PRIMARY_CLUSTER_REGION" >> ./deployment/deploy.state
export AKS_PRIMARY_CLUSTER_NAME="aks-primary-${LOCAL_NAME}-${SUFFIX}"
echo "AKS_PRIMARY_CLUSTER_NAME=$AKS_PRIMARY_CLUSTER_NAME" >> ./deployment/deploy.state
export AKS_PRIMARY_MANAGED_RG_NAME="rg-${LOCAL_NAME}-primary-aksmanaged-${SUFFIX}"
echo "AKS_PRIMARY_MANAGED_RG_NAME=$AKS_PRIMARY_MANAGED_RG_NAME" >> ./deployment/deploy.state
export AKS_PRIMARY_CLUSTER_FED_CREDENTIAL_NAME="pg-primary-fedcred1-${LOCAL_NAME}-${SUFFIX}"
echo "AKS_PRIMARY_CLUSTER_FED_CREDENTIAL_NAME=$AKS_PRIMARY_CLUSTER_FED_CREDENTIAL_NAME" >> ./deployment/deploy.state
export AKS_PRIMARY_CLUSTER_PG_DNSPREFIX=$(echo $(echo "a$(openssl rand -hex 5 | cut -c1-11)"))
echo "AKS_PRIMARY_CLUSTER_PG_DNSPREFIX=$AKS_PRIMARY_CLUSTER_PG_DNSPREFIX" >> ./deployment/deploy.state
export AKS_UAMI_CLUSTER_IDENTITY_NAME="mi-aks-${LOCAL_NAME}-${SUFFIX}"
echo "AKS_UAMI_CLUSTER_IDENTITY_NAME=$AKS_UAMI_CLUSTER_IDENTITY_NAME" >> ./deployment/deploy.state
export AKS_CLUSTER_VERSION="1.28"
echo "AKS_CLUSTER_VERSION=$AKS_CLUSTER_VERSION" >> ./deployment/deploy.state
export PG_NAMESPACE="cnpg-database"
echo "PG_NAMESPACE=$PG_NAMESPACE" >> ./deployment/deploy.state
export PG_SYSTEM_NAMESPACE="cnpg-system"
echo "PG_SYSTEM_NAMESPACE=$PG_SYSTEM_NAMESPACE" >> ./deployment/deploy.state
export PG_PRIMARY_CLUSTER_NAME="pg-primary-${LOCAL_NAME}-${SUFFIX}"
echo "PG_PRIMARY_CLUSTER_NAME=$PG_PRIMARY_CLUSTER_NAME" >> ./deployment/deploy.state
export PG_PRIMARY_STORAGE_ACCOUNT_NAME="hacnpgpsa${SUFFIX}"
echo "PG_PRIMARY_STORAGE_ACCOUNT_NAME=$PG_PRIMARY_STORAGE_ACCOUNT_NAME" >> ./deployment/deploy.state
export PG_STORAGE_BACKUP_CONTAINER_NAME="backups"
echo "PG_STORAGE_BACKUP_CONTAINER_NAME=$PG_STORAGE_BACKUP_CONTAINER_NAME" >> ./deployment/deploy.state
export ENABLE_AZURE_PVC_UPDATES="true"
echo "ENABLE_AZURE_PVC_UPDATES=$ENABLE_AZURE_PVC_UPDATES" >> ./deployment/deploy.state
export MY_PUBLIC_CLIENT_IP=$(dig +short myip.opendns.com @resolver3.opendns.com)
echo "MY_PUBLIC_CLIENT_IP=$MY_PUBLIC_CLIENT_IP" >> ./deployment/deploy.state

# Enable required extensions
az extension add --upgrade --name k8s-extension --yes --allow-preview false
az extension add --upgrade --name amg --yes --allow-preview false

# Create a resource group
az group create \
  --name $RESOURCE_GROUP_NAME \
  --location $PRIMARY_CLUSTER_REGION \
  --tags $TAGS \
  --output tsv --query 'properties.provisioningState'

if [ $? -ne 0 ]; then
    echo "Failed to create resource group"
    exit 1
fi
echo "Resource group created"

# Create user-assigned managed identity
AKS_UAMI_WI_IDENTITY=$(az identity create \
    --name $AKS_UAMI_CLUSTER_IDENTITY_NAME \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --output json)

export AKS_UAMI_WORKLOAD_OBJECTID=$( \
    echo "${AKS_UAMI_WI_IDENTITY}" | jq -r '.principalId')
export AKS_UAMI_WORKLOAD_RESOURCEID=$( \
    echo "${AKS_UAMI_WI_IDENTITY}" | jq -r '.id')
export AKS_UAMI_WORKLOAD_CLIENTID=$( \
    echo "${AKS_UAMI_WI_IDENTITY}" | jq -r '.clientId')

if [ $? -ne 0 ]; then
    echo "Failed to create user-assigned managed identity"
    exit 1
fi
echo "User-assigned managed identity created"

echo "ObjectId: $AKS_UAMI_WORKLOAD_OBJECTID"
echo "ResourceId: $AKS_UAMI_WORKLOAD_RESOURCEID"
echo "ClientId: $AKS_UAMI_WORKLOAD_CLIENTID"

# Create the primary region storage cluster and backup container
az storage account create \
  --name $PG_PRIMARY_STORAGE_ACCOUNT_NAME \
  --resource-group $RESOURCE_GROUP_NAME \
  --location $PRIMARY_CLUSTER_REGION \
  --sku Standard_ZRS \
  --kind StorageV2 \
  --output tsv --query 'provisioningState'

if [ $? -ne 0 ]; then
    echo "Failed to create storage account"
    exit 1
fi
echo "Storage account created"

az storage container create \
  --name $PG_STORAGE_BACKUP_CONTAINER_NAME \
  --account-name $PG_PRIMARY_STORAGE_ACCOUNT_NAME \
  --auth-mode login > /dev/null

if [ $? -ne 0 ]; then
    echo "Failed to create storage container"
    exit 1
fi
echo "Storage container created"

# Assign RBAC to the storage account
# NOTE/TODO - This resource id could be captured when the storage account is created
export STORAGE_ACCOUNT_PRIMARY_RESOURCE_ID=$(az storage account show \
    --name $PG_PRIMARY_STORAGE_ACCOUNT_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --query "id" \
    --output tsv)

echo $STORAGE_ACCOUNT_PRIMARY_RESOURCE_ID

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id $AKS_UAMI_WORKLOAD_OBJECTID \
  --assignee-principal-type ServicePrincipal \
  --scope $STORAGE_ACCOUNT_PRIMARY_RESOURCE_ID \
  --output tsv --query 'id'

if [ $? -ne 0 ]; then
    echo "Failed to assign RBAC to the storage account to managed identity"
    exit 1
fi
echo "RBAC assigned to the storage account to managed identity"

# Deploy monitoring (Grafana) infrastructure
export GRAFANA_PRIMARY="grafana-${LOCAL_NAME}-${SUFFIX}"

az grafana create \
  --resource-group $RESOURCE_GROUP_NAME \
  --name $GRAFANA_PRIMARY \
  --zone-redundancy Enabled \
  --tags $TAGS \
  --query 'id' \
  --output tsv

if [ $? -ne 0 ]; then
    echo "Failed to create Grafana resource"
    exit 1
fi
echo "Grafana resource created"

export GRAFANA_RESOURCE_ID=$(az grafana show \
  --name $GRAFANA_PRIMARY \
  --resource-group $RESOURCE_GROUP_NAME \
  --query 'id' \
  --output tsv)
echo $GRAFANA_RESOURCE_ID

export AMW_PRIMARY="amw-${LOCAL_NAME}-${SUFFIX}"

export AMW_RESOURCE_ID=$(az monitor account create \
  --name $AMW_PRIMARY \
  --resource-group $RESOURCE_GROUP_NAME \
  --tags $TAGS \
  --output tsv --query 'id')

if [ $? -ne 0 ]; then
    echo "Failed to create Azure Monitor Workspace resource"
    exit 1
fi
echo "Azure Monitor Workspace resource created"

echo $AMW_RESOURCE_ID

export ALA_PRIMARY="ala-${LOCAL_NAME}-${SUFFIX}"

export ALA_RESOURCE_ID=$(az monitor log-analytics workspace create \
  --resource-group $RESOURCE_GROUP_NAME \
  --workspace-name $ALA_PRIMARY \
  --output tsv --query 'id')

if [ $? -ne 0 ]; then
    echo "Failed to create Azure Log Analytics workspace"
    exit 1
fi
echo "Azure Log Analytics resource workspace created"

echo $ALA_RESOURCE_ID

# Deploy the primary region AKS cluster
export SYSTEM_NODE_POOL_VMSKU="Standard_B2s_v2"
export USER_NODE_POOL_NAME="postgres"
export USER_NODE_POOL_VMSKU="Standard_B4s_v4"

az aks create \
    --name $AKS_PRIMARY_CLUSTER_NAME \
    --tags $TAGS \
    --resource-group $RESOURCE_GROUP_NAME \
    --location $PRIMARY_CLUSTER_REGION \
    --generate-ssh-keys \
    --node-resource-group $AKS_PRIMARY_MANAGED_RG_NAME \
    --enable-managed-identity \
    --assign-identity $AKS_UAMI_WORKLOAD_RESOURCEID \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --network-dataplane cilium \
    --nodepool-name systempool \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --node-count 2 \
    --node-vm-size $SYSTEM_NODE_POOL_VMSKU \
    --enable-azure-monitor-metrics \
    --azure-monitor-workspace-resource-id $AMW_RESOURCE_ID \
    --grafana-resource-id $GRAFANA_RESOURCE_ID \
    --zones 1 2 3

if [ $? -ne 0 ]; then
    echo "Failed to create primary region AKS cluster"
    exit 1
fi
echo "Primary region AKS cluster created"

i=0
while [ $(az aks show \
    --name $AKS_PRIMARY_CLUSTER_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --query provisioningState -o tsv) != "Succeeded" ]; do
    if [ $i -eq 0 ]; then
        echo "Waiting for AKS cluster to be provisioned..."
    elif [ $(($i % 10)) -eq 0 ]; then
        echo "."
    else
        echo -n "."
    fi
    ((i++))
    sleep 2
done

# Deploy the user node pool
az aks nodepool add \
    --resource-group $RESOURCE_GROUP_NAME \
    --cluster-name $AKS_PRIMARY_CLUSTER_NAME \
    --name $USER_NODE_POOL_NAME \
    --node-count 3 \
    --node-vm-size $USER_NODE_POOL_VMSKU \
    --zones 1 2 3 \
    --labels workload=postgres

if [ $? -ne 0 ]; then
    echo "Failed to create user node pool"
    exit 1
fi
echo "User node pool created"

# Get the kubeconfig for the primary cluster and create namespace
az aks get-credentials \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $AKS_PRIMARY_CLUSTER_NAME

kubectl create namespace $PG_NAMESPACE --context $AKS_PRIMARY_CLUSTER_NAME
kubectl create namespace $PG_SYSTEM_NAMESPACE --context $AKS_PRIMARY_CLUSTER_NAME

# Update the monitoring infrstructure
az aks enable-addons \
    --addon monitoring \
    --name $AKS_PRIMARY_CLUSTER_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --workspace-resource-id $ALA_RESOURCE_ID

if [ $? -ne 0 ]; then
    echo "Failed to enable monitoring add-on"
    exit 1
fi
echo "Monitoring add-on enabled"

# Create a public ip for the primary cluster
export AKS_PRIMARY_CLUSTER_NODERG_NAME=$(az aks show \
  --name $AKS_PRIMARY_CLUSTER_NAME \
  --resource-group $RESOURCE_GROUP_NAME \
  --query nodeResourceGroup -o tsv)

echo $AKS_PRIMARY_CLUSTER_NODERG_NAME

export AKS_PRIMARY_CLUSTER_PUBLICIP_NAME="$AKS_PRIMARY_CLUSTER_NAME-pip"

az network public-ip create \
    --resource-group $AKS_PRIMARY_CLUSTER_NODERG_NAME \
    --name $AKS_PRIMARY_CLUSTER_PUBLICIP_NAME \
    --sku Standard \
    --zone 1 2 3 \
    --allocation-method static

if [ $? -ne 0 ]; then
    echo "Failed to create public ip"
    exit 1
fi
echo "Public ip created"

export AKS_PRIMARY_CLUSTER_PUBLICIP_ADDRESS=$(az network public-ip show \
    --resource-group $AKS_PRIMARY_CLUSTER_NODERG_NAME \
    --name $AKS_PRIMARY_CLUSTER_PUBLICIP_NAME \
    --query ipAddress --output tsv)

echo $AKS_PRIMARY_CLUSTER_PUBLICIP_ADDRESS

export AKS_PRIMARY_CLUSTER_NODERG_NAME_SCOPE=$(az group show --name \
    $AKS_PRIMARY_CLUSTER_NODERG_NAME \
    --query id -o tsv)

echo $AKS_PRIMARY_CLUSTER_NODERG_NAME_SCOPE

az role assignment create \
    --assignee-object-id ${AKS_UAMI_WORKLOAD_OBJECTID} \
    --assignee-principal-type ServicePrincipal \
    --role "Network Contributor" \
    --scope ${AKS_PRIMARY_CLUSTER_NODERG_NAME_SCOPE}

if [ $? -ne 0 ]; then
    echo "Failed to assign Network Contributor role to the managed identity"
    exit 1
fi
echo "Network Contributor role assigned to the managed identity"

# Install the CNPG operator using Helm
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg \
  --namespace $PG_SYSTEM_NAMESPACE \
  --create-namespace \
  --kube-context=$AKS_PRIMARY_CLUSTER_NAME \
  cnpg/cloudnative-pg

if [ $? -ne 0 ]; then
    echo "Failed to install CNPG operator"
    exit 1
fi
echo "CNPG operator installed"

# Deploy the primary region Postgres cluster
# NOTE/TODO - Refactor this part to use Exsternal Secrets Operator
PG_DATABASE_APPUSER_SECRET=$(echo -n | openssl rand -base64 16)

kubectl create secret generic db-user-pass \
    --from-literal=username=app \
    --from-literal=password="${PG_DATABASE_APPUSER_SECRET}" \
    --namespace $PG_NAMESPACE \
    --context $AKS_PRIMARY_CLUSTER_NAME

if [ $? -ne 0 ]; then
    echo "Failed to create db-user-pass secret"
    exit 1
fi
echo "Secret db-user-pass created"

# Set environment variables for the Postgres cluster
cat <<EOF | kubectl apply --context $AKS_PRIMARY_CLUSTER_NAME -n $PG_NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cnpg-controller-manager-config
data:
  ENABLE_AZURE_PVC_UPDATES: 'true'
EOF

if [ $? -ne 0 ]; then
    echo "Failed to create ConfigMap env variables for PG cluster"
    exit 1
fi
echo "ConfigMap env variables created for PG cluster"

# Install the Prometheus Community for CNPG PodMonitor
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts

helm upgrade --install \
  -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/docs/src/samples/monitoring/kube-stack-config.yaml \
  prometheus-community \
  prometheus-community/kube-prometheus-stack \
  --kube-context=$AKS_PRIMARY_CLUSTER_NAME

if [ $? -ne 0 ]; then
    echo "Failed to install Prometheus Community"
    exit 1
fi
echo "Prometheus Community installed"

# Create Federated Credential for the CNPG Workload Identity
export AKS_PRIMARY_CLUSTER_OIDC_ISSUER="$(az aks show \
    --name $AKS_PRIMARY_CLUSTER_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --query "oidcIssuerProfile.issuerUrl" -o tsv)"

az identity federated-credential create \
    --name $AKS_PRIMARY_CLUSTER_FED_CREDENTIAL_NAME \
    --identity-name $AKS_UAMI_CLUSTER_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP_NAME --issuer "${AKS_PRIMARY_CLUSTER_OIDC_ISSUER}" \
    --subject system:serviceaccount:"${PG_NAMESPACE}":"${PG_PRIMARY_CLUSTER_NAME}" \
    --audience api://AzureADTokenExchange

#"subject": "system:serviceaccount:cnpg-database:<clustername>"
if [ $? -ne 0 ]; then
    echo "Failed to create Federated Credential"
    exit 1
fi
echo "Federated Credential created"

# Deploy the Postgres cluster
cat <<EOF | kubectl apply --context $AKS_PRIMARY_CLUSTER_NAME -n $PG_NAMESPACE -v 9 -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $PG_PRIMARY_CLUSTER_NAME
spec:
  inheritedMetadata:
    annotations:
      service.beta.kubernetes.io/azure-dns-label-name: $AKS_PRIMARY_CLUSTER_PG_DNSPREFIX
    labels:
      azure.workload.identity/use: "true"

  instances: 3
  minSyncReplicas: 1
  maxSyncReplicas: 1

  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        cnpg.io/cluster: $PG_PRIMARY_CLUSTER_NAME

  affinity:
    nodeSelector:
      workload: postgres

  resources:
    requests:
      memory: '2Gi'
      cpu: 1.5
    limits:
      memory: '2Gi'
      cpu: 1.5

  bootstrap:
    initdb:
      database: appdb
      owner: app
      secret:
        name: db-user-pass
      dataChecksums: true

  storage:
    size: 2Gi
    pvcTemplate:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 2Gi
      storageClassName: managed-csi-premium
      volumeMode: Filesystem

  walStorage:
    size: 2Gi
    pvcTemplate:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 2Gi
      storageClassName: managed-csi-premium
      volumeMode: Filesystem

  monitoring:
    enablePodMonitor: true

  replicationSlots:
    highAvailability:
      enabled: true

  postgresql:
    parameters:
      # max_worker_processes: 64
    pg_hba:
      - host all all all scram-sha-256
  
  serviceAccountTemplate:
    metadata:
      annotations:
        azure.workload.identity/client-id: "$AKS_UAMI_WORKLOAD_CLIENTID"  
      labels:
        azure.workload.identity/use: "true"

  backup:
    barmanObjectStore:
      destinationPath: "https://${PG_PRIMARY_STORAGE_ACCOUNT_NAME}.blob.core.windows.net/backups"
      azureCredentials:
        inheritFromAzureAD: true

    retentionPolicy: '7d'
EOF

if [ $? -ne 0 ]; then
    echo "Failed to deploy Postgres cluster"
    exit 1
fi
echo "Postgres cluster deployed"

# Create a pod monitor using the azmonitoring group name to view metrics
cat <<EOF | kubectl apply --context $AKS_PRIMARY_CLUSTER_NAME -n $PG_NAMESPACE -f -
apiVersion: azmonitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-cluster-metrics
  namespace: ${PG_NAMESPACE}
  labels:
    azure.workload.identity/use: "true"
    cnpg.io/cluster: ${PG_PRIMARY_CLUSTER_NAME}
spec:
  selector:
    matchLabels:
      azure.workload.identity/use: "true"
      cnpg.io/cluster: ${PG_PRIMARY_CLUSTER_NAME}
  podMetricsEndpoints:
    - port: metrics
EOF