# GitHub OIDC automation for Azure

This manual GitHub Actions deployment supports an Azure Free-subscription-oriented CPU profile and an optional paid GPU profile. It uses short-lived GitHub OIDC tokens, Azure Run Command, a system-assigned VM identity, ACR, Key Vault, Caddy, Docker Compose, and a persistent managed disk. It never opens SSH or the Ollama/application ports; the NSG permits only inbound TCP 80 and 443.

## Profiles and honest expectations

| Profile | VM | Model | Disk / ACR | Runtime |
|---|---|---|---|---|
| `free-cpu` (default) | `Standard_B2ats_v2` | `qwen3:0.6b` | two 64 GiB P6 `Premium_LRS` disks / Standard ACR | CPU-only, thinking disabled, 4 GiB swap, 2K context, 1K output cap, one parallel request |
| `gpu` | `Standard_NC4as_T4_v3` | `qwen3:8b` | 256 GiB recommended `Premium_LRS` / Standard | NVIDIA driver/toolkit, 32K context, 8K output cap |

The free CPU profile is deliberately small. It is suitable for testing, short everyday questions, and light drafting, but answers will be slower and materially less capable than the GPU profile. A burstable 1 GiB VM can spend CPU credits, swap heavily, or time out on long prompts. For eligible new Azure customers, the current first-12-month offer includes the selected B2ats v2 compute allowance, one Standard ACR, Key Vault operations, and two 64 GB P6 disks within published limits. Eligibility, elapsed free period, region/SKU availability, and prior usage still matter. A static Standard public IPv4 address has a nominal charge, and bandwidth or usage above an allowance can also cost money. Confirm Azure Cost Management after provisioning.

The workflow rejects mixed free-profile values. `free-cpu` requires exactly `Standard_B2ats_v2`, `qwen3:0.6b`, and a 64 GiB disk. For `gpu`, select an NC-series size, at least 128 GiB of disk, and an appropriate model such as `qwen3:8b`.

## One-time OIDC bootstrap

Run as an Azure administrator. The script opens interactive `az login`, creates a federated identity scoped to `repo:OWNER/REPO:environment:production`, and prints non-secret identifiers only.

```powershell
./deploy/azure/automation/bootstrap-oidc.ps1 `
  -SubscriptionId '00000000-0000-0000-0000-000000000000' `
  -GitHubOwner 'YOUR_GITHUB_OWNER' `
  -GitHubRepo 'YOUR_REPOSITORY' `
  -GitHubEnvironment 'production'
```

It grants `Contributor`, `Role Based Access Control Administrator`, and `Key Vault Secrets Officer` at subscription scope. These are powerful provisioning roles; prefer a dedicated subscription and remove the assignments when retiring the deployment.

## GitHub production environment

Create a GitHub Environment named **`production`**, add a required reviewer, and store:

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | ID printed by the bootstrap script |
| `AZURE_TENANT_ID` | ID printed by the bootstrap script |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |
| `KEIVO_AUTH_HASH` | Caddy bcrypt hash, not the plaintext password |

Generate the hash without placing the password in shell history:

```sh
docker run --rm -it caddy:2-alpine caddy hash-password
```

The workflow writes the masked hash to Key Vault through a temporary owner-readable file. The VM retrieves it using managed identity; it is never sent through Run Command or printed.

## Run and verify

Open **Actions → Deploy KEIVO to Azure → Run workflow**. Actions are `provision`, `update`, `deallocate`, and read-only `status`. Keep the same prefix for the same deployment. `acme_email` is required for provision/update. GPU users must change `compute_profile`, VM size, model, and disk inputs together.

Provision/update builds the current commit with `az acr build`, installs the selected profile's dependencies without SSH, starts the existing Compose/Caddy stack, and performs two real checks:

1. It creates a temporary chat through KEIVO, sends a prompt, requires streamed `delta` and `done` events, and deletes the test chat.
2. It verifies the public HTTPS endpoint returns `401`, proving DNS, TLS, Caddy, and authentication are active.

The HTTPS URL is emitted as a job output and job-summary link. `deallocate` stops VM compute billing but does not remove charges for disks, registry, Key Vault, static IP, or bandwidth. Persistent Docker volumes contain chats, models, images, and Caddy state; deleting the resource group is permanent unless separately backed up.
