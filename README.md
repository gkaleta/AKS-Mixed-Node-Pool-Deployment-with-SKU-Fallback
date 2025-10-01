# AKS-Mixed-Node-Pool-Deployment-with-SKU-Fallback

This guide walks through building an Azure Kubernetes Service (AKS) cluster that mixes system and user node pools and automatically falls back across a prioritized list of VM SKUs when capacity is constrained in an availability zone.

## 🎯 Goals

- Provision an AKS cluster with a dedicated system node pool and a user workload node pool.
- Prioritize a primary memory-optimized VM SKU but gracefully fall back to secondary and tertiary SKUs when regional capacity is unavailable.
- Provide repeatable CLI, Bicep, and automation-friendly steps, including a test deployment script.

## ✅ Prerequisites

- Azure subscription with `Owner` or `Contributor` rights.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.51.0 or later.
- Logged in via `az login` and targeting the desired subscription (`az account set --subscription <SUBSCRIPTION_ID>`).
- Bash environment (macOS/Linux/WSL recommended).
- Optional: [Azure Resource Manager tools](https://learn.microsoft.com/azure/azure-resource-manager/templates/overview) if deploying via ARM/Bicep.

## 🧭 Architecture Overview

| Component           | Purpose                                                                 | Notes |
|---------------------|-------------------------------------------------------------------------|-------|
| Resource group      | Logical container for the AKS cluster and related resources             | Created once per deployment |
| AKS cluster         | Managed Kubernetes control plane with a default system node pool        | System pool keeps control plane lightweight |
| User node pool      | Dedicated pool for workloads with memory-intensive SKU preferences      | Will cycle across fallback SKUs |

### SKU Fallback Strategy

1. Attempt to provision the user node pool with **Primary SKU** (e.g., `Standard_E8ds_v5`).
2. If the region or zone lacks capacity, retry with **Secondary SKU** (e.g., `Standard_E8s_v3`).
3. As a final attempt, use **Tertiary SKU** (e.g., `Standard_D8s_v5`).
4. Surface a clear error if all SKUs fail so operators can escalate or adjust locations.

> ℹ️ Tip: Ensure each fallback SKU has comparable vCPU/RAM ratios to maintain workload performance characteristics.

## 🛠️ Step-by-Step (Azure CLI)

1. **Set environment variables** (adjust values for your environment):

   ```bash
   export RESOURCE_GROUP="rg-aks-mixed"
   export LOCATION="eastus"
   export CLUSTER_NAME="aks-mixed-demo"
   export PRIMARY_SKU="Standard_E8ds_v5"
   export SECONDARY_SKU="Standard_E8s_v3"
   export TERTIARY_SKU="Standard_D8s_v5"
   ```

2. **Create the resource group**:

   ```bash
   az group create \
     --name "$RESOURCE_GROUP" \
     --location "$LOCATION"
   ```

3. **Provision AKS cluster with a dedicated system node pool** (default VM size is fine for system workloads):

   ```bash
   az aks create \
     --name "$CLUSTER_NAME" \
     --resource-group "$RESOURCE_GROUP" \
     --location "$LOCATION" \
     --node-count 1 \
     --vm-set-type VirtualMachineScaleSets \
     --nodepool-name sysnp \
     --node-vm-size Standard_D4s_v5 \
     --mode System \
     --enable-cluster-autoscaler \
     --min-count 1 \
     --max-count 3
   ```

4. **Add the user node pool with fallback logic** (run the [provided script](./scripts/deploy-aks-mixed-nodepool.sh) to automate retries):

   ```bash
   ./scripts/deploy-aks-mixed-nodepool.sh \
     --resource-group "$RESOURCE_GROUP" \
     --cluster-name "$CLUSTER_NAME" \
     --location "$LOCATION" \
     --pool-name memnp \
     --zones 1 2 \
     --sku-primary "$PRIMARY_SKU" \
     --sku-secondary "$SECONDARY_SKU" \
     --sku-tertiary "$TERTIARY_SKU"
   ```

   The script will attempt node pool creation with each SKU in order and stop at the first success.

5. **Validate node pool status**:

   ```bash
   az aks nodepool list \
     --cluster-name "$CLUSTER_NAME" \
     --resource-group "$RESOURCE_GROUP" \
     --query "[].{name:name, vmSize:vmSize, mode:mode, powerState:powerState.code}"
   ```

## 📦 Optional: Deploy via Bicep or ARM Template

1. Review the parameter file to set the SKU priority list.
2. Deploy using `az deployment group create` with `--template-file` pointing to your preferred Bicep/ARM template.
3. Implement conditional logic in the template to choose the first SKU available (e.g., using [`condition` expressions](https://learn.microsoft.com/azure/azure-resource-manager/bicep/conditional-resource-deployment)).

> 🚀 Pro Tip: Combine Bicep modules with [`try`/`catch` style](https://learn.microsoft.com/azure/azure-resource-manager/bicep/loops#continue-and-exit) loops or preflight REST calls to check SKU availability before deploying.

## 🔍 Observability and Operations

- Enable [Azure Monitor Metrics](https://learn.microsoft.com/azure/aks/monitor-aks) for node pool health.
- Set up alerts for scale failures or capacity exhaustion.
- Use `az aks nodepool update --enable-cluster-autoscaler` to adjust scaling bounds post-deployment.

## 🧪 Test Script

- Located at [`scripts/deploy-aks-mixed-nodepool.sh`](./scripts/deploy-aks-mixed-nodepool.sh).
- Safely retries node pool creation with fallback SKUs and produces clear exit codes/logging.
- See inline comments for customization tips (spot instances, taints, labels, etc.).

## 🧹 Cleanup

When finished, remove the resource group to avoid costs:

```bash
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```

## 📚 Additional References

- [AKS node pools documentation](https://learn.microsoft.com/azure/aks/use-multiple-node-pools)
- [AKS VM SKU availability considerations](https://learn.microsoft.com/azure/aks/quotas-skus-regions)
- [Azure CLI `az aks` reference](https://learn.microsoft.com/cli/azure/aks)
