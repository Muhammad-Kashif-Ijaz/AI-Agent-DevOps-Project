#!/usr/bin/env bash
set -Eeuo pipefail

: "${KEIVO_ACTION:?Set KEIVO_ACTION}"
: "${KEIVO_PREFIX:?Set KEIVO_PREFIX}"

requested_region="${AZURE_REGION:-auto}"
vm_size="${VM_SIZE:-Standard_B2ats_v2}"
resource_group="${KEIVO_PREFIX}-rg"
vm_name="${KEIVO_PREFIX}-vm"

emit_region() {
  local region="$1"
  printf 'Selected Azure region: %s\n' "$region"
  printf 'region=%s\n' "$region" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
}

# Updates must stay with an existing VM. Status/deallocate do not create resources.
existing_region="$(az vm show --resource-group "$resource_group" --name "$vm_name" --query location --output tsv 2>/dev/null || true)"
if [[ -n "$existing_region" ]]; then
  emit_region "$existing_region"
  exit 0
fi
if [[ ! "$KEIVO_ACTION" =~ ^(provision|update)$ ]]; then
  emit_region "${requested_region/auto/eastus}"
  exit 0
fi

command -v jq >/dev/null || { echo 'jq is required for region selection.' >&2; exit 1; }

sku_json="$(az vm list-skus \
  --resource-type virtualMachines \
  --size "$vm_size" \
  --all \
  --output json)"

selected_region=""
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  printf 'Checking %s for %s capacity and public-IP quota...\n' "$candidate" "$vm_size"

  if ! az vm list-skus \
    --location "$candidate" \
    --resource-type virtualMachines \
    --size "$vm_size" \
    --all \
    --output json \
    | jq -e --arg size "$vm_size" \
      'any(.[]; .name == $size and ((.restrictions // []) | length == 0))' \
      >/dev/null; then
    continue
  fi

  usage_json="$(az network list-usages --location "$candidate" --output json 2>/dev/null || true)"
  if jq -e '
    [ .[] | select(((.name.value // "") | ascii_downcase) == "publicipaddresses") ][0] as $u
    | $u != null
      and (($u.limit // 0) == -1 or (($u.currentValue // 0) < ($u.limit // 0)))
  ' <<<"$usage_json" >/dev/null 2>&1; then
    selected_region="$candidate"
    break
  fi
done < <(
  {
    [[ "$requested_region" == "auto" ]] || printf '%s\n' "$requested_region"
    printf '%s\n' eastus2 westus2 westus3 southcentralus northcentralus canadacentral northeurope westeurope uksouth swedencentral southeastasia australiaeast
    jq -r '[.[].locations[]?] | unique[]' <<<"$sku_json"
  } | awk 'NF && !seen[$0]++'
)

[[ -n "$selected_region" ]] || {
  echo "No Azure region currently has unrestricted $vm_size capacity and public-IP quota for this subscription." >&2
  exit 1
}

emit_region "$selected_region"
