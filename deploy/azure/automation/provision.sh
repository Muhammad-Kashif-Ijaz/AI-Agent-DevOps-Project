#!/usr/bin/env bash
set -Eeuo pipefail

: "${KEIVO_ACTION:?Set KEIVO_ACTION to provision, update, deallocate, or status}"
: "${KEIVO_PREFIX:?Set KEIVO_PREFIX}"
: "${AZURE_REGION:?Set AZURE_REGION}"

VM_SIZE="${VM_SIZE:-Standard_B2ats_v2}"
ADMIN_USERNAME="${ADMIN_USERNAME:-azureuser}"
DATA_DISK_GB="${DATA_DISK_GB:-64}"
COMPUTE_PROFILE="${COMPUTE_PROFILE:-free-cpu}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$KEIVO_ACTION" =~ ^(provision|update|deallocate|status)$ ]] || fail "Unsupported action."
[[ "$COMPUTE_PROFILE" =~ ^(free-cpu|gpu)$ ]] || fail "Unsupported compute profile."
[[ "$KEIVO_PREFIX" =~ ^[a-z][a-z0-9-]{2,18}[a-z0-9]$ ]] || fail "Prefix must be 4-20 lowercase letters, numbers, or hyphens."
[[ "$AZURE_REGION" =~ ^[a-z0-9]+$ ]] || fail "Region contains unsupported characters."
[[ "$VM_SIZE" =~ ^[A-Za-z0-9_]+$ ]] || fail "VM size contains unsupported characters."
[[ "$ADMIN_USERNAME" =~ ^[a-z_][a-z0-9_-]{2,30}$ ]] || fail "Administrator username is invalid."
[[ "$DATA_DISK_GB" =~ ^[0-9]+$ ]] || fail "Data disk size must be a number."
(( DATA_DISK_GB >= 64 && DATA_DISK_GB <= 4095 )) || fail "Data disk size must be 64-4095 GiB."

if [[ "$COMPUTE_PROFILE" == "free-cpu" ]]; then
  [[ "$VM_SIZE" == "Standard_B2ats_v2" ]] || fail "free-cpu requires Standard_B2ats_v2."
  [[ "$DATA_DISK_GB" == "64" ]] || fail "free-cpu requires a 64 GiB data disk."
  # The eligible first-12-month offer includes one Standard ACR and two 64 GiB
  # P6 Premium SSDs: one for the operating system and one for KEIVO data.
  acr_sku="Standard"
  disk_sku="Premium_LRS"
  os_disk_gb="64"
else
  [[ "$VM_SIZE" == Standard_NC* ]] || fail "gpu requires an Azure NC-series VM size."
  (( DATA_DISK_GB >= 128 )) || fail "gpu requires at least 128 GiB of data disk."
  acr_sku="Standard"
  disk_sku="Premium_LRS"
  os_disk_gb="128"
fi

subscription_id="$(az account show --query id --output tsv)"
[[ -n "$subscription_id" ]] || fail "No active Azure subscription."

suffix="$(printf '%s' "${subscription_id}:${KEIVO_PREFIX}" | sha256sum | cut -c1-8)"
compact_prefix="${KEIVO_PREFIX//-/}"
compact_prefix="${compact_prefix:0:10}"

resource_group="${KEIVO_PREFIX}-rg"
vm_name="${KEIVO_PREFIX}-vm"
vnet_name="${KEIVO_PREFIX}-vnet"
subnet_name="workload"
nsg_name="${KEIVO_PREFIX}-nsg"
public_ip_name="${KEIVO_PREFIX}-pip"
nic_name="${KEIVO_PREFIX}-nic"
disk_name="${KEIVO_PREFIX}-data"
acr_name="${compact_prefix}${suffix}acr"
key_vault_name="${compact_prefix}${suffix}kv"
dns_label="${compact_prefix}-${suffix}"

emit() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

emit resource_group "$resource_group"
emit vm_name "$vm_name"
emit acr_name "$acr_name"
emit key_vault_name "$key_vault_name"
emit public_ip_name "$public_ip_name"
emit compute_profile "$COMPUTE_PROFILE"

resource_group_exists=false
if az group show --name "$resource_group" --output none 2>/dev/null; then
  resource_group_exists=true
fi

if [[ "$KEIVO_ACTION" == "status" || "$KEIVO_ACTION" == "deallocate" ]]; then
  if [[ "$resource_group_exists" != true ]] || ! az vm show --resource-group "$resource_group" --name "$vm_name" --output none 2>/dev/null; then
    emit vm_state "not-provisioned"
    emit fqdn ""
    printf 'KEIVO resources have not been provisioned for prefix %s.\n' "$KEIVO_PREFIX"
    exit 0
  fi

  if [[ "$KEIVO_ACTION" == "deallocate" ]]; then
    printf 'Deallocating %s...\n' "$vm_name"
    az vm deallocate --resource-group "$resource_group" --name "$vm_name" --output none
  fi

  vm_state="$(az vm get-instance-view \
    --resource-group "$resource_group" \
    --name "$vm_name" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" \
    --output tsv)"
  fqdn="$(az network public-ip show \
    --resource-group "$resource_group" \
    --name "$public_ip_name" \
    --query dnsSettings.fqdn \
    --output tsv 2>/dev/null || true)"
  emit vm_state "${vm_state:-unknown}"
  emit fqdn "$fqdn"
  printf 'VM state: %s\n' "${vm_state:-unknown}"
  [[ -z "$fqdn" ]] || printf 'Endpoint: https://%s\n' "$fqdn"
  exit 0
fi

for namespace in Microsoft.Compute Microsoft.Network Microsoft.ContainerRegistry Microsoft.KeyVault; do
  az provider register --namespace "$namespace" --wait --output none
done

printf 'Creating or updating Azure resources in %s...\n' "$AZURE_REGION"
az group create --name "$resource_group" --location "$AZURE_REGION" --output none

az acr create \
  --resource-group "$resource_group" \
  --name "$acr_name" \
  --location "$AZURE_REGION" \
  --sku "$acr_sku" \
  --admin-enabled false \
  --output none

az keyvault create \
  --resource-group "$resource_group" \
  --name "$key_vault_name" \
  --location "$AZURE_REGION" \
  --enable-rbac-authorization true \
  --retention-days 7 \
  --enable-purge-protection true \
  --output none

az network nsg create \
  --resource-group "$resource_group" \
  --name "$nsg_name" \
  --location "$AZURE_REGION" \
  --output none

az network nsg rule create \
  --resource-group "$resource_group" \
  --nsg-name "$nsg_name" \
  --name AllowHttp \
  --priority 100 \
  --access Allow \
  --direction Inbound \
  --protocol Tcp \
  --source-address-prefixes Internet \
  --source-port-ranges '*' \
  --destination-address-prefixes '*' \
  --destination-port-ranges 80 \
  --output none

az network nsg rule create \
  --resource-group "$resource_group" \
  --nsg-name "$nsg_name" \
  --name AllowHttps \
  --priority 110 \
  --access Allow \
  --direction Inbound \
  --protocol Tcp \
  --source-address-prefixes Internet \
  --source-port-ranges '*' \
  --destination-address-prefixes '*' \
  --destination-port-ranges 443 \
  --output none

az network nsg rule create \
  --resource-group "$resource_group" \
  --nsg-name "$nsg_name" \
  --name DenyOtherInbound \
  --priority 4000 \
  --access Deny \
  --direction Inbound \
  --protocol '*' \
  --source-address-prefixes '*' \
  --source-port-ranges '*' \
  --destination-address-prefixes '*' \
  --destination-port-ranges '*' \
  --output none

az network vnet create \
  --resource-group "$resource_group" \
  --name "$vnet_name" \
  --location "$AZURE_REGION" \
  --address-prefixes 10.42.0.0/16 \
  --subnet-name "$subnet_name" \
  --subnet-prefixes 10.42.1.0/24 \
  --output none

az network public-ip create \
  --resource-group "$resource_group" \
  --name "$public_ip_name" \
  --location "$AZURE_REGION" \
  --sku Standard \
  --allocation-method Static \
  --dns-name "$dns_label" \
  --output none

az network nic create \
  --resource-group "$resource_group" \
  --name "$nic_name" \
  --location "$AZURE_REGION" \
  --vnet-name "$vnet_name" \
  --subnet "$subnet_name" \
  --network-security-group "$nsg_name" \
  --public-ip-address "$public_ip_name" \
  --output none

if ! az vm show --resource-group "$resource_group" --name "$vm_name" --output none 2>/dev/null; then
  az vm create \
    --resource-group "$resource_group" \
    --name "$vm_name" \
    --location "$AZURE_REGION" \
    --nics "$nic_name" \
    --image Ubuntu2204 \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USERNAME" \
    --authentication-type ssh \
    --generate-ssh-keys \
    --assign-identity \
    --os-disk-size-gb "$os_disk_gb" \
    --storage-sku "$disk_sku" \
    --output none
else
  current_size="$(az vm show --resource-group "$resource_group" --name "$vm_name" --query hardwareProfile.vmSize --output tsv)"
  if [[ "$current_size" != "$VM_SIZE" ]]; then
    az vm deallocate --resource-group "$resource_group" --name "$vm_name" --output none
    az vm resize --resource-group "$resource_group" --name "$vm_name" --size "$VM_SIZE" --output none
  fi
  az vm identity assign --resource-group "$resource_group" --name "$vm_name" --identities '[system]' --output none
  az vm start --resource-group "$resource_group" --name "$vm_name" --output none
fi

if ! az disk show --resource-group "$resource_group" --name "$disk_name" --output none 2>/dev/null; then
  az disk create \
    --resource-group "$resource_group" \
    --name "$disk_name" \
    --location "$AZURE_REGION" \
    --size-gb "$DATA_DISK_GB" \
    --sku "$disk_sku" \
    --output none
else
  az disk update \
    --resource-group "$resource_group" \
    --name "$disk_name" \
    --sku "$disk_sku" \
    --output none
  current_disk_gb="$(az disk show --resource-group "$resource_group" --name "$disk_name" --query diskSizeGb --output tsv)"
  if (( DATA_DISK_GB > current_disk_gb )); then
    az disk update \
      --resource-group "$resource_group" \
      --name "$disk_name" \
      --size-gb "$DATA_DISK_GB" \
      --output none
  fi
fi

attached_count="$(az vm show \
  --resource-group "$resource_group" \
  --name "$vm_name" \
  --query "length(storageProfile.dataDisks[?name=='$disk_name'])" \
  --output tsv)"
if [[ "$attached_count" == "0" ]]; then
  az vm disk attach \
    --resource-group "$resource_group" \
    --vm-name "$vm_name" \
    --name "$disk_name" \
    --lun 10 \
    --output none
fi

principal_id="$(az vm identity show \
  --resource-group "$resource_group" \
  --name "$vm_name" \
  --query principalId \
  --output tsv)"
[[ -n "$principal_id" ]] || fail "The VM managed identity was not created."

acr_id="$(az acr show --resource-group "$resource_group" --name "$acr_name" --query id --output tsv)"
vault_id="$(az keyvault show --resource-group "$resource_group" --name "$key_vault_name" --query id --output tsv)"

for role_scope in "AcrPull|$acr_id" "Key Vault Secrets User|$vault_id"; do
  role="${role_scope%%|*}"
  scope="${role_scope#*|}"
  count="$(az role assignment list \
    --assignee-object-id "$principal_id" \
    --role "$role" \
    --scope "$scope" \
    --query 'length(@)' \
    --output tsv)"
  if [[ "$count" == "0" ]]; then
    az role assignment create \
      --assignee-object-id "$principal_id" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" \
      --scope "$scope" \
      --output none
  fi
done

if [[ "$COMPUTE_PROFILE" == "gpu" ]]; then
  # The paid GPU profile installs the host NVIDIA driver. The free profile skips it.
  az vm extension set \
    --resource-group "$resource_group" \
    --vm-name "$vm_name" \
    --publisher Microsoft.HpcCompute \
    --name NvidiaGpuDriverLinux \
    --output none
  az vm restart --resource-group "$resource_group" --name "$vm_name" --output none
fi

fqdn="$(az network public-ip show \
  --resource-group "$resource_group" \
  --name "$public_ip_name" \
  --query dnsSettings.fqdn \
  --output tsv)"
vm_state="$(az vm get-instance-view \
  --resource-group "$resource_group" \
  --name "$vm_name" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" \
  --output tsv)"

emit fqdn "$fqdn"
emit vm_state "${vm_state:-unknown}"
printf 'Infrastructure ready. Endpoint DNS: %s\n' "$fqdn"
