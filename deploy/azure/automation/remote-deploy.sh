#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" == "0" ]] || { echo 'Deployment must run as root.' >&2; exit 1; }
[[ "$#" == "6" ]] || { echo 'Deployment parameters are incomplete.' >&2; exit 1; }

auth_hash="$(printf '%s' "$1" | base64 --decode)"
model="$(printf '%s' "$2" | base64 --decode)"
fqdn="$3"
acme_email="$(printf '%s' "$4" | base64 --decode)"
auth_user="$(printf '%s' "$5" | base64 --decode)"
compute_profile="$6"

[[ "$auth_hash" == \$2a\$* || "$auth_hash" == \$2b\$* || "$auth_hash" == \$2y\$* ]] || { echo 'Authentication hash is invalid.' >&2; exit 1; }
[[ "$auth_hash" != *$'\n'* && "$auth_hash" != *"'"* ]] || { echo 'Authentication hash has an invalid format.' >&2; exit 1; }
[[ "$model" =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo 'Model name is invalid.' >&2; exit 1; }
[[ "$fqdn" =~ ^[a-z0-9.-]+\.cloudapp\.azure\.com$ ]] || { echo 'Azure endpoint is invalid.' >&2; exit 1; }
[[ "$acme_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo 'ACME email is invalid.' >&2; exit 1; }
[[ "$auth_user" =~ ^[A-Za-z0-9._-]{3,64}$ ]] || { echo 'Authentication username is invalid.' >&2; exit 1; }
[[ "$compute_profile" =~ ^(free-cpu|gpu)$ ]] || { echo 'Compute profile is invalid.' >&2; exit 1; }
if [[ "$compute_profile" == "free-cpu" && "$model" != "qwen3:0.6b" ]]; then
  echo 'The free CPU profile requires qwen3:0.6b.' >&2
  exit 1
fi

cd /opt/keivo
for required in compose.yaml Caddyfile Dockerfile requirements.txt server.py static/index.html compose.local.override.yaml compose.cpu.override.yaml; do
  [[ -f "$required" ]] || { echo "Missing deployment file: $required" >&2; exit 1; }
done

umask 077
environment_tmp="$(mktemp /opt/keivo/.env.XXXXXX)"
trap 'rm -f "$environment_tmp"' EXIT
{
  printf 'KEIVO_DOMAIN=%s\n' "$fqdn"
  printf 'ACME_EMAIL=%s\n' "$acme_email"
  printf 'KEIVO_AUTH_USER=%s\n' "$auth_user"
  printf "KEIVO_AUTH_HASH='%s'\n" "$auth_hash"
  printf 'OLLAMA_MODEL=%s\n' "$model"
  printf 'OLLAMA_IMAGE_TAG=latest\n'
  if [[ "$compute_profile" == "free-cpu" ]]; then
    printf 'OLLAMA_KEEP_ALIVE=1m\n'
    printf 'OLLAMA_THINK=false\n'
    printf 'OLLAMA_NUM_PARALLEL=1\n'
    printf 'OLLAMA_MAX_LOADED_MODELS=1\n'
    printf 'OLLAMA_MAX_QUEUE=8\n'
    printf 'AGENT_MAX_OUTPUT_TOKENS=1024\n'
    printf 'AGENT_CONTEXT_WINDOW=2048\n'
    printf 'AGENT_USAGE_LIMIT_PER_HOUR=20\n'
  else
    printf 'OLLAMA_KEEP_ALIVE=10m\n'
    printf 'OLLAMA_NUM_PARALLEL=2\n'
    printf 'OLLAMA_MAX_LOADED_MODELS=1\n'
    printf 'OLLAMA_MAX_QUEUE=64\n'
    printf 'AGENT_MAX_OUTPUT_TOKENS=8192\n'
    printf 'AGENT_CONTEXT_WINDOW=32768\n'
    printf 'AGENT_USAGE_LIMIT_PER_HOUR=60\n'
  fi
  printf 'AGENT_TEMPERATURE=0.55\n'
  printf 'AGENT_MAX_INPUT_CHARS=24000\n'
  printf 'AGENT_REQUEST_TIMEOUT=600\n'
} > "$environment_tmp"
chmod 600 "$environment_tmp"
mv -f "$environment_tmp" /opt/keivo/.env
trap - EXIT
unset auth_hash

compose=(docker compose --env-file .env -f compose.yaml -f compose.local.override.yaml)
if [[ "$compute_profile" == "free-cpu" ]]; then
  compose+=(-f compose.cpu.override.yaml)
fi
"${compose[@]}" config --quiet
"${compose[@]}" pull --ignore-buildable
"${compose[@]}" build --pull keivo
"${compose[@]}" up -d --remove-orphans

# Do not report a successful deployment unless Caddy is actually bound on the
# host-facing HTTP port. HTTPS certificate issuance follows through this path.
edge_ready=false
for _ in {1..60}; do
  edge_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --header "Host: $fqdn" --max-time 5 http://127.0.0.1/ 2>/dev/null || true)"
  if [[ "$edge_code" == "301" || "$edge_code" == "302" || "$edge_code" == "307" || "$edge_code" == "308" || "$edge_code" == "401" ]]; then
    edge_ready=true
    break
  fi
  sleep 5
done
if [[ "$edge_ready" != true ]]; then
  "${compose[@]}" ps
  "${compose[@]}" logs --tail=160 caddy || true
  ss -lntp | grep -E ':(80|443) ' || true
  echo 'Caddy did not bind to the public web ports.' >&2
  exit 1
fi

healthy=false
for _ in {1..180}; do
  if "${compose[@]}" exec -T keivo python -c \
    "import json,urllib.request; d=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/status',timeout=5)); raise SystemExit(0 if d.get('ready') else 1)" \
    >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 5
done

if [[ "$healthy" != true ]]; then
  "${compose[@]}" ps
  "${compose[@]}" logs --tail=120 keivo ollama model-pull caddy || true
  echo 'KEIVO did not become ready before the health-check deadline.' >&2
  exit 1
fi

# Exercise the same persistent chat and NDJSON streaming path used by the browser.
# The temporary health-check conversation is deleted whether the prompt succeeds or fails.
"${compose[@]}" exec -T keivo python - <<'PY'
import json
import urllib.request

base = "http://127.0.0.1:8000"

def call(path, *, method="GET", payload=None, timeout=30):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        base + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    return urllib.request.urlopen(request, timeout=timeout)

with call("/api/chats", method="POST", payload={"title": "Deployment check"}) as response:
    chat_id = json.load(response)["chat"]["id"]

try:
    request = urllib.request.Request(
        f"{base}/api/chats/{chat_id}/messages",
        data=json.dumps({"content": "Reply briefly with the word READY."}).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/x-ndjson"},
    )
    saw_delta = False
    saw_done = False
    with urllib.request.urlopen(request, timeout=600) as response:
        for raw_line in response:
            if not raw_line.strip():
                continue
            event = json.loads(raw_line)
            if event.get("type") == "delta" and event.get("text"):
                saw_delta = True
            elif event.get("type") == "done":
                saw_done = True
            elif event.get("type") == "error":
                raise RuntimeError("Assistant stream returned an error event")
    if not (saw_delta and saw_done):
        raise RuntimeError("Assistant stream did not include both delta and done events")
finally:
    try:
        call(f"/api/chats/{chat_id}", method="DELETE", timeout=15).close()
    except Exception:
        pass
PY

"${compose[@]}" ps
printf 'KEIVO application and local model are healthy.\n'
