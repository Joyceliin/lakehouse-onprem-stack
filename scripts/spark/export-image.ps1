# Gera delta-stack/spark:4.1.2 e exporta para .tar (Windows / Docker Desktop).
# Uso (PowerShell, na raiz do repo):
#   .\scripts\spark\export-image.ps1
#   .\scripts\spark\export-image.ps1 -OutTar D:\artifacts\delta-stack-spark-4.1.2.tar
#
# Pré-requisito: Docker Desktop aberto e em execução (ícone da baleia na bandeja).
param(
    [string]$OutTar = "delta-stack-spark-4.1.2.tar"
)

$ErrorActionPreference = "Stop"
$Image = "delta-stack/spark:4.1.2"
$BaseImage = "apache/spark:4.1.2-scala2.13-java17-python3-ubuntu"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")

function Assert-DockerExit {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO em: $Step (exit $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

docker version --format "{{.Server.Version}}" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERRO: Docker daemon nao esta acessivel." -ForegroundColor Red
    Write-Host "  - Abra o Docker Desktop e aguarde 'Engine running'"
    Write-Host "  - Teste manual: docker version"
    exit 1
}

Write-Host "==> Build $Image (context: config/spark)"
$env:DOCKER_BUILDKIT = "1"
$dockerfile = Join-Path $Root "config\spark\Dockerfile"
$context = Join-Path $Root "config\spark"
& docker build -t $Image -f $dockerfile --build-arg "SPARK_BASE_IMAGE=$BaseImage" $context
Assert-DockerExit "docker build"

$outPath = if ([System.IO.Path]::IsPathRooted($OutTar)) { $OutTar } else { Join-Path (Get-Location) $OutTar }
$outDir = Split-Path -Parent $outPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

Write-Host "==> Export $outPath"
# --output evita ambiguidade com -o no PowerShell; caminho sempre entre aspas
& docker save --output "$outPath" "$Image"
Assert-DockerExit "docker save"

if (-not (Test-Path -LiteralPath $outPath)) {
    Write-Host "ERRO: arquivo nao foi criado: $outPath" -ForegroundColor Red
    exit 1
}

Get-Item -LiteralPath $outPath | Format-List Name, Length, LastWriteTime
& docker image inspect "$Image" --format "ID={{.Id}} Criada={{.Created}}"
Assert-DockerExit "docker image inspect"

Write-Host ""
Write-Host "Arquivo gerado: $outPath"
Write-Host "Copie para a VM1, ex.:"
Write-Host "  scp `"$outPath`" usuario@VM1:/opt/delta-lake/"
