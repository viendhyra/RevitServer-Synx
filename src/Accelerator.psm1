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
    static string Text(IntPtr p){if(p==IntPtr.Zero)return null;int n=0;while(Marshal.ReadByte(p,n)!=0)n++;byte[] b=new byte[n];Marshal.Copy(p,b,0,n);return Encoding.UTF8.GetString(b);}
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
    $seen=@{}
    foreach($path in @($Paths)){
        if((-not $path) -or (-not (Test-Path -LiteralPath $path -PathType Leaf)) -or $seen.ContainsKey([string]$path)){continue}
        $seen[[string]$path]=$true
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
        $locationDatabases=@((Join-Path $dir.FullName 'Projects\ModelLocationTable.db3'),(Join-Path $dir.FullName 'ModelLocationTable.db3'))|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Sort-Object -Unique
        if((Test-Path -LiteralPath $cache)-or(Test-Path -LiteralPath $hostDb)-or$logs.Count-gt 0){[pscustomobject]@{Name=$dir.Name;Year=$year;Root=$dir.FullName;CachePath=$cache;HostDatabase=$hostDb;StatusDatabase=$statusDb;LocationDatabases=@($locationDatabases);LogPaths=$logs}}
    }
}

function ConvertFrom-SynxGuidHex {
    param([Parameter(Mandatory)][string]$Hex)
    if($Hex-notmatch'^[0-9a-fA-F]{32}$'){return ''}
    $bytes=New-Object byte[] 16
    for($i=0;$i-lt16;$i++){$bytes[$i]=[Convert]::ToByte($Hex.Substring($i*2,2),16)}
    ([Guid]::new($bytes)).ToString().ToLowerInvariant()
}

function Get-SynxModelLocationMap {
    param([string[]]$Paths)
    $result=@{};$seen=@{}
    foreach($path in @($Paths)){
        if((-not $path) -or (-not (Test-Path -LiteralPath $path -PathType Leaf)) -or $seen.ContainsKey([string]$path)){continue}
        $seen[[string]$path]=$true
        try{
            $sql='SELECT typeof(ModelIdentityGUID) AS GuidType, hex(ModelIdentityGUID) AS GuidHex, CAST(ModelIdentityGUID AS TEXT) AS GuidText, ModelPath, ModelNormalizedPath FROM ModelStorageTable;'
            foreach($row in @(Invoke-SynxSqliteQuery $path $sql)){
                $guid=if($row.GuidType-eq'blob'){ConvertFrom-SynxGuidHex ([string]$row.GuidHex)}elseif(([string]$row.GuidText)-match'^[0-9a-fA-F-]{36}$'){([string]$row.GuidText).ToLowerInvariant()}else{''}
                if(-not$guid){continue};$modelPath=if($row.ModelPath){[string]$row.ModelPath}else{[string]$row.ModelNormalizedPath}
                $result[$guid]=[pscustomobject]@{Name=[IO.Path]::GetFileName($modelPath);ModelPath=$modelPath;Source=$path}
            }
        }catch{}
    }
    $result
}

function Get-SynxModelEventState {
    param([object[]]$Events)
    $current=New-Object Collections.ArrayList;$dated=New-Object Collections.ArrayList
    foreach($event in @($Events)){
        if($null-eq$event){continue}
        if($event.Time){[void]$dated.Add($event)}
        if($event.Type-eq'UpToDate'){$current.Clear();continue}
        [void]$current.Add($event)
    }
    $hangs=@();$errors=@()
    foreach($event in @($current)){if($event.Type-eq'StuckThread'){$hangs+=,$event}elseif($event.Type-eq'Error'){$errors+=,$event}}
    $last=if($dated.Count){@($dated|Sort-Object Time|Select-Object -Last 1)}else{@()}
    [pscustomobject]@{
        Hangs=@($hangs)
        Errors=@($errors)
        Last=@($last)
    }
}

function Get-AcceleratorInventory {
    param([Parameter(Mandatory)]$Instance,[ValidateRange(100,200000)][int]$LogTail=30000)
    $events=@(Get-AutoSyncLogAnalysis -Paths @($Instance.LogPaths) -Tail $LogTail);$byGuid=@{};$locations=Get-SynxModelLocationMap -Paths @($Instance.LocationDatabases)
    foreach($event in @($events)){if(($null-eq$event) -or (-not $event.Guid)){continue};if(-not$byGuid.ContainsKey($event.Guid)){$byGuid[$event.Guid]=New-Object Collections.ArrayList};[void]$byGuid[$event.Guid].Add($event)}
    $rows=@();$dbIntegrity='missing'
    if(Test-Path -LiteralPath $Instance.HostDatabase -PathType Leaf){$dbIntegrity=Get-SynxSqliteIntegrity $Instance.HostDatabase;if($dbIntegrity-eq'ok'){$rows=@(Invoke-SynxSqliteQuery $Instance.HostDatabase 'SELECT lower(ModelIdentityGUID) AS Guid, HostNode FROM HostNodeForCachedModels ORDER BY ModelIdentityGUID;')}}
    $statusIntegrity='missing';$cacheStatus=''
    if(Test-Path -LiteralPath $Instance.StatusDatabase -PathType Leaf){$statusIntegrity=Get-SynxSqliteIntegrity $Instance.StatusDatabase;if($statusIntegrity-eq'ok'){$s=@(Invoke-SynxSqliteQuery $Instance.StatusDatabase 'SELECT CacheStatus FROM CacheStatus LIMIT 1;')|Select-Object -First 1;if($null-ne$s){$cacheStatus=[string]$s.CacheStatus}}}
    $known=@{};$items=New-Object Collections.ArrayList
    foreach($row in $rows){
        $guid=[string]$row.Guid;$known[$guid]=$true;$me=if($byGuid.ContainsKey($guid)){@($byGuid[$guid])}else{@()};$eventState=Get-SynxModelEventState $me;$hangs=@($eventState.Hangs);$errors=@($eventState.Errors);$last=@($eventState.Last);$lastTime=if($last.Count){$last[0].Time}else{$null};$folder=Join-Path $Instance.CachePath $guid;$location=if($locations.ContainsKey($guid)){$locations[$guid]}else{$null}
        $status=if($hangs.Count-ge3){'ЗАВИСАНИЕ'}elseif($errors.Count){'ОШИБКА'}elseif(-not(Test-Path -LiteralPath $folder -PathType Container)){'НЕТ КЭША'}else{'OK'}
        [void]$items.Add([pscustomobject]@{Name=if($location){$location.Name}else{'—'};ModelPath=if($location){$location.ModelPath}else{''};Guid=$guid;HostNode=[string]$row.HostNode;Year=$Instance.Year;Status=$status;HangCount=$hangs.Count;ErrorCount=$errors.Count;LastEvent=$lastTime;CacheExists=[bool](Test-Path -LiteralPath $folder -PathType Container);CachePath=$folder;InstanceRoot=$Instance.Root;HostDatabase=$Instance.HostDatabase;StatusDatabase=$Instance.StatusDatabase})
    }
    if(Test-Path -LiteralPath $Instance.CachePath){foreach($dir in @(Get-ChildItem -LiteralPath $Instance.CachePath -Directory -ErrorAction SilentlyContinue|Where-Object Name -match '^[0-9a-fA-F-]{36}$')){$guid=$dir.Name.ToLowerInvariant();if($known.ContainsKey($guid)){continue};$me=if($byGuid.ContainsKey($guid)){@($byGuid[$guid])}else{@()};$eventState=Get-SynxModelEventState $me;$hangs=@($eventState.Hangs);$errors=@($eventState.Errors);$last=@($eventState.Last);$status=if($hangs.Count-ge3){'ЗАВИСАНИЕ'}elseif($errors.Count){'ОШИБКА'}else{'БЕЗ ЗАПИСИ БД'};$location=if($locations.ContainsKey($guid)){$locations[$guid]}else{$null};[void]$items.Add([pscustomobject]@{Name=if($location){$location.Name}else{'—'};ModelPath=if($location){$location.ModelPath}else{''};Guid=$guid;HostNode='';Year=$Instance.Year;Status=$status;HangCount=$hangs.Count;ErrorCount=$errors.Count;LastEvent=if($last.Count){$last[0].Time}else{$null};CacheExists=$true;CachePath=$dir.FullName;InstanceRoot=$Instance.Root;HostDatabase=$Instance.HostDatabase;StatusDatabase=$Instance.StatusDatabase})}}
    [pscustomobject]@{Instance=$Instance;Models=@($items|Sort-Object @{Expression={if($_.Status-eq'ЗАВИСАНИЕ'){0}elseif($_.Status-eq'ОШИБКА'){1}else{2}}},Name,Guid);Events=$events;DatabaseIntegrity=$dbIntegrity;StatusDatabaseIntegrity=$statusIntegrity;CacheStatus=$cacheStatus;ResolvedNames=$locations.Count}
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
    [pscustomobject]@{Name=$Model.Name;ModelPath=$Model.ModelPath;Guid=$Model.Guid;HostNode=$Model.HostNode;Services=@($targets.Services|ForEach-Object{"$($_.DisplayName) [$($_.State)]"});Pools=@($targets.Pools|ForEach-Object{"$($_.Name) [$($_.State)]"})}
}

function Wait-SynxServiceState([string]$Name,[string]$Status){for($i=0;$i-lt45;$i++){if([string](Get-Service $Name).Status-eq$Status){return};Start-Sleep 1};throw "Служба $Name не перешла в состояние $Status."}
function Set-SynxRuntimeState {
    param($Targets,[ValidateSet('Stop','Start')]$Action)
    if($Targets.Pools.Count){Import-Module WebAdministration -ErrorAction Stop}
    if($Action-eq'Stop'){
        foreach($s in @($Targets.Services)){if(([string]$s.State-eq'Running') -and ([string](Get-Service $s.Name).Status-ne'Stopped')){Stop-Service $s.Name -Force -ErrorAction Stop;Wait-SynxServiceState $s.Name 'Stopped'}}
        foreach($p in @($Targets.Pools)){if($p.State-eq'Started'){$current=[string](Get-WebAppPoolState $p.Name).Value;if($current-ne'Stopped'){Stop-WebAppPool $p.Name;for($i=0;$i-lt45;$i++){if((Get-WebAppPoolState $p.Name).Value-eq'Stopped'){break};Start-Sleep 1};if((Get-WebAppPoolState $p.Name).Value-ne'Stopped'){throw "IIS-пул $($p.Name) не остановился."}}}}
    }else{
        foreach($p in @($Targets.Pools)){if((Get-WebAppPoolState $p.Name).Value-ne'Started'){Start-WebAppPool $p.Name;for($i=0;$i-lt45;$i++){if((Get-WebAppPoolState $p.Name).Value-eq'Started'){break};Start-Sleep 1};if((Get-WebAppPoolState $p.Name).Value-ne'Started'){throw "IIS-пул $($p.Name) не запустился."}}}
        foreach($s in @($Targets.Services)){if((Get-Service $s.Name).Status-ne'Running'){Start-Service $s.Name;Wait-SynxServiceState $s.Name 'Running'}}
    }
}

function Set-SynxCacheRepairAccess {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){throw "Каталог кэша не найден: $Path"}
    $takeown=Join-Path $env:SystemRoot 'System32\takeown.exe';$icacls=Join-Path $env:SystemRoot 'System32\icacls.exe'
    & $takeown '/F' $Path '/A' '/R' '/D' 'Y'|Out-Null
    if($LASTEXITCODE-ne0){throw "takeown не смог получить доступ к кэшу (Code $LASTEXITCODE)."}
    & $icacls $Path '/grant' '*S-1-5-32-544:(OI)(CI)F' '/T' '/C' '/Q'|Out-Null
    if($LASTEXITCODE-ne0){throw "icacls не смог выдать права на кэш (Code $LASTEXITCODE)."}
}

function Move-SynxCacheDirectory {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,[scriptblock]$ProgressCallback)
    if(-not(Test-Path -LiteralPath $Source -PathType Container)){return $false}
    if(Test-Path -LiteralPath $Destination){throw "Папка карантина уже существует: $Destination"}
    $parent=Split-Path -Parent $Destination;if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $accessFixed=$false;$lastError=''
    for($attempt=1;$attempt-le8;$attempt++){
        try{[IO.Directory]::Move($Source,$Destination);return $true}catch{
            $lastError=$_.Exception.Message
            if(($attempt-ge3) -and (-not$accessFixed) -and (Test-Path -LiteralPath $Source -PathType Container)){
                if($ProgressCallback){&$ProgressCallback 58 'Восстановление прав на выбранный кэш GUID'}
                Set-SynxCacheRepairAccess $Source;$accessFixed=$true
            }
            if($attempt-lt8){Start-Sleep -Seconds 1}
        }
    }
    throw "Не удалось переместить кэш после 8 попыток: $lastError"
}

function Invoke-AcceleratorModelRepair {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)]$Model,[scriptblock]$ProgressCallback)
    function Publish-RepairProgress([int]$Percent,[string]$Message){if($ProgressCallback){&$ProgressCallback $Percent $Message}}

    Publish-RepairProgress 2 'Проверка выбранной модели'
    if(-not(Test-SynxAdministrator)){throw 'Запустите Windows PowerShell от имени администратора.'}
    $guid=[string]$Model.Guid
    if($guid-notmatch'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw 'Недопустимый GUID.'}
    $expected=Join-Path ([string]$Model.InstanceRoot) ('Cache\'+$guid)
    if([IO.Path]::GetFullPath([string]$Model.CachePath).TrimEnd('\')-ne[IO.Path]::GetFullPath($expected).TrimEnd('\')){throw 'Путь кэша не соответствует экземпляру Revit Server.'}
    if(-not$PSCmdlet.ShouldProcess($guid,'Точечный ремонт кэша Accelerator')){return [pscustomobject]@{Status='Skipped';Guid=$guid;Message='Отменено'}}

    $stamp=Get-Date -Format yyyy-MM-dd_HHmmss
    $synxBackupRoot=Join-Path ([string]$Model.InstanceRoot) 'SynxBackup'
    $root=Join-Path $synxBackupRoot "Repair_${guid}_$stamp"
    $backup=Join-Path $root DatabaseBackup
    $qroot=Join-Path ([string]$Model.InstanceRoot) SynxQuarantine
    $quarantine=Join-Path $qroot "${guid}_$stamp"
    New-Item -ItemType Directory -Path $backup,$qroot -Force|Out-Null

    Publish-RepairProgress 8 'Поиск AutoSync и IIS-пула'
    $targets=Get-AcceleratorRepairTargets $Model
    if($targets.Services.Count-eq0){throw "Служба Revit Server AutoSync $($Model.Year) не найдена. Файлы не изменены."}
    if($targets.Pools.Count-eq0){throw "IIS-пул Revit Server $($Model.Year) не найден. Файлы не изменены."}

    $moved=$false;$changed=$false
    $manifest=[ordered]@{Created=Get-Date;Name=$Model.Name;ModelPath=$Model.ModelPath;Guid=$guid;HostNode=$Model.HostNode;InstanceRoot=$Model.InstanceRoot;CachePath=$Model.CachePath;Quarantine=$quarantine;Services=@($targets.Services|Select-Object Name,DisplayName,State);Pools=@($targets.Pools);Result='Started'}
    try{
        Publish-RepairProgress 12 'Сохранение плана ремонта'
        $manifest|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root manifest-before.json) -Encoding UTF8

        Publish-RepairProgress 20 'Остановка AutoSync и IIS-пула'
        Set-SynxRuntimeState $targets Stop

        Publish-RepairProgress 35 'Создание бэкапа SQLite-баз'
        foreach($db in @($Model.HostDatabase,$Model.StatusDatabase)){
            if($db-and(Test-Path -LiteralPath $db)){
                $destination=Join-Path $backup ([IO.Path]::GetFileName($db))
                Copy-Item -LiteralPath $db -Destination $destination -Force
                if((Get-Item -LiteralPath $db).Length-ne(Get-Item -LiteralPath $destination).Length){throw "Размер резервной копии не совпадает: $db"}
                if((Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash-ne(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash){throw "SHA-256 резервной копии не совпадает: $db"}
                foreach($suffix in @('-journal','-wal','-shm')){if(Test-Path -LiteralPath ($db+$suffix)){Copy-Item -LiteralPath ($db+$suffix) -Destination (Join-Path $backup ([IO.Path]::GetFileName($db+$suffix))) -Force}}
            }
        }
        Publish-RepairProgress 48 'Бэкап баз проверен по SHA-256'

        Publish-RepairProgress 55 'Удаление кэша GUID из активной системы'
        if(Test-Path -LiteralPath $Model.CachePath -PathType Container){$moved=Move-SynxCacheDirectory -Source $Model.CachePath -Destination $quarantine -ProgressCallback $ProgressCallback}

        Publish-RepairProgress 65 'Удаление привязки GUID из локальной базы'
        if(Test-Path -LiteralPath $Model.HostDatabase){Invoke-SynxSqliteExecute $Model.HostDatabase "BEGIN IMMEDIATE; DELETE FROM HostNodeForCachedModels WHERE lower(ModelIdentityGUID)=lower('$guid'); COMMIT;";$changed=$true}

        Publish-RepairProgress 75 'Проверка удаления локальных данных GUID'
        if(Test-Path -LiteralPath $Model.CachePath){throw 'Каталог GUID остался в активном кэше.'}
        if(Test-Path -LiteralPath $Model.HostDatabase){
            $integrity=Get-SynxSqliteIntegrity $Model.HostDatabase
            if($integrity-ne'ok'){throw "Проверка базы: $integrity"}
            if(@(Invoke-SynxSqliteQuery $Model.HostDatabase "SELECT ModelIdentityGUID FROM HostNodeForCachedModels WHERE lower(ModelIdentityGUID)=lower('$guid');").Count){throw 'GUID остался в базе.'}
        }

        Publish-RepairProgress 88 'Запуск IIS-пула и AutoSync'
        Set-SynxRuntimeState $targets Start
        $manifest.Result='Changed';$manifest.Completed=Get-Date;$manifest|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root manifest-after.json) -Encoding UTF8

        $dbBackupPath=Join-Path $backup ([IO.Path]::GetFileName([string]$Model.HostDatabase))
        @(
            "`$ErrorActionPreference='Stop'",
            "# Перед откатом остановите AutoSync и IIS-пул Revit Server $($Model.Year).",
            "Copy-Item -LiteralPath '$($dbBackupPath.Replace("'","''"))' -Destination '$(([string]$Model.HostDatabase).Replace("'","''"))' -Force",
            "if(Test-Path -LiteralPath '$($quarantine.Replace("'","''"))'){[IO.Directory]::Move('$($quarantine.Replace("'","''"))','$(([string]$Model.CachePath).Replace("'","''"))')}"
        )|Set-Content (Join-Path $root Rollback.ps1) -Encoding UTF8

        Publish-RepairProgress 100 'Готово: локальные данные модели очищены'
        [pscustomobject]@{Status='Changed';Name=$Model.Name;Guid=$guid;Message='Активный кэш GUID и локальная привязка удалены; база проверена; компоненты запущены.';ActionRoot=$root;Quarantine=$quarantine}
    }catch{
        $errorText=$_.Exception.Message
        try{
            Publish-RepairProgress 80 'Ошибка: выполняется безопасный откат'
            Set-SynxRuntimeState $targets Stop
            if($changed){$copy=Join-Path $backup ([IO.Path]::GetFileName([string]$Model.HostDatabase));if(Test-Path $copy){Copy-Item -LiteralPath $copy -Destination $Model.HostDatabase -Force}}
            if($moved-and(Test-Path $quarantine)-and-not(Test-Path $Model.CachePath)){[IO.Directory]::Move([string]$quarantine,[string]$Model.CachePath)}
            Set-SynxRuntimeState $targets Start
            Publish-RepairProgress 100 'Откат завершён'
        }catch{$errorText+="; откат: $($_.Exception.Message)"}
        $manifest.Result='Failed';$manifest.Error=$errorText;$manifest|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root manifest-error.json) -Encoding UTF8
        throw $errorText
    }
}

Export-ModuleMember -Function Initialize-SynxSqlite,Invoke-SynxSqliteQuery,Invoke-SynxSqliteExecute,Get-SynxSqliteIntegrity,ConvertFrom-AutoSyncLogLine,Get-AutoSyncLogAnalysis,Find-AutoSyncLogs,Get-RevitAcceleratorInstances,ConvertFrom-SynxGuidHex,Get-SynxModelLocationMap,Get-SynxModelEventState,Get-AcceleratorInventory,Test-SynxAdministrator,Get-AcceleratorRepairTargets,New-AcceleratorRepairPreview,Set-SynxCacheRepairAccess,Move-SynxCacheDirectory,Invoke-AcceleratorModelRepair
