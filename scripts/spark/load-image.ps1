# Carrega imagem Spark a partir de .tar (Windows / Docker Desktop).
# Uso:
#   .\scripts\spark\load-image.ps1 -Tar delta-stack-spark-4.1.2.tar
param(
    [Parameter(Mandatory = $true)]
    [string]$Tar
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Tar)) {
    Write-Error "Arquivo nao encontrado: $Tar"
}

Write-Host "==> docker load -i $Tar"
docker load -i $Tar

Write-Host "==> Imagens delta-stack/spark"
docker images "delta-stack/spark"

Write-Host ""
Write-Host "Subir sem rebuild:"
Write-Host "  docker compose -f docker-compose.spark-vm1.yml --env-file .env up -d --no-build"
