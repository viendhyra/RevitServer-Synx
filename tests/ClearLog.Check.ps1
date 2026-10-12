$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/Accelerator.psm1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('SynxLogCheck_'+[guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $root 'Logs') -Force | Out-Null
try{
    & $module {function script:Test-SynxAdministrator {$true}}
    & $module {
        $script:testStatus='Running';$script:testStops=0;$script:testStarts=0;$script:testLock=$null
        function script:Get-AcceleratorRepairTargets {param($Model) [pscustomobject]@{Services=@([pscustomobject]@{Name='TestAutoSync'})}}
        function script:Get-Service {param($Name,$ErrorAction) [pscustomobject]@{Status=$script:testStatus}}
        function script:Stop-Service {param($Name,$ErrorAction) $script:testStops++;$script:testStatus='Stopped';if($script:testLock){$script:testLock.Dispose();$script:testLock=$null}}
        function script:Start-Service {param($Name,$ErrorAction) $script:testStarts++;$script:testStatus='Running'}
        function script:Wait-SynxServiceState {param($Name,$Status) if($script:testStatus-ne$Status){throw 'Wrong service state'}}
    }
    $log=Join-Path $root 'Logs/AutoSyncLog.log';$other=Join-Path $root 'Logs/Other.log'
    [IO.File]::WriteAllText($log,'old events');[IO.File]::WriteAllText($other,'keep')
    $instance=[pscustomobject]@{Root=$root;Year=2024}
    $writer=[IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try{
        $result=Clear-SynxAutoSyncLogs $instance -Confirm:$false
        if($result.ClearedCount-ne1-or(Get-Item $log).Length-ne0){throw 'The existing shared log must be truncated.'}
        $writer.Position=$writer.Length;$bytes=[Text.Encoding]::UTF8.GetBytes('new event');$writer.Write($bytes,0,$bytes.Length);$writer.Flush()
    }finally{$writer.Dispose()}
    if([IO.File]::ReadAllText($log)-ne'new event'-or[IO.File]::ReadAllText($other)-ne'keep'){throw 'New writes and unrelated logs must be preserved.'}
    Clear-SynxAutoSyncLogs $instance -WhatIf | Out-Null
    if([IO.File]::ReadAllText($log)-ne'new event'){throw 'WhatIf must not clear the log.'}
    $lock=[IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        $failed=$false;try{Clear-SynxAutoSyncLogs $instance -Confirm:$false}catch{$failed=$true}
        if(-not$failed){throw 'An exclusive lock must be reported as a failure.'}
    }finally{$lock.Dispose()}
    if((& $module {$script:testStatus})-ne'Running'){throw 'The service must restart even when log clearing fails.'}
    & $module {param($Path) $script:testLock=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)} $log
    $result=Clear-SynxAutoSyncLogs $instance -Confirm:$false
    if($result.ClearedCount-ne1-or(Get-Item $log).Length-ne0-or(& $module {$script:testStatus})-ne'Running'){throw 'Stopping AutoSync must release its exclusive log lock and restart it.'}
    & $module {$script:testStatus='Stopped';$script:testStarts=0}
    Clear-SynxAutoSyncLogs $instance -Confirm:$false | Out-Null
    if((& $module {$script:testStarts})-ne0){throw 'An initially stopped service must stay stopped.'}
    'AutoSyncLog clear checks passed.'
}finally{
    # Only the unique directory created by this check is removed.
    Remove-Item -LiteralPath $root -Recurse -Force
}
