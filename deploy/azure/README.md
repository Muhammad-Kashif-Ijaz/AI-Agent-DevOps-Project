# KEIVO on an Azure GPU VM

This deployment runs KEIVO, Ollama, a one-shot model pull, and Caddy on one Docker Compose host. Caddy is the only public service. KEIVO is private behind Caddy, while Ollama is isolated from the public edge and publishes no host port. Its separate outbound-only network exists solely so the Ollama daemon can download model files.

## Azure prerequisites

- Use an Azure N-series Linux VM with enough VRAM for the selected model.
- Install the NVIDIA driver, Docker Engine with the Compose plugin, and NVIDIA Container Toolkit. Confirm containers can see the GPU before starting KEIVO.
- In the Network Security Group, allow TCP 80 and 443 from the internet, optionally UDP 443 for HTTP/3, and restrict SSH to trusted administrator addresses. Allow outbound HTTPS for container images, certificates, and the model pull.
- Point an A record for the chosen hostname to the VM public IP. Caddy obtains and renews HTTPS certificates after DNS resolves.

GPU VMs can be expensive and are billed while allocated. Deallocate the VM when it is not needed to stop compute billing; managed disks and some networking resources may continue to incur charges. Check the Azure calculator for the chosen region and VM size before provisioning.

## Configure and start

From this directory on the VM:

```sh
cp .env.example .env
docker run --rm -it caddy:2-alpine caddy hash-password
```

Edit `.env`, replace every placeholder, and paste the generated bcrypt value into `KEIVO_AUTH_HASH` inside single quotes. Choose a strong password and keep `.env` readable only by its owner:

```sh
chmod 600 .env
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d --build
docker compose --env-file .env ps
```

The `model-pull` container runs once and KEIVO waits for it to finish. Follow the first download with `docker compose --env-file .env logs -f model-pull`. To use another model, change `OLLAMA_MODEL` in `.env` and run `docker compose --env-file .env up -d` again.

`AGENT_USAGE_LIMIT_PER_HOUR` controls the rolling per-client capacity guard. The default is 60 accepted questions per hour. When a client reaches it, KEIVO returns a retry time and the interface shows when that client can continue.

## Data and operations

Named volumes persist chat history (`keivo_data`), model files (`ollama_data`), and Caddy certificates/configuration (`caddy_data`, `caddy_config`). Include these volumes in the VM backup plan. Do not publish ports 8000 or 11434 in Azure, Docker, or a second proxy. Only Caddy should receive public traffic.

Useful checks:

```sh
docker compose --env-file .env ps
docker compose --env-file .env logs --tail=100 keivo ollama caddy
curl -I https://your-keivo-hostname.example
```

To stop the stack without deleting persistent data, run `docker compose --env-file .env down`. Avoid `down -v` unless permanent data deletion is intended.
