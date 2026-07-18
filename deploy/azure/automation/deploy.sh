#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/az-retry.sh"

: "${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
: "${VM_NAME:?Set VM_NAME}"
: "${OLLAMA_MODEL:?Set OLLAMA_MODEL}"
: "${KEIVO_FQDN:?Set KEIVO_FQDN}"
: "${ACME_EMAIL:?Set ACME_EMAIL}"
: "${KEIVO_AUTH_USER:?Set KEIVO_AUTH_USER}"
: "${KEIVO_AUTH_HASH:?Set KEIVO_AUTH_HASH}"
: "${COMPUTE_PROFILE:?Set COMPUTE_PROFILE}"

[[ "$RESOURCE_GROUP" =~ ^[a-z][a-z0-9-]{2,40}$ ]] || { echo 'Resource group is invalid.' >&2; exit 1; }
[[ "$VM_NAME" =~ ^[a-z][a-z0-9-]{2,60}$ ]] || { echo 'VM name is invalid.' >&2; exit 1; }
[[ "$OLLAMA_MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo 'Model name is invalid.' >&2; exit 1; }
[[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo 'ACME email is invalid.' >&2; exit 1; }
[[ "$KEIVO_AUTH_USER" =~ ^[A-Za-z0-9._-]{3,64}$ ]] || { echo 'Authentication username is invalid.' >&2; exit 1; }
[[ "$KEIVO_AUTH_HASH" == \$2a\$* || "$KEIVO_AUTH_HASH" == \$2b\$* || "$KEIVO_AUTH_HASH" == \$2y\$* ]] || { echo 'Authentication hash is invalid.' >&2; exit 1; }
[[ "$COMPUTE_PROFILE" =~ ^(free-cpu|gpu)$ ]] || { echo 'Compute profile is invalid.' >&2; exit 1; }

azure_dir="$(cd -- "$script_dir/.." && pwd)"
project_dir="$(cd -- "$azure_dir/../.." && pwd)"

bundle="$(mktemp --suffix=.tgz)"
trap 'rm -f "$bundle"' EXIT
tar -czf "$bundle" \
  -C "$azure_dir" compose.yaml Caddyfile Dockerfile \
  -C "$script_dir" compose.local.override.yaml compose.cpu.override.yaml remote-deploy.sh \
  -C "$project_dir" requirements.txt server.py static

bundle_base64="$(base64 -w 0 "$bundle")"
upload_script="install -d -m 0750 /opt/keivo; printf '%s' '$bundle_base64' | base64 --decode > /tmp/keivo-deploy.tgz; tar -xzf /tmp/keivo-deploy.tgz -C /opt/keivo; rm -f /tmp/keivo-deploy.tgz; chmod 700 /opt/keivo/remote-deploy.sh"

run_vm_script_checked() {
  local script="$1" encoded wrapper message remote_status
  encoded="$(printf '%s' "$script" | base64 -w 0)"
  wrapper="set +e; printf '%s' '$encoded' | base64 --decode > /tmp/keivo-command.sh; bash /tmp/keivo-command.sh; status=\$?; printf '\n__KEIVO_EXIT_CODE__=%s\n' \"\$status\"; rm -f /tmp/keivo-command.sh; exit 0"
  message="$(az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "$wrapper" \
    --query 'value[0].message' \
    --output tsv)"
  printf '%s\n' "$message"
  remote_status="$(sed -n 's/.*__KEIVO_EXIT_CODE__=\([0-9][0-9]*\).*/\1/p' <<<"$message" | tail -n 1)"
  [[ "$remote_status" == "0" ]] || {
    echo "Azure VM command failed with remote exit code ${remote_status:-unknown}." >&2
    return 1
  }
}

run_vm_script_checked "$upload_script"

model_b64="$(printf '%s' "$OLLAMA_MODEL" | base64 -w 0)"
email_b64="$(printf '%s' "$ACME_EMAIL" | base64 -w 0)"
user_b64="$(printf '%s' "$KEIVO_AUTH_USER" | base64 -w 0)"
auth_hash_b64="$(printf '%s' "$KEIVO_AUTH_HASH" | base64 -w 0)"
remote_command="bash /opt/keivo/remote-deploy.sh '$auth_hash_b64' '$model_b64' '$KEIVO_FQDN' '$email_b64' '$user_b64' '$COMPUTE_PROFILE'"
unset KEIVO_AUTH_HASH auth_hash_b64

run_vm_script_checked "$remote_command"
