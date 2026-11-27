# Portfolio RAG on AKS behind API Management

Same code as the App Service version, packaged as **one Docker image** (Angular UI + .NET 10 API), deployed to **Azure Kubernetes Service**, with every `/api` call going through **Azure API Management**.

```
 Advisor browser
   │  1. loads UI          http://<AKS public IP>            (Angular from the container)
   │  2. calls API         https://apim-portfolio-bab01.azure-api.net/portfolio/api/...
   ▼
 Azure API Management (Consumption)
   • one operation per endpoint      • CORS for the UI origin
   • adds X-Gateway-Secret header    (Named Value, encrypted)
   ▼
 AKS (1 x Standard_B2s node)  ── Service: LoadBalancer :80 → pod :8080
   Pod: portfolio-rag  (non-root, readiness + liveness on /health, CPU/memory limits)
   Env vars from Kubernetes Secret "portfolio-secrets"
   /api without the gateway header → 403
   ▼
 Azure SQL · Blob Storage · AI Search · Azure OpenAI   (same resources as before)

 GitHub Actions:  docker build → ghcr.io/<owner>/<repo>:<sha> → kubectl apply → rollout status → /health via APIM
```

## What changed from the App Service copy

| File | Change |
| --- | --- |
| `Dockerfile` (new) | 3 stages: node builds Angular, SDK publishes the API, small `aspnet` runtime image, non-root, port 8080 |
| `.dockerignore` (new) | Keeps node_modules, bin/obj, secrets and docs out of the image |
| `k8s/deployment.yaml` (new) | Namespace, Deployment (probes, limits, rolling update), LoadBalancer Service |
| `infra/setup-aks.ps1` (new) | Creates AKS, the Kubernetes Secret, deploys, creates APIM + operations + policy |
| `.github/workflows/aks.yml` (new) | Build and push the image to GHCR, deploy to AKS, auto-rollback, smoke test |
| `Program.cs` | Gateway-secret check on `/api`; `/config.json` for the UI; no HTTPS redirect in Production (TLS ends at APIM) |
| `Options/AppOptions.cs` | `GatewayOptions`, `UiOptions` |
| Angular `app-config.service.ts` (new), `api.service.ts`, `app.config.ts` | UI reads `apiBase` from `/config.json` at startup and calls the API through APIM |

Locally nothing changes: `apiBase` is empty and the gateway check is off when no secret is set.

## Steps

### 1. Unzip and create the GitHub repo
Unzip to `C:\babu\babu\resume\techprepration\PortfolioRagPoc-AKS`. On github.com create a **public** repo `portfolio-rag-aks` (no README), then:
```powershell
cd C:\babu\babu\resume\techprepration\PortfolioRagPoc-AKS
git init; git add .; git commit -m "Portfolio RAG on AKS behind API Management"
git branch -M main
git remote add origin https://github.com/babuk123/portfolio-rag-aks.git
git push -u origin main
```
The **build** job pushes the image to `ghcr.io/babuk123/portfolio-rag-aks`. **deploy** fails for now (no cluster yet), which is expected.

### 2. Make the image public (one time)
GitHub → your profile → **Packages** → `portfolio-rag-aks` → **Package settings** → **Change visibility** → **Public**.
That lets AKS pull it without a registry password. (We use GHCR instead of Azure Container Registry because your subscription can't grant the AcrPull role to the cluster identity.)

### 3. Create AKS + API Management and deploy
```powershell
Set-ExecutionPolicy -Scope Process Bypass
az login --tenant e8d9ec5a-7657-4f69-8bac-88ac99cc8b66
./infra/setup-aks.ps1 -Prefix bab01 -GitHubRepo "babuk123/portfolio-rag-aks" -PublisherEmail "<your email>"
```
About 15 minutes. At the end it prints the UI URL, the APIM URL and the KUBE_CONFIG instructions.
If `Standard_B2s` has no quota in West US 3, add `-NodeSize Standard_B2s_v2` or try `-Location eastus`.

### 4. Connect GitHub to the cluster
If you have the `gh` CLI, the script already saved the secret and variable. Otherwise add in **Settings → Secrets and variables → Actions**:
- Secret `KUBE_CONFIG`: the whole content of the printed kubeconfig file (then delete the file)
- Variable `APIM_HEALTH_URL`: the printed `.../portfolio/health` URL

Then **Actions → aks → Run workflow**. Both jobs should go green.

### 5. Test
| Check | Expected |
| --- | --- |
| `http://<AKS IP>` | The Advisor Workspace loads |
| Browser DevTools → Network | API calls go to `apim-portfolio-bab01.azure-api.net/portfolio/api/...` |
| `http://<AKS IP>/api/customers` | **403**: must go through APIM |
| `https://apim-portfolio-bab01.azure-api.net/portfolio/api/customers` | JSON list of customers |
| Azure portal → APIM → APIs → Portfolio RAG API → Test | Run any operation |

### 6. Useful kubectl commands
```powershell
kubectl get pods -n portfolio                       # pod status
kubectl logs -n portfolio deploy/portfolio-rag -f   # live logs
kubectl describe pod -n portfolio <pod-name>        # events: image pull, probes, OOMKilled
kubectl rollout undo deployment/portfolio-rag -n portfolio   # roll back
kubectl scale deployment/portfolio-rag -n portfolio --replicas=2
```

## Cost control
```powershell
az aks stop  -g rg-portfolio-rag-bab01 -n aks-portfolio-bab01    # no VM cost while stopped
az aks start -g rg-portfolio-rag-bab01 -n aks-portfolio-bab01    # then rerun setup-aks.ps1 (the IP may change)
```
Delete when done: `az aks delete -g rg-portfolio-rag-bab01 -n aks-portfolio-bab01 --yes` and `az apim delete -g rg-portfolio-rag-bab01 -n apim-portfolio-bab01 --yes`.

## Interview talking points
- **Multi-stage Dockerfile:** small runtime image (no SDK, no Node), layer caching for restore, non-root user.
- **Kubernetes basics shown:** Deployment, ReplicaSet history, rolling update with `maxUnavailable: 0`, readiness vs liveness probes, requests vs limits, Secret as env vars, LoadBalancer Service.
- **API Management:** a single entry point for APIs, operations per endpoint, policies (CORS, headers; add `rate-limit`, JWT validation, caching), secrets as Named Values, built-in test console and analytics.
- **Backend locked to APIM:** a shared-secret header with a constant-time compare. Production: private AKS + APIM in a VNet (or an internal load balancer), so the backend has no public IP at all.
- **Pipeline:** immutable image tags (git SHA), `kubectl rollout status` with automatic `rollout undo`, smoke test through the gateway.
- **POC trade-offs (say them out loud):** kubeconfig secret instead of OIDC (role assignment blocked by an ABAC condition); public GHCR image instead of ACR; one node, no HPA; HTTP inside the cluster.
- **Production next steps:** ACR + AcrPull for the kubelet identity, Workload Identity + Key Vault CSI driver for secrets, Managed Identity to Azure services, NGINX/AGIC ingress with TLS, HPA, Azure Monitor Container Insights, Helm or Kustomize, private cluster.
