#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

PRIMARY_SKU=""
SECONDARY_SKU=""
TERTIARY_SKU=""
RESOURCE_GROUP=""
CLUSTER_NAME=""
POOL_NAME="memnp"
NODE_COUNT=2
MIN_COUNT=1
MAX_COUNT=5
LOCATION=""
ZONES=()
MODE="User"
NODE_LABELS=""
NODE_TAINTS=""
SPOT_PRIORITY=""
OS_SKU="Ubuntu"
K8S_VERSION=""
SSH_KEY=""
MANAGED_IDENTITY=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME \
  --resource-group <name> \
  --cluster-name <name> \
  --location <azure-region> \
  --sku-primary <vm-size> \
  [--sku-secondary <vm-size>] \
  [--sku-tertiary <vm-size>] \
  [--pool-name <nodepool-name>] \
  [--node-count <count>] \
  [--min-count <count>] \
  [--max-count <count>] \
  [--zones <zone1> <zone2> ...] \
  [--node-labels key=value[,key=value...]] \
  [--node-taints key=value:effect[,key=value:effect...]] \
  [--spot] \
  [--os-sku <Ubuntu|CBLMariner>] \
  [--k8s-version <version>] \
  [--ssh-key <path-to-public-key>] \
  [--managed-identity <resource-id>]

Attempts to add an AKS user node pool with a prioritized list of VM SKUs.
If the primary SKU is unavailable due to capacity constraints, the script retries
with the secondary and tertiary SKUs (when provided).
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

error() {
  >&2 log "ERROR: $*"
}

require_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Required command '$1' not found in PATH"
    exit 127
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --resource-group)
        RESOURCE_GROUP="$2"; shift 2 ;;
      --cluster-name)
        CLUSTER_NAME="$2"; shift 2 ;;
      --location)
        LOCATION="$2"; shift 2 ;;
      --sku-primary)
        PRIMARY_SKU="$2"; shift 2 ;;
      --sku-secondary)
        SECONDARY_SKU="$2"; shift 2 ;;
      --sku-tertiary)
        TERTIARY_SKU="$2"; shift 2 ;;
      --pool-name)
        POOL_NAME="$2"; shift 2 ;;
      --node-count)
        NODE_COUNT="$2"; shift 2 ;;
      --min-count)
        MIN_COUNT="$2"; shift 2 ;;
      --max-count)
        MAX_COUNT="$2"; shift 2 ;;
      --zones)
        shift
        while [[ $# -gt 0 && $1 != --* ]]; do
          ZONES+=("$1")
          shift
        done
        ;;
      --node-labels)
        NODE_LABELS="$2"; shift 2 ;;
      --node-taints)
        NODE_TAINTS="$2"; shift 2 ;;
      --spot)
        SPOT_PRIORITY="Spot"; shift ;;
      --os-sku)
        OS_SKU="$2"; shift 2 ;;
      --k8s-version)
        K8S_VERSION="$2"; shift 2 ;;
      --ssh-key)
        SSH_KEY="$2"; shift 2 ;;
      --managed-identity)
        MANAGED_IDENTITY="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        error "Unknown argument: $1"; usage; exit 64 ;;
    esac
  done
}

validate_args() {
  local missing=()
  [[ -z $RESOURCE_GROUP ]] && missing+=("--resource-group")
  [[ -z $CLUSTER_NAME ]] && missing+=("--cluster-name")
  [[ -z $LOCATION ]] && missing+=("--location")
  [[ -z $PRIMARY_SKU ]] && missing+=("--sku-primary")
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required arguments: ${missing[*]}"
    usage
    exit 64
  fi
}

az_requires_login() {
  if ! az account show >/dev/null 2>&1; then
    error "Azure CLI isn\'t logged in. Run 'az login' first."
    exit 1
  fi
}

add_node_pool() {
  local sku="$1"
  local tokens=(
    az aks nodepool add
    --resource-group "$RESOURCE_GROUP"
    --cluster-name "$CLUSTER_NAME"
    --name "$POOL_NAME"
    --node-count "$NODE_COUNT"
    --node-vm-size "$sku"
    --mode "$MODE"
    --min-count "$MIN_COUNT"
    --max-count "$MAX_COUNT"
    --enable-cluster-autoscaler
    --os-sku "$OS_SKU"
  )

  if [[ ${#ZONES[@]} -gt 0 ]]; then
    tokens+=(--zones "${ZONES[@]}")
  fi

  if [[ -n $NODE_LABELS ]]; then
    tokens+=(--labels "$NODE_LABELS")
  fi

  if [[ -n $NODE_TAINTS ]]; then
    tokens+=(--node-taints "$NODE_TAINTS")
  fi

  if [[ -n $SPOT_PRIORITY ]]; then
    tokens+=(--priority "$SPOT_PRIORITY")
  fi

  if [[ -n $K8S_VERSION ]]; then
    tokens+=(--kubernetes-version "$K8S_VERSION")
  fi

  if [[ -n $SSH_KEY ]]; then
    tokens+=(--ssh-key-value "$SSH_KEY")
  fi

  if [[ -n $MANAGED_IDENTITY ]]; then
    tokens+=(--assign-identity "$MANAGED_IDENTITY")
  fi

  log "Attempting to add node pool '$POOL_NAME' with SKU '$sku'"
  if output=$("${tokens[@]}" 2>&1); then
    log "Successfully created node pool '$POOL_NAME' with SKU '$sku'"
    printf '%s' "$output"
    return 0
  else
    error "Failed to create node pool with SKU '$sku': $output"
    return 1
  fi
}

main() {
  require_binary az
  parse_args "$@"
  validate_args
  az_requires_login

  local tried=()
  local errors=()
  local skus=("$PRIMARY_SKU")

  [[ -n $SECONDARY_SKU ]] && skus+=("$SECONDARY_SKU")
  [[ -n $TERTIARY_SKU ]] && skus+=("$TERTIARY_SKU")

  for sku in "${skus[@]}"; do
    tried+=("$sku")
    if add_node_pool "$sku"; then
      log "Node pool provisioning completed using SKU '$sku'"
      exit 0
    else
      errors+=("SKU $sku failed")
      log "Retrying with next SKU (if available)"
    fi
  done

  error "All SKU attempts failed: ${tried[*]}"
  exit 1
}

main "$@"
