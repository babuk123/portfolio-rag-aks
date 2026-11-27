# ------------------------------------------------------------------
# AKS + API Management setup for the Portfolio RAG POC.
# Reuses the AI resources from setup-azure.ps1 (OpenAI, AI Search, Blob) and the Azure SQL
# database already created for the App Service version.
#
#   az login --tenant <your tenant id>
#   ./infra/setup-aks.ps1 -Prefix bab01 -GitHubRepo "babuk123/portfolio-rag-aks" -PublisherEmail "you@example.com"
#
# Creates:  AKS (1 x Standard_B2s node, Free tier control plane)
#           Kubernetes namespace, Secret, Deployment, LoadBalancer Service
#           API Management (Consumption tier) with an API that forwards to AKS
# Cost:     ~1 B2s node while running (stop it when idle: see the end of this file)
# Safe to rerun: every step checks what already exists.
# ------------------------------------------------------------------
param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$GitHubRepo,        # owner/repo that builds the image (GHCR)
    [Parameter(Mandatory = $true)][string]$PublisherEmail,    # APIM requires a publisher email
    [string]$Location = "westus3",
    [string]$ApimLocation = "",                               # defaults to $Location
    [string]$NodeSize = "Standard_B2s",
    [string]$SqlConnection = ""                               # optional; otherwise read from the App Service web app
)

$ErrorActionPreference = "Stop"
function Assert-Az([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "FAILED: $Step (see the error above). Fix it and rerun this script." }
}

if (-not $ApimLocation) { $ApimLocation = $Location }
$rg      = "rg-portfolio-rag-$Prefix"
$aks     = "aks-portfolio-$Prefix"
$apim    = "apim-portfolio-$Prefix"
$storage = "stportfolio$Prefix"
$search  = "srch-portfolio-$Prefix"
$openai  = "oai-portfolio-$Prefix"
$webapp  = "app-portfolio-$Prefix"
$ns      = "portfolio"
$image   = "ghcr.io/$($GitHubRepo.ToLower()):latest"
$subId   = az account show --query id -o tsv; Assert-Az 'az account show'

# ---------- 0. Providers + kubectl ----------
Write-Host "0/7 Providers and kubectl" -ForegroundColor Cyan
az provider register --namespace Microsoft.ContainerService --wait; Assert-Az 'register ContainerService'
az provider register --namespace Microsoft.ApiManagement --wait;   Assert-Az 'register ApiManagement'
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    az aks install-cli; Assert-Az 'az aks install-cli'
    $env:PATH += ";$env:USERPROFILE\.azure-kubectl;$env:USERPROFILE\.azure-kubelogin"
}

# ---------- 1. AKS cluster ----------
Write-Host "1/7 AKS cluster $aks ($NodeSize x1, $Location) - takes 5-10 minutes" -ForegroundColor Cyan
$exists = az aks list -g $rg --query "[?name=='$aks'].name" -o tsv; Assert-Az 'az aks list'
if (-not $exists) {
    az aks create -g $rg -n $aks -l $Location --node-count 1 --node-vm-size $NodeSize `
        --tier free --enable-managed-identity --generate-ssh-keys -o none
    Assert-Az 'az aks create'
} else {
    $state = az aks show -g $rg -n $aks --query powerState.code -o tsv
    if ($state -eq "Stopped") { az aks start -g $rg -n $aks; Assert-Az 'az aks start' }
}
az aks get-credentials -g $rg -n $aks --overwrite-existing; Assert-Az 'az aks get-credentials'

# ---------- 2. Gather settings ----------
Write-Host "2/7 Reading keys from the existing Azure resources" -ForegroundColor Cyan
$openaiKey   = az cognitiveservices account keys list -n $openai -g $rg --query key1 -o tsv; Assert-Az 'openai key'
$searchKey   = az search admin-key show --service-name $search -g $rg --query primaryKey -o tsv; Assert-Az 'search key'
$storageConn = az storage account show-connection-string -n $storage -g $rg --query connectionString -o tsv; Assert-Az 'storage'
if (-not $SqlConnection) {
    $SqlConnection = az webapp config connection-string list -n $webapp -g $rg --query "[0].value" -o tsv; Assert-Az 'sql connection'
}
if (-not $SqlConnection) { throw "No SQL connection string found. Pass -SqlConnection '<Azure SQL connection string>'." }
$gatewaySecret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 40 | ForEach-Object { [char]$_ })

function Set-K8sSecret([string]$apiBase) {
    kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    kubectl create secret generic portfolio-secrets -n $ns `
        --from-literal="AzureOpenAI__Endpoint=https://$openai.openai.azure.com/" `
        --from-literal="AzureOpenAI__ApiKey=$openaiKey" `
        --from-literal="AzureOpenAI__ChatDeployment=gpt-4.1-mini" `
        --from-literal="AzureOpenAI__EmbeddingDeployment=text-embedding-3-small" `
        --from-literal="AzureSearch__Endpoint=https://$search.search.windows.net" `
        --from-literal="AzureSearch__ApiKey=$searchKey" `
        --from-literal="BlobStorage__ConnectionString=$storageConn" `
        --from-literal="ConnectionStrings__Sql=$SqlConnection" `
        --from-literal="ApiGateway__SharedSecret=$gatewaySecret" `
        --from-literal="Ui__ApiBase=$apiBase" `
        --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    Assert-Az 'kubectl secret'
}

# ---------- 3. Deploy to AKS ----------
Write-Host "3/7 Deploying $image" -ForegroundColor Cyan
Set-K8sSecret ""
(Get-Content (Join-Path $PSScriptRoot "..\k8s\deployment.yaml") -Raw) -replace 'IMAGE_PLACEHOLDER', $image | kubectl apply -f -
Assert-Az 'kubectl apply'

Write-Host "4/7 Waiting for the public IP of the Service" -ForegroundColor Cyan
$ip = ""
for ($i = 0; $i -lt 40 -and -not $ip; $i++) {
    Start-Sleep -Seconds 10
    $ip = kubectl get svc portfolio-rag -n $ns -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}
if (-not $ip) { throw "No external IP yet. Run: kubectl get svc -n $ns  (then rerun this script)" }
Write-Host "   AKS public IP: $ip"

# ---------- 5. API Management ----------
Write-Host "5/7 API Management $apim (Consumption) - first creation takes a few minutes" -ForegroundColor Cyan
$apimExists = az apim list -g $rg --query "[?name=='$apim'].name" -o tsv; Assert-Az 'az apim list'
if (-not $apimExists) {
    az apim create -n $apim -g $rg -l $ApimLocation --sku-name Consumption `
        --publisher-email $PublisherEmail --publisher-name "Portfolio RAG POC" -o none
    Assert-Az 'az apim create'
}
$gatewayUrl = az apim show -n $apim -g $rg --query gatewayUrl -o tsv; Assert-Az 'az apim show'

# Secret stored as an APIM Named Value (encrypted), referenced in the policy as {{gateway-secret}}
az apim nv create --service-name $apim -g $rg --named-value-id gateway-secret --display-name gateway-secret `
    --value $gatewaySecret --secret true -o none
Assert-Az 'named value'

# API: https://<apim>.azure-api.net/portfolio/<operation>  ->  http://<aks ip>/<operation>
az apim api create --service-name $apim -g $rg --api-id portfolio --path portfolio `
    --display-name "Portfolio RAG API" --service-url "http://$ip" --protocols https `
    --subscription-required false -o none
Assert-Az 'az apim api create'
# One APIM operation per API endpoint: shows up in the APIM portal and test console,
# and lets you put different policies on each (for example a stricter rate limit on /api/chat).
$ops = @(
    @{ id = "list-customers";      m = "GET";  t = "/api/customers" },
    @{ id = "get-portfolio";       m = "GET";  t = "/api/customers/{customerId}" },
    @{ id = "list-reviews";        m = "GET";  t = "/api/customers/{customerId}/reviews" },
    @{ id = "create-review";       m = "POST"; t = "/api/customers/{customerId}/reviews" },
    @{ id = "download-review-pdf"; m = "GET";  t = "/api/reviews/{reviewId}/pdf" },
    @{ id = "get-file";            m = "GET";  t = "/api/files" },
    @{ id = "index-sample-policy"; m = "POST"; t = "/api/documents/sample-policy" },
    @{ id = "upload-policy";       m = "POST"; t = "/api/documents/policy" },
    @{ id = "chat";                m = "POST"; t = "/api/chat" },
    @{ id = "health";              m = "GET";  t = "/health" }
)
foreach ($op in $ops) {
    $params = @()
    foreach ($p in [regex]::Matches($op.t, '\{(\w+)\}')) {
        $params += @("--template-parameters", "name=$($p.Groups[1].Value)", "type=string", "required=true")
    }
    az apim api operation create --service-name $apim -g $rg --api-id portfolio `
        --operation-id $op.id --display-name "$($op.m) $($op.t)" --method $op.m --url-template $op.t @params -o none
    Assert-Az "operation $($op.id)"
}

# Policy: CORS for the UI origin + secret header to the backend
$policyXml = @"
<policies>
  <inbound>
    <base />
    <cors allow-credentials="false">
      <allowed-origins><origin>http://$ip</origin><origin>http://localhost:4200</origin></allowed-origins>
      <allowed-methods><method>GET</method><method>POST</method><method>OPTIONS</method></allowed-methods>
      <allowed-headers><header>*</header></allowed-headers>
    </cors>
    <set-header name="X-Gateway-Secret" exists-action="override"><value>{{gateway-secret}}</value></set-header>
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
"@
$policyFile = Join-Path $env:TEMP "apim-policy-$Prefix.json"
[System.IO.File]::WriteAllText($policyFile, (@{ properties = @{ format = "rawxml"; value = $policyXml } } | ConvertTo-Json -Depth 5))
az rest --method put `
    --uri "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim/apis/portfolio/policies/policy?api-version=2022-08-01" `
    --body "@$policyFile" -o none
Assert-Az 'apim policy'
Remove-Item $policyFile

# ---------- 6. Point the UI at APIM ----------
Write-Host "6/7 Pointing the UI at API Management and restarting the pod" -ForegroundColor Cyan
Set-K8sSecret "$gatewayUrl/portfolio"
kubectl rollout restart deployment/portfolio-rag -n $ns | Out-Null
kubectl rollout status deployment/portfolio-rag -n $ns --timeout=180s; Assert-Az 'rollout'

# ---------- 7. Kubeconfig for GitHub Actions ----------
Write-Host "7/7 GitHub secret KUBE_CONFIG" -ForegroundColor Cyan
$kubeFile = Join-Path $env:TEMP "kubeconfig-$Prefix"
az aks get-credentials -g $rg -n $aks --admin --file $kubeFile --overwrite-existing; Assert-Az 'admin kubeconfig'
if (Get-Command gh -ErrorAction SilentlyContinue) {
    Get-Content $kubeFile -Raw | gh secret set KUBE_CONFIG -R $GitHubRepo
    gh variable set APIM_HEALTH_URL -R $GitHubRepo -b "$gatewayUrl/portfolio/health"
    Write-Host "   KUBE_CONFIG secret and APIM_HEALTH_URL variable saved in GitHub." -ForegroundColor Green
    Remove-Item $kubeFile
} else {
    Write-Host "   In GitHub > Settings > Secrets and variables > Actions add:" -ForegroundColor Yellow
    Write-Host "     Secret   KUBE_CONFIG     = the whole content of $kubeFile (then delete the file)"
    Write-Host "     Variable APIM_HEALTH_URL = $gatewayUrl/portfolio/health"
}

Write-Host "`nDone." -ForegroundColor Green
Write-Host "  UI (served by AKS):      http://$ip"
Write-Host "  API through APIM:        $gatewayUrl/portfolio/api/customers"
Write-Host "  Direct API call (403):   http://$ip/api/customers   <- blocked: must go through APIM"
Write-Host "`nSave money when idle:"
Write-Host "  az aks stop  -g $rg -n $aks      # stops the node (no VM cost)"
Write-Host "  az aks start -g $rg -n $aks      # the public IP can change after start: rerun this script"
