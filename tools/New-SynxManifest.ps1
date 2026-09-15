[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'

# Пересобирает manifest.sha256. Запускать перед каждым тегом релиза,
# затем коммитить манифест вместе с изменёнными файлами.
$files = @('RevitServer-Synx.ps1', 'src/Accelerator.psm1', 'ui/MainWindow.xaml')
$lines = @()
foreach ($file in $files) {
    $path = Join-Path $RepoRoot ($file -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Не найден файл: $path" }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    $lines += "$hash  $file"
}
$manifest = Join-Path $RepoRoot 'manifest.sha256'
$lines | Set-Content -LiteralPath $manifest -Encoding ASCII
Write-Host "manifest.sha256 обновлён:" -ForegroundColor Cyan
$lines | ForEach-Object { Write-Host "  $_" }
