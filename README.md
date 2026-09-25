# Platform Engineer / DevOps Engineer: Interview Exercise

A small Go HTTP service, containerized, provisioned on **Azure Container Apps** with **Terraform**, and delivered by a **GitHub Actions** pipeline that authenticates to Azure with **OIDC (no stored secrets)**. Everything runs inside free tiers.

| Section | Where |
| --- | --- |
| 1. Platform baseline (container, IaC, CI/CD) | `app/`, `Dockerfile`, `infra/`, `.github/workflows/`, `.azuredevops/pipeline.yaml` |
| 2. Security hardening | [Security](#security), `.trivyignore`, `docs/evidence/` |
| 3. Multi-cloud connectivity design | `docs/network-design.md`, `docs/network-diagram.drawio` / `.png` |
| 4. Observability & reliability | `docs/observability.md`, `docs/alerts.yaml` |

---

## Architecture

```
 developer ──PR──▶ GitHub ──▶ ci.yml:  test · lint · SCA/secret/IaC scan · build · image scan · tf plan · kind
                         └─▶ cd.yml:  build · scan · push (GHCR, by digest) · tf apply · smoke test
                                            │ OIDC (federated credential, no secret)
                                            ▼
            Azure subscription ── rg-platex-dev
                                   ├─ Log Analytics workspace (0.1 GB/day cap)
                                   ├─ Container Apps environment (Consumption)
                                   ├─ Container App  ca-platex-dev  (HTTPS ingress, 0–2 replicas)
                                   └─ runtime managed identity (no role assignments)
                      ── rg-platex-tfstate
                                   ├─ Storage account (Terraform state, Entra ID auth only)
                                   └─ GitHub OIDC identities: plan (PRs), deploy-dev (environment "dev")
```

## Repository layout

```
app/                      Go service (stdlib only): /health, /ready, /
Dockerfile                multi-stage → distroless static, non-root
infra/bootstrap/          one-time: state backend, OIDC identities, role assignments, budget
infra/                    main stack (main.tf, variables.tf, outputs.tf) + envs/
infra/modules/container-app/  reusable module: Log Analytics, environment, app, runtime identity
k8s/                      Deployment/Service/PDB/NetworkPolicy, validated on kind in CI
.github/workflows/        build.yml (reusable), ci.yml (PR), cd.yml (main)
.azuredevops/pipeline.yaml  Azure DevOps equivalent
docs/                     design docs (sections 3–4) and validation evidence
Makefile                  one-command local workflows (`make help`)
```

---

## Run locally

Prerequisites: Docker, Go 1.24 (tests only), optionally Trivy, hadolint, kind.

```bash
make test            # unit tests
make run             # build image and run on http://localhost:8080 (read-only FS, all caps dropped)
make smoke           # in another shell: curl /health
make scan            # Trivy: SCA + secrets, image, IaC
make kind-test       # deploy the k8s manifests to a local kind cluster
```

Endpoints:

| Path | Purpose |
| --- | --- |
| `GET /health` | liveness: `{"status":"ok"}` |
| `GET /ready` | readiness: 503 while draining on SIGTERM |
| `GET /` | service, **version (git SHA)**, env, used to verify a deploy |

Every response carries `X-Request-ID` (propagated or generated), and every request is logged as one JSON line with that ID.

## Deploy to Azure

One-time setup, about 15 minutes. Everything after that is automated.

1. **Accounts**: an Azure free account, and a public GitHub repo (Actions minutes and GHCR storage are free for public repos).
2. **Bootstrap** (run as subscription Owner, local state):
   ```bash
   az login
   cd infra/bootstrap
   cp terraform.tfvars.example terraform.tfvars   # fill in subscription, unique storage name, repo, email
   terraform init && terraform apply
   terraform output
   ```
3. **Backend config**: put `storage_account_name` from `backend_config` into `infra/envs/dev.backend.hcl`.
4. **GitHub settings** (no secrets, only IDs):
   - Repository variables: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_PLAN_CLIENT_ID`
   - Environment `dev` → variable `AZURE_DEPLOY_CLIENT_ID` (from `deploy_client_ids.dev`)
5. **First deploy**: push to `main`. The first `cd` run pushes the image, and GHCR creates the package as **private**. Set it to **public** once (Package settings → Change visibility), then re-run the deploy job. Container Apps pulls public images without registry credentials.
6. The deploy job prints the app URL and fails unless `/health` is 200 and `/` reports the commit SHA.

To tear down: `terraform -chdir=infra destroy` then `terraform -chdir=infra/bootstrap destroy`, or delete both resource groups.

## Pipeline

```
ci.yml (pull_request)                          cd.yml (push to main)
 ├─ build.yml (reusable)                         ├─ build.yml (push: true)
 │   ├─ test       gofmt · vet · go test -race    │   └─ … same gates, then push scanned image, output digest
 │   ├─ lint       hadolint · tflint              └─ deploy (environment: dev, concurrency: 1)
 │   ├─ security   trivy fs (SCA+secrets) · trivy config (IaC) → SARIF    OIDC → terraform apply image@sha256
 │   └─ image      buildx (GHA cache) · trivy image · SBOM                 smoke test: /health + version == SHA
 ├─ terraform-plan  OIDC (plan identity) · fmt · validate · plan → job summary
 └─ kind           apply k8s manifests · rollout status · curl /health
```

- **Build once, deploy the digest.** The image that passed the scan is the one that is pushed (`docker push` of the loaded image), and Terraform deploys it by `@sha256` digest, never by `latest`.
- **Caching.** BuildKit layer cache in the GitHub Actions cache (`type=gha,mode=max`), Go build cache mounts in the Dockerfile, and a Terraform provider plugin cache.
- **Safe re-runs.** Terraform is idempotent. Deploys are serialized (`concurrency: deploy-dev`, never cancelled mid-apply), state locking uses blob leases, and `-lock-timeout` absorbs contention.
- **Reusability.** One reusable build workflow serves both PR and main. One Terraform module is reused per environment through `envs/<env>.tfvars` and `envs/<env>.backend.hcl`.

---

## Design decisions & assumptions

| Decision | Choice | Why | Alternative considered |
| --- | --- | --- | --- |
| Language | Go, standard library only | Static binary, ~6 MB image, zero third-party dependencies to patch | Python/Node: faster to write, 10–20× larger images |
| Runtime image | `distroless/static:nonroot` | No shell or package manager, tiny attack surface, non-root by default | `scratch` (no CA certs or tzdata), Alpine (has a shell) |
| Hosting | Azure Container Apps, Consumption | Serverless containers, free HTTPS ingress, scale to zero, free monthly grant | AKS (paid nodes, more to operate), App Service |
| Registry | GHCR, public package | Free; push with the job's short-lived `GITHUB_TOKEN` | ACR: no free tier (Basic is ~$5/month) |
| CI/CD | GitHub Actions (+ Azure DevOps YAML) | Native OIDC to Entra ID, free for public repos | Azure DevOps only: its free agent needs an approval request |
| Auth to Azure | User-assigned managed identities with federated credentials | No client secrets to store or rotate; subject pinned to repo + environment | Service principal + secret |
| IaC state | Azure Storage, Entra ID auth, keys disabled | Native locking, versioning, no access keys | HCP Terraform free tier |
| Role assignments | Only in `bootstrap` | CI never needs Owner or User Access Administrator | CI assigns roles (needs privileged role) |

Assumptions: a single subscription and a single environment (`dev`), parameterized for more. The demo service must be publicly reachable, so it uses public ingress; Section 3's "no public endpoint" requirement applies to the enterprise design, not to this demo. The budget is $0, so nothing with an hourly charge is created (no ACR, NAT, gateways or databases).

---

## Security

### What I hardened, in priority order

1. **No long-lived credentials anywhere** (highest blast radius). GitHub → Azure uses OIDC federated credentials. The plan identity only works for `pull_request` and has Reader access. The deploy identity only works from the `dev` GitHub Environment and has Contributor on one resource group. The state storage account has shared keys disabled. GHCR uses the per-job `GITHUB_TOKEN`.
2. **Vulnerable artifacts cannot ship.** Trivy SCA and secret scanning of the repo, an IaC scan of Terraform and k8s, and an image scan **before push**. Each fails the build on fixable HIGH/CRITICAL findings. Results go to the GitHub Security tab (SARIF), and a CycloneDX SBOM is attached to every build.
3. **Minimal, non-root runtime.** Distroless static image, UID 65532, no shell. In k8s: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop all capabilities, `RuntimeDefault` seccomp, no service-account token, default-deny NetworkPolicy.
4. **Least privilege at runtime.** The app's managed identity has no role assignments.
5. **Supply chain.** Every third-party action is pinned by commit SHA, workflows start from `permissions: {}` and grant per job, and Dependabot tracks actions, base images, Go modules and providers.

### Policy on HIGH/CRITICAL findings

The build **fails** on HIGH or CRITICAL findings that have a fix available (`--ignore-unfixed`). Unfixed CVEs don't block delivery, because the team cannot act on them; they stay visible in the Security tab. Any accepted finding goes in `.trivyignore` with a reason, an owner and an expiry date, and is reviewed like code. There is currently one accepted finding (`AZU-0012`, state storage network access; see the file for the rationale and mitigations).

### Evidence

- `docs/evidence/trivy-config.txt`: IaC scan. It flagged 1 CRITICAL, which is accepted with its rationale, leaving 0 unaccepted.
- `docs/evidence/local-checks.txt`: unit tests, binary size, hadolint, terraform fmt, tflint, actionlint.
- `docs/evidence/trivy-image.txt`, `trivy-fs.txt`: generated by `make scan` or taken from the CI logs (TODO once the pipeline runs).

### Tradeoffs made under the time and budget limits

- Public ingress on the demo app, and a public GHCR image instead of a private ACR.
- `--ignore-unfixed` trades completeness for a pipeline that doesn't block on unpatchable CVEs.
- The deploy identity uses the built-in Contributor role on the resource group rather than a custom role.
- The state storage account is reachable from the internet (Entra ID auth only), because hosted runners have no fixed IPs.
- No image signing or admission verification.
- The Azure DevOps variant needs one scoped PAT to push to GHCR (GitHub Actions needs none).

### What I'd fix with more time

VNet-integrated Container Apps environment with internal ingress behind Front Door + WAF; private ACR with managed-identity pull and Defender for Containers; cosign/Notation signing verified at deploy; a custom least-privilege deploy role; Azure Policy (deny public storage, require tags); a private endpoint for state with self-hosted runners; branch protection with required checks; and a DAST baseline (OWASP ZAP) against the deployed URL.

---

## Known limitations

- Single environment. `stg` and `prod` need a tfvars file, a backend file, a GitHub Environment and a bootstrap entry each.
- The deploy applies without a separate manual approval. The PR plan is the review gate; a required reviewer can be added on the `prod` environment.
- PRs from forks get no OIDC token, so their Terraform plan job fails by design.
- Scale-to-zero causes a cold start of a few seconds on the first request; the smoke test retries.
- Base images are pinned by tag, not digest. Dependabot will propose digest pins and updates.

## Improvements

Promotion of the same digest across environments; Terraform plan artifact reused by apply; OpenTelemetry instrumentation (see `docs/observability.md`); Infracost in PRs; a Helm chart instead of raw manifests if the k8s path becomes the real target.

## What I tried / where I got stuck

_Keep this section honest: note anything that didn't work first time and how you resolved it._
