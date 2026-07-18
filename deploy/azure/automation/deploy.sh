#!/usr/bin/env bash
set -Eeuo pipefail

: "${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
: "${VM_NAME:?Set VM_NAME}"
: "${ACR_NAME:?Set ACR_NAME}"
: "${KEY_VAULT_NAME:?Set KEY_VAULT_NAME}"
: "${KEIVO_IMAGE:?Set KEIVO_IMAGE}"
: "${OLLAMA_MODEL:?Set OLLAMA_MODEL}"
: "${KEIVO_FQDN:?Set KEIVO_FQDN}"
: "${ACME_EMAIL:?Set ACME_EMAIL}"
: "${KEIVO_AUTH_USER:?Set KEIVO_AUTH_USER}"
: "${COMPUTE_PROFILE:?Set COMPUTE_PROFILE}"

[[ "$RESOURCE_GROUP" =~ ^[a-z][a-z0-9-]{2,40}$ ]] || { echo 'Resource group is invalid.' >&2; exit 1; }
[[ "$VM_NAME" =~ ^[a-z][a-z0-9-]{2,60}$ ]] || { echo 'VM name is invalid.' >&2; exit 1; }
[[ "$OLLAMA_MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo 'Model name is invalid.' >&2; exit 1; }
[[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo 'ACME email is invalid.' >&2; exit 1; }
[[ "$KEIVO_AUTH_USER" =~ ^[A-Za-z0-9._-]{3,64}$ ]] || { echo 'Authentication username is invalid.' >&2; exit 1; }
[[ "$COMPUTE_PROFILE" =~ ^(free-cpu|gpu)$ ]] || { echo 'Compute profile is invalid.' >&2; exit 1; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
azure_dir="$(cd -- "$script_dir/.." && pwd)"

bundle="$(mktemp --suffix=.tgz)"
trap 'rm -f "$bundle"' EXIT
tar -czf "$bundle" \
  -C "$azure_dir" compose.yaml Caddyfile \
  -C "$script_dir" compose.acr.override.yaml compose.cpu.override.yaml remote-deploy.sh

bundle_base64="$(base64 -w 0 "$bundle")"
upload_script="install -d -m 0750 /opt/keivo; printf '%s' '$bundle_base64' | base64 --decode > /tmp/keivo-deploy.tgz; tar -xzf /tmp/keivo-deploy.tgz -C /opt/keivo; rm -f /tmp/keivo-deploy.tgz; chmod 700 /opt/keivo/remote-deploy.sh"

az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$upload_script" \
  --output none

model_b64="$(printf '%s' "$OLLAMA_MODEL" | base64 -w 0)"
email_b64="$(printf '%s' "$ACME_EMAIL" | base64 -w 0)"
user_b64="$(printf '%s' "$KEIVO_AUTH_USER" | base64 -w 0)"
remote_command="bash /opt/keivo/remote-deploy.sh '$ACR_NAME' '$KEY_VAULT_NAME' '$KEIVO_IMAGE' '$model_b64' '$KEIVO_FQDN' '$email_b64' '$user_b64' '$COMPUTE_PROFILE'"

az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$remote_command" \
  --query 'value[0].message' \
  --output tsv
