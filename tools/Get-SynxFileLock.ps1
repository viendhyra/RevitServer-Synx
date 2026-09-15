[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [switch]$Release,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\FileLocks.psm1') -Force

# Запускать от администратора: без этого Restart Manager не увидит
# процессы, работающие под другими учётными записями (w3wp, службы).

$targets = if (Test-Path -LiteralPath $Path -PathType Container) {
    @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 120 | ForEach-Object { $_.FullName })
} else { @($Path) }

Write-Host "`nПроверяется объектов: $($targets.Count)" -ForegroundColor Cyan
$holders = @(Get-SynxFileLockOwner -Path $targets -IncludeSmb)

if ($holders.Count -eq 0) {
    Write-Host 'Держателей не найдено — файлы свободны.' -ForegroundColor Green
    Write-Host 'Если удаление всё равно не проходит, файл держит драйвер-фильтр (антивирус, агент резервного копирования): Restart Manager их не показывает.' -ForegroundColor DarkYellow
    return
}

Write-Host "`n=== Кто держит ===" -ForegroundColor Yellow
$holders | Select-Object ProcessId, ProcessName, Kind, ServiceName, AppPool, UserName,
    @{ n = 'Начат'; e = { if ($_.StartTime) { ([datetime]$_.StartTime).ToString('dd.MM.yyyy HH:mm:ss') } else { '' } } },
    IsCritical, IsSecuritySoftware, CanForceStop | Format-Table -AutoSize -Wrap

Write-Host "=== Чем освобождать ===" -ForegroundColor Yellow
Get-SynxLockReleasePlan -Holders $holders | Select-Object Order, Safe, Action, Command | Format-Table -AutoSize -Wrap

if ($Release) {
    Write-Host "`n=== Освобождение ===" -ForegroundColor Yellow
    $result = Unlock-SynxFile -Path $targets -StopServices -StopAppPools -CloseSmbSessions -Force:$Force -Confirm:$false
    $result.Steps | Format-Table -AutoSize -Wrap
    Write-Host $result.Message -ForegroundColor $(if ($result.Released) { 'Green' } else { 'Red' })
}
