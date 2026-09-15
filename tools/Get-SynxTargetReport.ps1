[CmdletBinding()]
param([string]$Year = '2022')
$ErrorActionPreference = 'Continue'

# Запускать от администратора на самом сервере. Показывает, что именно
# выбрал бы Synx, ничего не изменяя.

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Accelerator.psm1') -Force

Write-Host "`n=== IIS: все пулы и их приложения ===" -ForegroundColor Cyan
$inventory = @(Get-SynxAppPoolInventory)
$inventory | ForEach-Object {
    [pscustomobject]@{
        Name = $_.Name
        State = $_.State
        Selected = $(try { @(Select-SynxRepairPools -Pools @($_) -Year $Year).Count -gt 0 } catch { "ОТКАЗ: $($_.Exception.Message)" })
        Paths = ((@($_.Paths) | Sort-Object -Unique) -join ' | ')
    }
} | Format-Table -AutoSize -Wrap

Write-Host "=== Пулы, которые будут остановлены при ремонте $Year ===" -ForegroundColor Yellow
try { @(Select-SynxRepairPools -Pools $inventory -Year $Year) | Format-Table Name, State -AutoSize }
catch { Write-Host $_.Exception.Message -ForegroundColor Red }

Write-Host "`n=== Рабочие процессы w3wp ===" -ForegroundColor Cyan
foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='w3wp.exe'" -ErrorAction SilentlyContinue)) {
    [pscustomobject]@{
        ProcessId = $process.ProcessId
        Pool = Get-SynxPoolNameFromCommandLine ([string]$process.CommandLine)
    }
} | Format-Table -AutoSize

Write-Host "`n=== Службы AutoSync ===" -ForegroundColor Cyan
Get-CimInstance Win32_Service | Where-Object { $_.Name -match '(?i)Auto.?Sync' -or $_.DisplayName -match '(?i)Revit.*Auto.?Sync' } |
    Select-Object Name, DisplayName, State, StartMode, PathName | Format-Table -AutoSize -Wrap

Write-Host "`n=== Что записано в манифестах прошлых ремонтов ===" -ForegroundColor Cyan
$roots = @()
foreach ($instance in @(Get-RevitAcceleratorInstances)) {
    $roots += , (Join-Path $instance.Root 'SynxBackup')
    try { $roots += , (Join-Path (Get-SynxWorkspaceRoot -InstanceRoot $instance.Root) 'Repairs') } catch {}
}
foreach ($root in ($roots | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'manifest-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) {
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $pools = (@(Get-SynxValue $manifest 'Pools' @()) | ForEach-Object { [string]$_.Name }) -join ', '
            $services = (@(Get-SynxValue $manifest 'Services' @()) | ForEach-Object { [string]$_.Name }) -join ', '
            [pscustomobject]@{
                When = Get-SynxValue $manifest 'Created' ''
                Result = Get-SynxValue $manifest 'Result' ''
                Guid = Get-SynxValue $manifest 'Guid' ''
                Pools = $pools
                Services = $services
                Error = Get-SynxValue $manifest 'Error' ''
            }
        } catch {}
    }
} | Format-Table -AutoSize -Wrap
