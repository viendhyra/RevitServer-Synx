Set-StrictMode -Version 2.0

function Initialize-SynxSqlite {
    if ('RevitServerSynx.NativeSqlite' -as [type]) { return }
    Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace RevitServerSynx {
  public static class NativeSqlite {
    const int OK=0, ROW=100, DONE=101, READONLY=1, READWRITE=2;
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_open_v2(IntPtr p,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db,IntPtr sql,int n,out IntPtr stmt,IntPtr tail);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_name(IntPtr stmt,int i);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt,int i);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_exec(IntPtr db,IntPtr sql,IntPtr cb,IntPtr arg,out IntPtr error);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern void sqlite3_free(IntPtr p);
    static IntPtr Utf8(string s){byte[] b=Encoding.UTF8.GetBytes(s+"\0");IntPtr p=Marshal.AllocHGlobal(b.Length);Marshal.Copy(b,0,p,b.Length);return p;}
    static string Text(IntPtr p){return p==IntPtr.Zero?null:Marshal.PtrToStringAnsi(p);}
    static IntPtr Open(string path,int flags){IntPtr db,p=Utf8(path);try{int c=sqlite3_open_v2(p,out db,flags,IntPtr.Zero);if(c!=OK){string m=db==IntPtr.Zero?"open failed":Text(sqlite3_errmsg(db));if(db!=IntPtr.Zero)sqlite3_close(db);throw new InvalidOperationException("SQLite open ("+c+"): "+m);}return db;}finally{Marshal.FreeHGlobal(p);}}
    public static List<Dictionary<string,string>> Query(string path,string sql){IntPtr db=Open(path,READONLY),stmt=IntPtr.Zero,p=Utf8(sql);try{int c=sqlite3_prepare_v2(db,p,-1,out stmt,IntPtr.Zero);if(c!=OK)throw new InvalidOperationException("SQLite prepare ("+c+"): "+Text(sqlite3_errmsg(db)));var rows=new List<Dictionary<string,string>>();int n=sqlite3_column_count(stmt);while((c=sqlite3_step(stmt))==ROW){var row=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);for(int i=0;i<n;i++)row[Text(sqlite3_column_name(stmt,i))]=Text(sqlite3_column_text(stmt,i));rows.Add(row);}if(c!=DONE)throw new InvalidOperationException("SQLite query ("+c+"): "+Text(sqlite3_errmsg(db)));return rows;}finally{if(stmt!=IntPtr.Zero)sqlite3_finalize(stmt);Marshal.FreeHGlobal(p);sqlite3_close(db);}}
    public static void Execute(string path,string sql){IntPtr db=Open(path,READWRITE),error=IntPtr.Zero,p=Utf8(sql);try{int c=sqlite3_exec(db,p,IntPtr.Zero,IntPtr.Zero,out error);if(c!=OK)throw new InvalidOperationException("SQLite write ("+c+"): "+(error==IntPtr.Zero?Text(sqlite3_errmsg(db)):Text(error)));}finally{if(error!=IntPtr.Zero)sqlite3_free(error);Marshal.FreeHGlobal(p);sqlite3_close(db);}}
  }
}
'@
}

function Invoke-SynxSqliteQuery {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Sql)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "SQLite database not found: $Path" }
    Initialize-SynxSqlite
    foreach ($row in [RevitServerSynx.NativeSqlite]::Query($Path,$Sql)) {
        $value=[ordered]@{};foreach($key in $row.Keys){$value[$key]=$row[$key]};[pscustomobject]$value
    }
}

function Invoke-SynxSqliteExecute {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Sql)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "SQLite database not found: $Path" }
    Initialize-SynxSqlite;[RevitServerSynx.NativeSqlite]::Execute($Path,$Sql)
}

function Get-SynxSqliteIntegrity {
    param([Parameter(Mandatory)][string]$Path)
    try{$row=@(Invoke-SynxSqliteQuery $Path 'PRAGMA integrity_check;')|Select-Object -First 1;if($null -eq $row){'no result'}else{[string](@($row.PSObject.Properties)[0].Value)}}catch{"ERROR: $($_.Exception.Message)"}
}

function ConvertFrom-AutoSyncLogLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $time=$null
    if($Line -match '^(?<t>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}[,.]\d{3})'){try{$time=[datetime]::ParseExact(($matches.t-replace ',','.'),'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)}catch{}}
    $guid='';$gm=[regex]::Match($Line,'(?i)(?<g>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})');if($gm.Success){$guid=$gm.Groups['g'].Value.ToLowerInvariant()}
    $type='Info';$level='INFO';$message=$Line;$host='';$loop=0;$threads=0
    if($Line -match '(?i)Loop\s+(?<l>\d+)\s*:\s*(?<n>\d+)\s+threads?\s+are\s+still\s+not\s+done\s+for\s+Model'){$type='StuckThread';$level='FAIL';$loop=[int]$matches.l;$threads=[int]$matches.n;$message='Поток AutoSync не завершил обработку кэша модели.'}
    elseif($Line -match '(?i)Failed to get IP addresses for\s+(?<h>[^ ]+)\s*: No such host'){$type='HostResolution';$level='WARN';$host=$matches.h.TrimEnd(':');$message='Не удалось разрешить адрес HostNode.'}
    elseif($Line -match '(?i)\b(ERROR|Exception|Failed|FileNotFoundException|EndpointNotFoundException|locked by another process)\b'){$type='Error';$level='FAIL'}
    elseif($Line -match '(?i)Data is up-to-date with central'){$type='UpToDate';$level='OK';$message='Кэш соответствует центральной модели.'}
    [pscustomobject]@{Time=$time;Level=$level;Type=$type;Guid=$guid;HostNode=$host;Loop=$loop;Threads=$threads;Message=$message;Raw=$Line}
}

function Get-AutoSyncLogAnalysis {
    param([string[]]$Paths,[ValidateRange(100,200000)][int]$Tail=30000)
    $events=New-Object Collections.ArrayList
    foreach($path in @($Paths|Where-Object{$_ -and (Test-Path -LiteralPath $_ -PathType Leaf)}|Sort-Object -Unique)){
        try{foreach($line in @(Get-Content -LiteralPath $path -Tail $Tail -ErrorAction Stop)){$event=ConvertFrom-AutoSyncLogLine ([string]$line);if($event.Type-ne'Info'){$event|Add-Member -NotePropertyName LogPath -NotePropertyValue $path;[void]$events.Add($event)}}}catch{[void]$events.Add([pscustomobject]@{Time=Get-Date;Level='FAIL';Type='LogRead';Guid='';HostNode='';Loop=0;Threads=0;Message=$_.Exception.Message;Raw='';LogPath=$path})}
    };@($events)
}

function Find-AutoSyncLogs {
    param([Parameter(Mandatory)][string]$Root)
    $result=New-Object Collections.ArrayList
    foreach($candidate in @((Join-Path $Root 'Logs\AutoSyncLog.log'),(Join-Path $Root 'AutoSyncLog.log'),(Join-Path $Root 'AutoSync\AutoSyncLog.log'),(Join-Path $Root 'AutoSync\Logs\AutoSyncLog.log'))){if(Test-Path -LiteralPath $candidate -PathType Leaf){[void]$result.Add($candidate)}}
    foreach($dir in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue|Where-Object Name -ne 'Cache')){foreach($file in @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter 'AutoSyncLog*.log' -Recurse -ErrorAction SilentlyContinue)){if($result-notcontains$file.FullName){[void]$result.Add($file.FullName)}}};@($result)
}

function Get-RevitAcceleratorInstances {
    param([string]$ProgramDataPath=$env:ProgramData)
    if(-not$ProgramDataPath){return @()};$autodesk=Join-Path $ProgramDataPath 'Autodesk';if(-not(Test-Path -LiteralPath $autodesk)){return @()}
    foreach($dir in @(Get-ChildItem -LiteralPath $autodesk -Directory -Filter 'Revit Server 20??' -ErrorAction SilentlyContinue|Sort-Object Name)){
        $year=([regex]::Match($dir.Name,'20\d{2}')).Value;$cache=Join-Path $dir.FullName 'Cache';$hostDb=Join-Path $cache 'HostNodeForCachedModels.db3';$statusDb=Join-Path $cache 'LocalServer_Cache.db3';$logs=@(Find-AutoSyncLogs $dir.FullName)
        if((Test-Path -LiteralPath $cache)-or(Test-Path -LiteralPath $hostDb)-or$logs.Count-gt 0){[pscustomobject]@{Name=$dir.Name;Year=$year;Root=$dir.FullName;CachePath=$cache;HostDatabase=$hostDb;StatusDatabase=$statusDb;LogPaths=$logs}}
    }
}

function Get-SynxModelEventState {
    param([object[]]$Events)
    $current=New-Object Collections.ArrayList
    foreach($event in @($Events)){
        if($event.Type-eq'UpToDate'){$current.Clear();continue}
        [void]$current.Add($event)
    }
    [pscustomobject]@{
        Hangs=@($current|Where-Object Type -eq StuckThread)
        Errors=@($current|Where-Object Type -eq Error)
        Last=@($Events|Where-Object Time|Sort-Object Time|Select-Object -Last 1)
    }
}

function Get-AcceleratorInventory {
    param([Parameter(Mandatory)]$Instance,[ValidateRange(100,200000)][int]$LogTail=30000)
    $events=@(Get-AutoSyncLogAnalysis @($Instance.LogPaths) $LogTail);$byGuid=@{}
    foreach($event in @($events|Where-Object Guid)){if(-not$byGuid.ContainsKey($event.Guid)){$byGuid[$event.Guid]=New-Object Collections.ArrayList};[void]$byGuid[$event.Guid].Add($event)}
    $rows=@();$dbIntegrity='missing'
    if(Test-Path -LiteralPath $Instance.HostDatabase -PathType Leaf){$dbIntegrity=Get-SynxSqliteIntegrity $Instance.HostDatabase;if($dbIntegrity-eq'ok'){$rows=@(Invoke-SynxSqliteQuery $Instance.HostDatabase 'SELECT lower(ModelIdentityGUID) AS Guid, HostNode FROM HostNodeForCachedModels ORDER BY ModelIdentityGUID;')}}
    $statusIntegrity='missing';$cacheStatus=''
    if(Test-Path -LiteralPath $Instance.StatusDatabase -PathType Leaf){$statusIntegrity=Get-SynxSqliteIntegrity $Instance.StatusDatabase;if($statusIntegrity-eq'ok'){$s=@(Invoke-SynxSqliteQuery $Instance.StatusDatabase 'SELECT CacheStatus FROM CacheStatus LIMIT 1;')|Select-Object -First 1;if($null-ne$s){$cacheStatus=[string]$s.CacheStatus}}}
    $known=@{};$items=New-Object Collections.ArrayList
    foreach($row in $rows){
        $guid=[string]$row.Guid;$known[$guid]=$true;$me=if($byGuid.ContainsKey($guid)){@($byGuid[$guid])}else{@()};$eventState=Get-SynxModelEventState $me;$hangs=@($eventState.Hangs);$errors=@($eventState.Errors);$last=@($eventState.Last);$lastTime=if($last.Count){$last[0].Time}else{$null};$folder=Join-Path $Instance.CachePath $guid
        $status=if($hangs.Count-ge3){'ЗАВИСАНИЕ'}elseif($errors.Count){'ОШИБКА'}elseif(-not(Test-Path -LiteralPath $folder -PathType Container)){'НЕТ КЭША'}else{'OK'}
        [void]$items.Add([pscustomobject]@{Guid=$guid;HostNode=[string]$row.HostNode;Year=$Instance.Year;Status=$status;HangCount=$hangs.Count;ErrorCount=$errors.Count;LastEvent=$lastTime;CacheExists=[bool](Test-Path -LiteralPath $folder -PathType Container);CachePath=$folder;InstanceRoot=$Instance.Root;HostDatabase=$Instance.HostDatabase;StatusDatabase=$Instance.StatusDatabase})
    }
    if(Test-Path -LiteralPath $Instance.CachePath){foreach($dir in @(Get-ChildItem -LiteralPath $Instance.CachePath -Directory -ErrorAction SilentlyContinue|Where-Object Name -match '^[0-9a-fA-F-]{36}$')){$guid=$dir.Name.ToLowerInvariant();if($known.ContainsKey($guid)){continue};$me=if($byGuid.ContainsKey($guid)){@($byGuid[$guid])}else{@()};$eventState=Get-SynxModelEventState $me;$hangs=@($eventState.Hangs);$errors=@($eventState.Errors);$last=@($eventState.Last);$status=if($hangs.Count-ge3){'ЗАВИСАНИЕ'}elseif($errors.Count){'ОШИБКА'}else{'БЕЗ ЗАПИСИ БД'};[void]$items.Add([pscustomobject]@{Guid=$guid;HostNode='';Year=$Instance.Year;Status=$status;HangCount=$hangs.Count;ErrorCount=$errors.Count;LastEvent=if($last.Count){$last[0].Time}else{$null};CacheExists=$true;CachePath=$dir.FullName;InstanceRoot=$Instance.Root;HostDatabase=$Instance.HostDatabase;StatusDatabase=$Instance.StatusDatabase})}}
    [pscustomobject]@{Instance=$Instance;Models=@($items|Sort-Object @{Expression={if($_.Status-eq'ЗАВИСАНИЕ'){0}elseif($_.Status-eq'ОШИБКА'){1}else{2}}},Guid);Events=$events;DatabaseIntegrity=$dbIntegrity;StatusDatabaseIntegrity=$statusIntegrity;CacheStatus=$cacheStatus}
}

function Test-SynxAdministrator {
    try{$id=[Security.Principal.WindowsIdentity]::GetCurrent();$p=New-Object Security.Principal.WindowsPrincipal($id);[bool]$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}catch{$false}
}

function Get-AcceleratorRepairTargets {
    param([Parameter(Mandatory)]$Model)
    $year=[string]$Model.Year;$services=@()
    try{$all=@(Get-CimInstance Win32_Service|Where-Object{$_.Name-match'(?i)Auto.?Sync'-or$_.DisplayName-match'(?i)Revit.*Auto.?Sync'-or$_.PathName-match'(?i)Auto.?Sync'});$services=@($all|Where-Object{([string]$_.PathName-match[regex]::Escape([string]$Model.InstanceRoot))-or([string]$_.Name-match$year)-or([string]$_.DisplayName-match$year)})}catch{}
    $pools=@();try{Import-Module WebAdministration -ErrorAction Stop;$pools=@(Get-ChildItem IIS:\AppPools|Where-Object{$_.Name-match"(?i)RevitServerAppPool.*$year|ModelService.*$year"}|ForEach-Object{[pscustomobject]@{Name=$_.Name;State=[string](Get-WebAppPoolState $_.Name).Value}})}catch{}
    [pscustomobject]@{Services=@($services);Pools=@($pools)}
}

function New-AcceleratorRepairPreview {
    param([Parameter(Mandatory)]$Model)
    $targets=Get-AcceleratorRepairTargets $Model
    [pscustomobject]@{Guid=$Model.Guid;HostNode=$Model.HostNode;Services=@($targets.Services|ForEach-Object{"$($_.DisplayName) [$($_.State)]"});Pools=@($targets.Pools|ForEach-Object{"$($_.Name) [$($_.State)]"})}
}

function Wait-SynxServiceState([string]$Name,[string]$Status){for($i=0;$i-lt45;$i++){if([string](Get-Service $Name).Status-eq$Status){return};Start-Sleep 1};throw "Служба $Name не перешла в состояние $Status."}
function Set-SynxRuntimeState {
    param($Targets,[ValidateSet('Stop','Start')]$Action)
    if($Targets.Pools.Count){Import-Module WebAdministration -ErrorAction Stop}
    if($Action-eq'Stop'){
        foreach($s in @($Targets.Services)){if([string]$s.State-eq'Running'){Stop-Service $s.Name -Force -ErrorAction Stop;Wait-SynxServiceState $s.Name 'Stopped'}}
        foreach($p in @($Targets.Pools)){if($p.State-eq'Started'){Stop-WebAppPool $p.Name;for($i=0;$i-lt45;$i++){if((Get-WebAppPoolState $p.Name).Value-eq'Stopped'){break};Start-Sleep 1};if((Get-WebAppPoolState $p.Name).Value-ne'Stopped'){throw "IIS-пул $($p.Name) не остановился."}}}
    }else{
        foreach($p in @($Targets.Pools)){if($p.State-eq'Started'-and(Get-WebAppPoolState $p.Name).Value-ne'Started'){Start-WebAppPool $p.Name;for($i=0;$i-lt45;$i++){if((Get-WebAppPoolState $p.Name).Value-eq'Started'){break};Start-Sleep 1};if((Get-WebAppPoolState $p.Name).Value-ne'Started'){throw "IIS-пул $($p.Name) не запустился."}}}
        foreach($s in @($Targets.Services)){if([string]$s.State-eq'Running'-and(Get-Service $s.Name).Status-ne'Running'){Start-Service $s.Name;Wait-SynxServiceState $s.Name 'Running'}}
    }
}

function Invoke-AcceleratorModelRepair {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)]$Model,[Parameter(Mandatory)][string]$OutputRoot)
    if(-not(Test-SynxAdministrator)){throw 'Запустите Windows PowerShell от имени администратора.'};$guid=[string]$Model.Guid
    if($guid-notmatch'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw 'Недопустимый GUID.'}
    $expected=Join-Path ([string]$Model.InstanceRoot) ('Cache\'+$guid);if([IO.Path]::GetFullPath([string]$Model.CachePath).TrimEnd('\')-ne[IO.Path]::GetFullPath($expected).TrimEnd('\')){throw 'Путь кэша не соответствует экземпляру Revit Server.'}
    if(-not$PSCmdlet.ShouldProcess($guid,'Точечный ремонт кэша Accelerator')){return [pscustomobject]@{Status='Skipped';Guid=$guid;Message='Отменено'}}
    $stamp=Get-Date -Format yyyy-MM-dd_HHmmss;$root=Join-Path $OutputRoot "Repair_${guid}_$stamp";$backup=Join-Path $root DatabaseBackup;$qroot=Join-Path ([string]$Model.InstanceRoot) SynxQuarantine;$quarantine=Join-Path $qroot "${guid}_$stamp";New-Item -ItemType Directory -Path $backup,$qroot -Force|Out-Null
    $targets=Get-AcceleratorRepairTargets $Model
    if($targets.Services.Count-eq0){throw "Служба Revit Server AutoSync $($Model.Year) не найдена. Ремонт остановлен до изменения файлов."}
    if($targets.Pools.Count-eq0){throw "IIS-пул Revit Server $($Model.Year) не найден. Ремонт остановлен до изменения файлов."}
    $moved=$false;$changed=$false
    $manifest=[ordered]@{Created=Get-Date;Guid=$guid;HostNode=$Model.HostNode;InstanceRoot=$Model.InstanceRoot;CachePath=$Model.CachePath;Quarantine=$quarantine;Services=@($targets.Services|Select-Object Name,DisplayName,State);Pools=@($targets.Pools);Result='Started'}
    try{
        $manifest|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root manifest-before.json) -Encoding UTF8
        Set-SynxRuntimeState $targets Stop
        foreach($db in @($Model.HostDatabase,$Model.StatusDatabase)){
            if($db-and(Test-Path -LiteralPath $db)){
                $destination=Join-Path $backup ([IO.Path]::GetFileName($db))
                Copy-Item -LiteralPath $db -Destination $destination -Force
                if((Get-Item -LiteralPath $db).Length-ne(Get-Item -LiteralPath $destination).Length){throw "Размер резервной копии не совпадает: $db"}
                if((Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash-ne(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash){throw "Контрольная сумма резервной копии не совпадает: $db"}
                foreach($suffix in @('-journal','-wal','-shm')){
                    if(Test-Path -LiteralPath ($db+$suffix)){Copy-Item -LiteralPath ($db+$suffix) -Destination (Join-Path $backup ([IO.Path]::GetFileName($db+$suffix))) -Force}
                }
            }
        }
        if(Test-Path -LiteralPath $Model.CachePath -PathType Container){Move-Item $Model.CachePath $quarantine -Force;$moved=$true}
        if(Test-Path -LiteralPath $Model.HostDatabase){Invoke-SynxSqliteExecute $Model.HostDatabase "BEGIN IMMEDIATE; DELETE FROM HostNodeForCachedModels WHERE lower(ModelIdentityGUID)=lower('$guid'); COMMIT;";$changed=$true;$integrity=Get-SynxSqliteIntegrity $Model.HostDatabase;if($integrity-ne'ok'){throw "Проверка базы: $integrity"};if(@(Invoke-SynxSqliteQuery $Model.HostDatabase "SELECT ModelIdentityGUID FROM HostNodeForCachedModels WHERE lower(ModelIdentityGUID)=lower('$guid');").Count){throw 'GUID остался в базе.'}}
        Set-SynxRuntimeState $targets Start;$manifest.Result='Changed';$manifest.Completed=Get-Date;$manifest|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root manifest-after.json) -Encoding UTF8
        $dbBackupPath=Join-Path $backup ([IO.Path]::GetFileName([string]$Model.HostDatabase))
        @(
            "`$ErrorActionPreference='Stop'",
            "# Перед откатом остановите AutoSync и IIS-пул Revit Server $($Model.Year).",
            "Copy-Item -LiteralPath '$($dbBackupPath.Replace("'","''"))' -Destination '$(([string]$Model.HostDatabase).Replace("'","''"))' -Force",
            "if(Test-Path -LiteralPath '$($quarantine.Replace("'","''"))'){Move-Item -LiteralPath '$($quarantine.Replace("'","''"))' -Destination '$(([string]$Model.CachePath).Replace("'","''"))' -Force}"
        )|Set-Content (Join-Path $root Rollback.ps1) -Encoding UTF8
        [pscustomobject]@{Status='Changed';Guid=$guid;Message='Кэш перенесён в карантин, запись удалена, база проверена, компоненты запущены.';ActionRoot=$root;Quarantine=$quarantine}
    }catch{
        $errorText=$_.Exception.Message
        try{
            Set-SynxRuntimeState $targets Stop
            if($changed){$copy=Join-Path $backup ([IO.Path]::GetFileName([string]$Model.HostDatabase));if(Test-Path $copy){Copy-Item -LiteralPath $copy -Destination $Model.HostDatabase -Force}}
            if($moved-and(Test-Path $quarantine)-and-not(Test-Path $Model.CachePath)){Move-Item -LiteralPath $quarantine -Destination $Model.CachePath -Force}
            Set-SynxRuntimeState $targets Start
        }catch{$errorText+="; откат: $($_.Exception.Message)"}
        $manifest.Result='Failed';$manifest.Error=$errorText;$manifest|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root manifest-error.json) -Encoding UTF8;throw $errorText
    }
}

Export-ModuleMember -Function Initialize-SynxSqlite,Invoke-SynxSqliteQuery,Invoke-SynxSqliteExecute,Get-SynxSqliteIntegrity,ConvertFrom-AutoSyncLogLine,Get-AutoSyncLogAnalysis,Find-AutoSyncLogs,Get-RevitAcceleratorInstances,Get-SynxModelEventState,Get-AcceleratorInventory,Test-SynxAdministrator,Get-AcceleratorRepairTargets,New-AcceleratorRepairPreview,Invoke-AcceleratorModelRepair
