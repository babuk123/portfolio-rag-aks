# ------------------------------------------------------------------
# Re-applies the APIM API policy (CORS origins + gateway secret header) without rerunning setup-aks.ps1.
# Use after the UI address changes, e.g. after adding the Azure DNS label.
#
#   ./infra/update-apim-cors.ps1 -Prefix bab01
# ------------------------------------------------------------------
param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [string]$Location = "westus3"
)
$ErrorActionPreference = "Stop"
$rg     = "rg-portfolio-rag-$Prefix"
$apim   = "apim-portfolio-$Prefix"
$uiHost = "portfolio-$Prefix.$Location.cloudapp.azure.com"
$subId  = az account show --query id -o tsv
if ($LASTEXITCODE -ne 0) { throw "Run az login first." }
$ip = kubectl get svc portfolio-rag -n portfolio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

$policyXml = @"
<policies>
  <inbound>
    <base />
    <cors allow-credentials="false">
      <allowed-origins><origin>http://$uiHost</origin><origin>http://$ip</origin><origin>http://localhost:4200</origin></allowed-origins>
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
if ($LASTEXITCODE -ne 0) { throw "APIM policy update failed (see the error above)." }
Remove-Item $policyFile
Write-Host "CORS now allows: http://$uiHost, http://$ip, http://localhost:4200" -ForegroundColor Green
Write-Host "Open: http://$uiHost"
