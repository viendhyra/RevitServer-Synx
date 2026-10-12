$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/Accelerator.psm1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('SynxLogCheck_'+[guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $root 'Logs') -Force | Out-Null
try{
    & $module {function script:Test-SynxAdministrator {$true}}
    $log=Join-Path $root 'Logs/AutoSyncLog.log';$other=Join-Path $root 'Logs/Other.log'
    [IO.File]::WriteAllText($log,'old events');[IO.File]::WriteAllText($other,'keep')
    $instance=[pscustomobject]@{Root=$root}
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
    'AutoSyncLog clear checks passed.'
}finally{
    # Only the unique directory created by this check is removed.
    Remove-Item -LiteralPath $root -Recurse -Force
}
