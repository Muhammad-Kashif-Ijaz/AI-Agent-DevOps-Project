#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
COMPUTE_PROFILE="${COMPUTE_PROFILE:-${1:-free-cpu}}"
COMPUTE_PROFILE="${COMPUTE_PROFILE#profile=}"
[[ "$COMPUTE_PROFILE" =~ ^(free-cpu|gpu)$ ]] || { echo 'Unsupported compute profile.' >&2; exit 1; }

retry() {
  local attempts="$1"
  shift
  local delay=5
  for ((index = 1; index <= attempts; index++)); do
    if "$@"; then
      return 0
    fi
    if (( index == attempts )); then
      return 1
    fi
    sleep "$delay"
    delay=$((delay < 30 ? delay + 5 : 30))
  done
}

if [[ "$(id -u)" != "0" ]]; then
  echo 'This bootstrap must run as root.' >&2
  exit 1
fi

# Fresh Azure images can keep apt/dpkg locked while cloud-init finishes.
if command -v cloud-init >/dev/null 2>&1; then
  timeout 600 cloud-init status --wait >/dev/null 2>&1 || true
fi
retry 8 apt-get update -y
retry 8 apt-get install -y ca-certificates curl gnupg jq lsb-release apt-transport-https

# Mount the dedicated managed disk and keep Docker's images and named volumes on it.
disk_link='/dev/disk/azure/scsi1/lun10'
for _ in {1..60}; do
  [[ -e "$disk_link" ]] && break
  sleep 2
done
[[ -e "$disk_link" ]] || { echo 'Managed data disk LUN 10 was not found.' >&2; exit 1; }
disk_device="$(readlink -f "$disk_link")"

if ! blkid "$disk_device" >/dev/null 2>&1; then
  mkfs.ext4 -F -L keivo-data "$disk_device"
fi

disk_uuid="$(blkid -s UUID -o value "$disk_device")"
[[ -n "$disk_uuid" ]] || { echo 'Managed data disk UUID was not found.' >&2; exit 1; }
install -d -m 0755 /srv/keivo-docker
if ! grep -q "UUID=$disk_uuid" /etc/fstab; then
  printf 'UUID=%s /srv/keivo-docker ext4 defaults,nofail,discard 0 2\n' "$disk_uuid" >> /etc/fstab
fi
mountpoint -q /srv/keivo-docker || mount /srv/keivo-docker
install -d -m 0711 /srv/keivo-docker/docker

if [[ "$COMPUTE_PROFILE" == "free-cpu" ]]; then
  # The free-size VM has little RAM. Disk-backed swap prevents model startup from
  # being killed while keeping all persistent data on the managed data disk.
  swap_file='/srv/keivo-docker/keivo.swap'
  if [[ ! -f "$swap_file" ]]; then
    fallocate -l 4G "$swap_file"
    chmod 600 "$swap_file"
    mkswap "$swap_file" >/dev/null
  fi
  if ! grep -qF "$swap_file none swap sw 0 0" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$swap_file" >> /etc/fstab
  fi
  swapon --show=NAME | grep -qx "$swap_file" || swapon "$swap_file"
  printf 'vm.swappiness=20\n' > /etc/sysctl.d/90-keivo-swap.conf
  sysctl --system >/dev/null
fi

# Docker Engine and Compose plugin from Docker's signed Ubuntu repository.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
ubuntu_codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
architecture="$(dpkg --print-architecture)"
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
  "$architecture" "$ubuntu_codename" > /etc/apt/sources.list.d/docker.list

if [[ "$COMPUTE_PROFILE" == "gpu" ]]; then
  # NVIDIA Container Toolkit is intentionally absent from the free CPU profile.
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
else
  rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
fi

retry 8 apt-get update -y
retry 8 apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
if [[ "$COMPUTE_PROFILE" == "gpu" ]]; then
  retry 8 apt-get install -y nvidia-container-toolkit
fi

install -d -m 0755 /etc/docker
if [[ ! -s /etc/docker/daemon.json ]]; then
  printf '{}\n' > /etc/docker/daemon.json
fi
jq '. + {"data-root":"/srv/keivo-docker/docker"}' \
  /etc/docker/daemon.json > /etc/docker/daemon.json.tmp
mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
if [[ "$COMPUTE_PROFILE" == "gpu" ]]; then
  nvidia-ctk runtime configure --runtime=docker
fi
systemctl enable --now docker
systemctl restart docker

# Ubuntu normally leaves UFW disabled on Azure, but explicitly preserve the
# public web ports when an image or policy has enabled it.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw reload >/dev/null
fi

if [[ "$COMPUTE_PROFILE" == "gpu" ]]; then
  # The driver extension may still be settling after the VM restart.
  retry 30 nvidia-smi >/dev/null
  retry 3 docker run --rm --gpus all nvidia/cuda:12.2.2-base-ubuntu22.04 nvidia-smi >/dev/null
fi

docker version >/dev/null
docker compose version >/dev/null
printf 'VM dependencies for profile %s are ready.\n' "$COMPUTE_PROFILE"
