#!/usr/bin/env bash

# Azure CLI on hosted runners can occasionally fail inside Python imports or
# while decoding a long-running-operation response. Retry only known transient
# failures; real Azure validation/quota errors still fail immediately.
export AZURE_CORE_COLLECT_TELEMETRY=0

az() {
  local attempt status error_file
  error_file="$(mktemp)"
  for attempt in 1 2 3 4 5; do
    : > "$error_file"
    if command az "$@" 2>"$error_file"; then
      [[ ! -s "$error_file" ]] || cat "$error_file" >&2
      rm -f "$error_file"
      return 0
    else
      status=$?
    fi

    cat "$error_file" >&2
    if ! grep -Eqi '_DeadlockError|deadlock detected by _ModuleLock|content for this response was already consumed|TooManyRequests|InternalServerError|ServiceUnavailable|temporarily unavailable' "$error_file"; then
      rm -f "$error_file"
      return "$status"
    fi

    printf 'Transient Azure CLI failure; retrying (%s/5)...\n' "$attempt" >&2
    sleep $((attempt * 4))
  done

  rm -f "$error_file"
  return "$status"
}
