$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$base='https://raw.githubusercontent.com/viendhyra/RevitServer-Synx/main'
$target=Join-Path $env:TEMP ('RevitServer-Synx_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path (Join-Path $target 'src'),(Join-Path $target 'ui') -Force|Out-Null
foreach($file in @('RevitServer-Synx.ps1','src/Accelerator.psm1','ui/MainWindow.xaml')){$destination=Join-Path $target ($file-replace'/','\');Invoke-WebRequest -UseBasicParsing -Uri "$base/$file" -OutFile $destination}
Write-Host "RevitServer Synx downloaded to: $target" -ForegroundColor Cyan
& (Join-Path $target 'RevitServer-Synx.ps1')
