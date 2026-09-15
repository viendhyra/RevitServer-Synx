Set-StrictMode -Version 2.0

# =====================================================================
#  RevitServer Synx — кто держит файл и как его безопасно освободить
#
#  Используется Restart Manager (rstrtmgr.dll) — тот же механизм, что
#  показывает Windows в диалоге «файл открыт в другой программе».
#  Сторонние утилиты (handle.exe, Process Explorer) не требуются.
#
#  Принцип: закрывать чужие дескрипторы через DuplicateHandle
#  (как «Close Handle» в Process Explorer) здесь НЕ делается и делаться
#  не должно — владелец продолжит писать в уже закрытый дескриптор и
#  повредит данные. Освобождение идёт только штатной остановкой
#  владельца.
# =====================================================================

$script:SynxCriticalProcesses = @('System', 'Idle', 'Registry', 'Memory Compression', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsm', 'svchost', 'MsMpEng')
$script:SynxSecurityHints = @('antivir', 'avast', 'avp', 'bitdefender', 'crowdstrike', 'cylance', 'defender', 'drweb', 'eset', 'kaspersky', 'mcafee', 'msmpeng', 'sentinel', 'sophos', 'symantec', 'trendmicro', 'windefend')

function Initialize-SynxRestartManager {
    if ('RevitServerSynx.RestartManager' -as [type]) { return }
    Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace RevitServerSynx {
  [StructLayout(LayoutKind.Sequential)]
  public struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct RM_PROCESS_INFO {
    public RM_UNIQUE_PROCESS Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
    public int ApplicationType;
    public uint AppStatus;
    public uint TSSessionId;
    [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
  }

  public class LockHolder {
    public int ProcessId;
    public string AppName;
    public string ServiceShortName;
    public int ApplicationType;
    public bool Restartable;
    public uint SessionId;
  }

  public static class RestartManager {
    const int ERROR_MORE_DATA = 234;
    const int MOVEFILE_DELAY_UNTIL_REBOOT = 4;

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
      uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
      [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);

    public static List<LockHolder> WhoIsLocking(string[] paths) {
      var result = new List<LockHolder>();
      if (paths == null || paths.Length == 0) return result;
      uint handle;
      var key = new StringBuilder(Guid.NewGuid().ToString("N"));
      int rc = RmStartSession(out handle, 0, key);
      if (rc != 0) throw new InvalidOperationException("RmStartSession failed: " + rc);
      try {
        rc = RmRegisterResources(handle, (uint)paths.Length, paths, 0, null, 0, null);
        if (rc != 0) throw new InvalidOperationException("RmRegisterResources failed: " + rc);
        uint pnProcInfo = 0, pnProcInfoNeeded = 0, reasons = 0;
        rc = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref reasons);
        if (rc == ERROR_MORE_DATA) {
          var info = new RM_PROCESS_INFO[pnProcInfoNeeded];
          pnProcInfo = pnProcInfoNeeded;
          rc = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, info, ref reasons);
          if (rc != 0) throw new InvalidOperationException("RmGetList failed: " + rc);
          for (int i = 0; i < pnProcInfo; i++) {
            result.Add(new LockHolder {
              ProcessId = info[i].Process.dwProcessId,
              AppName = info[i].strAppName,
              ServiceShortName = info[i].strServiceShortName,
              ApplicationType = info[i].ApplicationType,
              Restartable = info[i].bRestartable,
              SessionId = info[i].TSSessionId
            });
          }
        } else if (rc != 0) {
          throw new InvalidOperationException("RmGetList failed: " + rc);
        }
      } finally { RmEndSession(handle); }
      return result;
    }

    public static void DeleteOnReboot(string path) {
      if (!MoveFileEx(path, null, MOVEFILE_DELAY_UNTIL_REBOOT))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
  }
}
'@
}

function Get-SynxProcessDetail {
    param([Parameter(Mandatory)][int]$ProcessId)
    $detail = [ordered]@{
        ProcessId = $ProcessId; ProcessName = ''; ExecutablePath = ''; CommandLine = ''
        Company = ''; Description = ''; StartTime = $null; UserName = ''
    }
    try {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop | Select-Object -First 1
        if ($wmi) {
            $detail.ProcessName = [string]$wmi.Name
            $detail.ExecutablePath = [string]$wmi.ExecutablePath
            $detail.CommandLine = [string]$wmi.CommandLine
            if ($wmi.CreationDate) { $detail.StartTime = [datetime]$wmi.CreationDate }
            try {
                $owner = Invoke-CimMethod -InputObject $wmi -MethodName GetOwner -ErrorAction Stop
                if ($owner.User) { $detail.UserName = "$($owner.Domain)\$($owner.User)" }
            } catch {}
        }
    } catch {}
    if ($detail.ExecutablePath -and (Test-Path -LiteralPath $detail.ExecutablePath -PathType Leaf)) {
        try {
            $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($detail.ExecutablePath)
            $detail.Company = [string]$version.CompanyName
            $detail.Description = [string]$version.FileDescription
        } catch {}
    }
    [pscustomobject]$detail
}

function Get-SynxPoolNameFromCommandLine {
    param([AllowEmptyString()][string]$CommandLine)
    $text = [string]$CommandLine
    $match = [regex]::Match($text, '(?i)(^|\s)-ap\s+"(?<n>[^"]+)"')
    if ($match.Success) { return $match.Groups['n'].Value }
    $match = [regex]::Match($text, "(?i)(^|\s)-ap\s+'(?<n>[^']+)'")
    if ($match.Success) { return $match.Groups['n'].Value }
    ''
}

function Get-SynxFileLockOwner {
    <#
      .SYNOPSIS
        Показывает, какие процессы держат указанные файлы.
      .NOTES
        Пустой результат означает «Restart Manager владельца не видит».
        Это не всегда «файл свободен»: файл может держать драйвер-фильтр
        (антивирус, резервное копирование) или SMB-сессия — их ловит
        ключ -IncludeSmb и признак System/pid 4.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [switch]$IncludeSmb,
        [ValidateRange(1, 256)][int]$BatchSize = 48
    )
    Initialize-SynxRestartManager
    $existing = @(@($Path) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
    if ($existing.Count -eq 0) { return @() }

    $holders = @{}
    for ($offset = 0; $offset -lt $existing.Count; $offset += $BatchSize) {
        $batch = @($existing[$offset..([Math]::Min($offset + $BatchSize - 1, $existing.Count - 1))])
        $raw = @()
        try { $raw = @([RevitServerSynx.RestartManager]::WhoIsLocking([string[]]$batch)) }
        catch { Write-Verbose "Restart Manager: $($_.Exception.Message)"; continue }
        foreach ($item in $raw) {
            $key = [string]$item.ProcessId
            if ($holders.ContainsKey($key)) { $holders[$key].Files += , $batch; continue }
            $detail = Get-SynxProcessDetail -ProcessId ([int]$item.ProcessId)
            $name = if ($detail.ProcessName) { [IO.Path]::GetFileNameWithoutExtension($detail.ProcessName) } else { [string]$item.AppName }
            $isCritical = ([int]$item.ApplicationType -eq 1000) -or ([int]$item.ProcessId -le 4) -or
                          (@($script:SynxCriticalProcesses) -contains $name)
            $probe = (("$name $($detail.Company) $($detail.Description) $($item.ServiceShortName)")).ToLowerInvariant()
            $isSecurity = $false
            foreach ($hint in $script:SynxSecurityHints) { if ($probe.Contains($hint)) { $isSecurity = $true; break } }
            $pool = Get-SynxPoolNameFromCommandLine $detail.CommandLine
            $kind = if ([int]$item.ProcessId -le 4) { 'System' }
                    elseif ($pool) { 'IisWorker' }
                    elseif ($item.ServiceShortName) { 'Service' }
                    elseif ([int]$item.ApplicationType -eq 4) { 'Explorer' }
                    elseif ([int]$item.ApplicationType -in @(1, 2)) { 'UserApplication' }
                    else { 'Process' }

            $holders[$key] = [pscustomobject]@{
                ProcessId = [int]$item.ProcessId
                ProcessName = $name
                AppName = [string]$item.AppName
                Kind = $kind
                ServiceName = [string]$item.ServiceShortName
                AppPool = $pool
                ExecutablePath = $detail.ExecutablePath
                CommandLine = $detail.CommandLine
                Company = $detail.Company
                Description = $detail.Description
                UserName = $detail.UserName
                StartTime = $detail.StartTime
                SessionId = [int]$item.SessionId
                Restartable = [bool]$item.Restartable
                IsCritical = [bool]$isCritical
                IsSecuritySoftware = [bool]$isSecurity
                # Принудительно снимать можно только некритичный процесс,
                # и никогда — svchost (в нём живут чужие службы) и антивирус.
                CanForceStop = [bool]((-not $isCritical) -and (-not $isSecurity) -and ($name -ne 'svchost'))
                Files = @($batch)
                Source = 'RestartManager'
            }
        }
    }

    $result = @(@($holders.Values) | Sort-Object ProcessId)

    if ($IncludeSmb) {
        try {
            foreach ($open in @(Get-SmbOpenFile -ErrorAction Stop)) {
                $openPath = [string]$open.Path
                if (-not $openPath) { continue }
                foreach ($file in $existing) {
                    if ($openPath.StartsWith($file, [StringComparison]::OrdinalIgnoreCase) -or
                        $file.StartsWith($openPath, [StringComparison]::OrdinalIgnoreCase)) {
                        $result += , ([pscustomobject]@{
                            ProcessId = 4; ProcessName = 'System'; AppName = 'SMB'; Kind = 'SmbSession'
                            ServiceName = 'LanmanServer'; AppPool = ''; ExecutablePath = ''; CommandLine = ''
                            Company = 'Microsoft'; Description = "SMB: $($open.ClientUserName) c $($open.ClientComputerName)"
                            UserName = [string]$open.ClientUserName; StartTime = $null; SessionId = 0
                            Restartable = $false; IsCritical = $true; IsSecuritySoftware = $false; CanForceStop = $false
                            Files = @($openPath); Source = 'SMB'; SmbFileId = $open.FileId
                        })
                        break
                    }
                }
            }
        } catch {}
    }
    @($result)
}

function Get-SynxLockReleasePlan {
    <#
      Превращает список держателей в конкретные шаги. Ничего не выполняет.
    #>
    param([Parameter(Mandatory)][object[]]$Holders)
    $plan = @()
    foreach ($holder in @($Holders)) {
        switch ($holder.Kind) {
            'IisWorker' {
                $plan += , [pscustomobject]@{ Holder = $holder; Order = 1; Safe = $true
                    Action = "Остановить IIS-пул $($holder.AppPool)"
                    Command = "Stop-WebAppPool -Name '$($holder.AppPool)'" }
            }
            'Service' {
                $plan += , [pscustomobject]@{ Holder = $holder; Order = 1; Safe = $true
                    Action = "Остановить службу $($holder.ServiceName)"
                    Command = "Stop-Service -Name '$($holder.ServiceName)' -Force" }
            }
            'SmbSession' {
                $plan += , [pscustomobject]@{ Holder = $holder; Order = 2; Safe = $true
                    Action = "Закрыть SMB-сессию клиента $($holder.UserName)"
                    Command = "Close-SmbOpenFile -FileId $($holder.SmbFileId) -Force" }
            }
            'System' {
                $plan += , [pscustomobject]@{ Holder = $holder; Order = 9; Safe = $false
                    Action = 'Файл держит ядро или драйвер-фильтр (антивирус, резервное копирование). Процесс не снимается.'
                    Command = 'Добавить каталог Cache в исключения фильтра и повторить проверку.' }
            }
            default {
                if ($holder.IsSecuritySoftware) {
                    $plan += , [pscustomobject]@{ Holder = $holder; Order = 9; Safe = $false
                        Action = "Файл сканирует защитное ПО ($($holder.ProcessName)). Снимать процесс нельзя."
                        Command = 'Добавить исключение на каталог Cache и процессы AutoSync/w3wp, затем повторить проверку.' }
                } elseif ($holder.IsCritical) {
                    $plan += , [pscustomobject]@{ Holder = $holder; Order = 9; Safe = $false
                        Action = "Системный процесс $($holder.ProcessName) (PID $($holder.ProcessId)) — снимать нельзя."
                        Command = 'Разбирать вручную.' }
                } else {
                    $plan += , [pscustomobject]@{ Holder = $holder; Order = 5; Safe = $false
                        Action = "Закрыть приложение $($holder.ProcessName) (PID $($holder.ProcessId), пользователь $($holder.UserName))"
                        Command = "Stop-Process -Id $($holder.ProcessId) -Force   # только после согласования с владельцем сессии" }
                }
            }
        }
    }
    @($plan | Sort-Object Order)
}

function Unlock-SynxFile {
    <#
      Ступенчатое освобождение. По умолчанию выполняются только
      безопасные шаги: остановка службы, остановка IIS-пула, закрытие
      SMB-сессии. Принудительное снятие процесса — только с -Force и
      только для того, что помечено CanForceStop.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [switch]$StopServices,
        [switch]$StopAppPools,
        [switch]$CloseSmbSessions,
        [switch]$Force,
        [ValidateRange(1, 300)][int]$WaitSeconds = 20
    )
    $steps = @()
    $holders = @(Get-SynxFileLockOwner -Path $Path -IncludeSmb)
    if ($holders.Count -eq 0) {
        return [pscustomobject]@{ Released = $true; Holders = @(); Steps = @(); Remaining = @()
            Message = 'Restart Manager не видит держателей файла.' }
    }

    foreach ($entry in @(Get-SynxLockReleasePlan -Holders $holders)) {
        $holder = $entry.Holder
        $done = $false; $note = 'Пропущено'
        switch ($holder.Kind) {
            'Service' {
                if ($StopServices -and $PSCmdlet.ShouldProcess($holder.ServiceName, 'Остановить службу')) {
                    try { Stop-Service -Name $holder.ServiceName -Force -ErrorAction Stop; $done = $true; $note = 'Служба остановлена' }
                    catch { $note = "Не удалось остановить службу: $($_.Exception.Message)" }
                } else { $note = 'Нужен ключ -StopServices' }
            }
            'IisWorker' {
                if ($StopAppPools -and $holder.AppPool -and $PSCmdlet.ShouldProcess($holder.AppPool, 'Остановить IIS-пул')) {
                    try {
                        Import-Module WebAdministration -ErrorAction Stop
                        Stop-WebAppPool -Name $holder.AppPool -ErrorAction Stop
                        $done = $true; $note = 'IIS-пул остановлен'
                    } catch { $note = "Не удалось остановить пул: $($_.Exception.Message)" }
                } else { $note = 'Нужен ключ -StopAppPools' }
            }
            'SmbSession' {
                if ($CloseSmbSessions -and $PSCmdlet.ShouldProcess([string]$holder.SmbFileId, 'Закрыть SMB-сессию')) {
                    try { Close-SmbOpenFile -FileId $holder.SmbFileId -Force -ErrorAction Stop; $done = $true; $note = 'SMB-сессия закрыта' }
                    catch { $note = "Не удалось закрыть SMB-сессию: $($_.Exception.Message)" }
                } else { $note = 'Нужен ключ -CloseSmbSessions' }
            }
            default {
                if ($Force -and $holder.CanForceStop -and $PSCmdlet.ShouldProcess("$($holder.ProcessName) (PID $($holder.ProcessId))", 'Принудительно завершить процесс')) {
                    try { Stop-Process -Id $holder.ProcessId -Force -ErrorAction Stop; $done = $true; $note = 'Процесс завершён принудительно' }
                    catch { $note = "Не удалось завершить процесс: $($_.Exception.Message)" }
                } elseif (-not $holder.CanForceStop) {
                    $note = 'Завершение запрещено: системный процесс или защитное ПО'
                } else { $note = 'Нужен ключ -Force' }
            }
        }
        $steps += , [pscustomobject]@{ Action = $entry.Action; Applied = $done; Note = $note; ProcessId = $holder.ProcessId }
    }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $remaining = @($holders)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $remaining = @(Get-SynxFileLockOwner -Path $Path -IncludeSmb)
        if ($remaining.Count -eq 0) { break }
    }

    [pscustomobject]@{
        Released = [bool]($remaining.Count -eq 0)
        Holders = @($holders); Steps = @($steps); Remaining = @($remaining)
        Message = if ($remaining.Count -eq 0) { 'Файл освобождён.' }
                  else { "Файл всё ещё держат: " + ((@($remaining) | ForEach-Object { "$($_.ProcessName) (PID $($_.ProcessId))" }) -join ', ') }
    }
}

function Remove-SynxLockedItem {
    <#
      Удаление с честной эскалацией:
        1) обычное удаление;
        2) перенос в сторону (снимает блокировку каталога, если держат
           файл внутри и открывали с FILE_SHARE_DELETE);
        3) пометка на удаление при следующей перезагрузке.
      Пункт 3 требует перезагрузки сервера — сам по себе ничего не чинит.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$AsideDirectory,
        [switch]$OnRebootFallback
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Result = 'Missing'; Path = $Path; Message = 'Объект не найден.' }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Удалить')) {
        return [pscustomobject]@{ Result = 'Skipped'; Path = $Path; Message = 'Отменено' }
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return [pscustomobject]@{ Result = 'Deleted'; Path = $Path; Message = 'Удалено штатно.' }
    } catch { $firstError = $_.Exception.Message }

    if ($AsideDirectory) {
        try {
            if (-not (Test-Path -LiteralPath $AsideDirectory)) { New-Item -ItemType Directory -Path $AsideDirectory -Force | Out-Null }
            $target = Join-Path $AsideDirectory ((Split-Path -Leaf $Path) + '_' + (Get-Date -Format yyyyMMdd_HHmmss))
            [IO.Directory]::Move($Path, $target)
            return [pscustomobject]@{ Result = 'MovedAside'; Path = $target
                Message = "Удалить не удалось ($firstError), объект перенесён в $target." }
        } catch { $firstError += "; перенос: $($_.Exception.Message)" }
    }

    if ($OnRebootFallback) {
        Initialize-SynxRestartManager
        $marked = 0; $errors = @()
        $targets = @()
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $targets += @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            $targets += @(Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { $_.FullName })
        }
        $targets += , $Path
        foreach ($item in $targets) {
            try { [RevitServerSynx.RestartManager]::DeleteOnReboot($item); $marked++ }
            catch { $errors += , "$item : $($_.Exception.Message)" }
        }
        return [pscustomobject]@{ Result = 'ScheduledOnReboot'; Path = $Path
            Message = "Удалить сейчас не удалось ($firstError). Помечено к удалению при перезагрузке: $marked объектов." 
            Errors = @($errors) }
    }

    [pscustomobject]@{ Result = 'Locked'; Path = $Path; Message = "Удалить не удалось: $firstError" }
}

function Get-SynxCacheLockReport {
    <#
      Практическая точка входа для Synx: берёт самые свежие файлы кэша
      GUID и все .db3, выясняет держателей и классифицирует их.
    #>
    param(
        [Parameter(Mandatory)][string]$CachePath,
        [ValidateRange(1, 1000)][int]$SampleSize = 120,
        [string]$ExpectedAppPool = '',
        [string[]]$ExpectedServices = @()
    )
    if (-not (Test-Path -LiteralPath $CachePath -PathType Container)) { throw "Каталог кэша не найден: $CachePath" }
    $files = @(Get-ChildItem -LiteralPath $CachePath -Recurse -File -Force -ErrorAction SilentlyContinue)
    $sample = @(@(@($files | Sort-Object LastWriteTime -Descending | Select-Object -First $SampleSize) +
                  @($files | Where-Object { $_.Extension -eq '.db3' })) |
                Sort-Object FullName -Unique | ForEach-Object { $_.FullName })
    $holders = @(Get-SynxFileLockOwner -Path $sample -IncludeSmb)

    $expected = @(); $unexpected = @()
    foreach ($holder in $holders) {
        $isExpected = $false
        if ($ExpectedAppPool -and [string]::Equals($holder.AppPool, $ExpectedAppPool, [StringComparison]::OrdinalIgnoreCase)) { $isExpected = $true }
        foreach ($service in @($ExpectedServices)) {
            if ($service -and [string]::Equals($holder.ServiceName, $service, [StringComparison]::OrdinalIgnoreCase)) { $isExpected = $true }
        }
        if ($isExpected) { $expected += , $holder } else { $unexpected += , $holder }
    }

    $verdict = if ($holders.Count -eq 0) { 'Держателей нет — файлы свободны, дело не в блокировке.' }
               elseif ($unexpected.Count -eq 0) { 'Кэш держат только компоненты Revit Server — это нормальная работа, а не причина зависания.' }
               else { 'Кэш держат посторонние процессы: ' + ((@($unexpected) | ForEach-Object { "$($_.ProcessName) (PID $($_.ProcessId))" }) -join ', ') }

    [pscustomobject]@{
        CachePath = $CachePath; FilesChecked = $sample.Count; TotalFiles = $files.Count
        Holders = @($holders); Expected = @($expected); Unexpected = @($unexpected)
        SecuritySoftware = @(@($holders) | Where-Object { $_.IsSecuritySoftware })
        Plan = @(Get-SynxLockReleasePlan -Holders $holders)
        Verdict = $verdict
    }
}

Export-ModuleMember -Function `
    Initialize-SynxRestartManager, Get-SynxProcessDetail, Get-SynxPoolNameFromCommandLine, `
    Get-SynxFileLockOwner, Get-SynxLockReleasePlan, Unlock-SynxFile, Remove-SynxLockedItem, Get-SynxCacheLockReport
