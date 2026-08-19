<#
.SYNOPSIS
  Sets up a preview-environment cluster on this machine.

.DESCRIPTION
  Creates a local Kubernetes cluster, installs the TTL cleanup job, and registers a
  GitHub Actions runner. After this, any repository can get preview environments by
  calling the reusable workflow.

.EXAMPLE
  ./scripts/install.ps1 -Repo myorg/myapp -Token AABBCC...

.EXAMPLE
  ./scripts/install.ps1 -Repo myorg/myapp -Token AABBCC... -Domain preview.example.com
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$Repo,

  [Parameter(Mandatory = $true)]
  [string]$Token,

  [string]$Domain = "",
  [string]$ClusterName = "preview",
  [int]$Port = 8080,
  [string]$RunnerDir = "$HOME\preview-runner"
)

$ErrorActionPreference = "Stop"

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

Step "Checking prerequisites"

$missing = @()
foreach ($tool in @("docker", "kubectl", "helm", "k3d")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $missing += $tool }
}
if ($missing.Count -gt 0) {
  Write-Host "`nMissing: $($missing -join ', ')" -ForegroundColor Red
  Write-Host "Install them with:`n"
  foreach ($m in $missing) {
    switch ($m) {
      "docker"  { Write-Host "  winget install Docker.DockerDesktop" }
      "kubectl" { Write-Host "  winget install Kubernetes.kubectl" }
      "helm"    { Write-Host "  winget install Helm.Helm" }
      "k3d"     { Write-Host "  winget install k3d" }
    }
  }
  Write-Host "`nThen restart your terminal and run this script again."
  exit 1
}
Ok "docker, kubectl, helm, k3d found"

try { docker version --format '{{.Server.Version}}' | Out-Null }
catch { Write-Host "`nDocker is not running. Start Docker Desktop and try again." -ForegroundColor Red; exit 1 }
Ok "docker daemon reachable"

Step "Resolving host address"

if ($Domain) {
  $hostIP = ""
  Ok "using domain $Domain"
} else {
  $hostIP = (Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
    Select-Object -First 1).IPv4Address.IPAddress
  if (-not $hostIP) { $hostIP = "127.0.0.1" }
  Ok "using sslip.io on $hostIP - no domain needed"
}

Step "Creating cluster '$ClusterName'"

$existing = k3d cluster list -o json 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq $ClusterName }
if ($existing) {
  Warn "cluster already exists, starting it"
  k3d cluster start $ClusterName | Out-Null
} else {
  k3d cluster create $ClusterName --agents 2 --port "${Port}:80@loadbalancer" | Out-Null
  Ok "cluster created"
}

# k3d writes host.docker.internal into the kubeconfig, which follows the current LAN
# address and breaks whenever the machine changes network.
$apiPort = (docker port "k3d-$ClusterName-serverlb" 6443 2>$null) -replace '.*:', ''
if ($apiPort) {
  kubectl config set-cluster "k3d-$ClusterName" --server="https://127.0.0.1:$apiPort" | Out-Null
  Ok "kubeconfig pinned to 127.0.0.1:$apiPort"
}

kubectl wait --for=condition=Ready nodes --all --timeout=120s | Out-Null
Ok "nodes ready"

Step "Installing TTL cleanup"

$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) { $repoRoot = Split-Path $PSScriptRoot -Parent }

docker build -t pr-preview-ttl-cleanup:dev "$repoRoot/tools/ttl-cleanup" | Out-Null
k3d image import pr-preview-ttl-cleanup:dev -c $ClusterName | Out-Null
kubectl apply -f "$repoRoot/infra/ttl-cleanup.yaml" | Out-Null
Ok "idle previews will be reaped after 48h"

Step "Registering GitHub Actions runner"

if (Test-Path "$RunnerDir\.runner") {
  Warn "runner already configured at $RunnerDir"
} else {
  New-Item -ItemType Directory -Force $RunnerDir | Out-Null
  $version = (Invoke-RestMethod "https://api.github.com/repos/actions/runner/releases/latest").tag_name.TrimStart("v")
  $zip = "$RunnerDir\runner.zip"

  Ok "downloading runner $version"
  Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v$version/actions-runner-win-x64-$version.zip" -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $RunnerDir -Force
  Remove-Item $zip

  Push-Location $RunnerDir
  & "$RunnerDir\config.cmd" --url "https://github.com/$Repo" --token $Token --name "preview-$env:COMPUTERNAME" --labels self-hosted,preview --unattended --replace
  Pop-Location
  Ok "runner registered for $Repo"
}

$sample = @"
name: preview
on:
  pull_request:
    types: [opened, synchronize, closed]

jobs:
  preview:
    uses: raviduravisara/pr-preview/.github/workflows/preview.yml@main
    with:
$(if ($Domain) { "      domain: $Domain" } else { "      host-ip: $hostIP" })
      app-port: 3000
      database: none
"@

Write-Host "`n" -NoNewline
Write-Host "Setup complete." -ForegroundColor Green
Write-Host @"

Preview URLs will look like:
  $(if ($Domain) { "https://pr-1-preview.$Domain" } else { "http://pr-1-preview.$($hostIP -replace '\.','-').sslip.io:$Port" })

Two things left:

1. Start the runner and leave it open:
     cd $RunnerDir
     ./run.cmd

2. Add this file to any repository that should get previews,
   at .github/workflows/preview.yml:

$sample
"@
