BeforeAll { Import-Module (Join-Path $PSScriptRoot '../src/Accelerator.psm1') -Force }
Describe 'GitHub bootstrap' {
  It 'can be piped from irm to iex without a BOM prefix' {
    $path=Join-Path $PSScriptRoot '../Run.ps1';$bytes=[IO.File]::ReadAllBytes($path)
    $bytes[0]|Should -Be 0x24
    $text=[Text.Encoding]::UTF8.GetString($bytes);@($text.ToCharArray()|Where-Object{[int]$_-gt127}).Count|Should -Be 0
    $tokens=$null;$errors=$null;[void][System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors);$errors.Count|Should -Be 0
  }
}
Describe 'Model name mapping' {
  It 'converts a Revit SQLite GUID blob to the standard GUID form' {
    ConvertFrom-SynxGuidHex 'ad1a670f8aae2b458b8d467ebf402643'|Should -Be '0f671aad-ae8a-452b-8b8d-467ebf402643'
  }
  It 'reads the model name and path from ModelLocationTable' {
    $db=Join-Path $TestDrive 'ModelLocationTable.db3';[IO.File]::WriteAllBytes($db,[byte[]]@())
    Invoke-SynxSqliteExecute $db "CREATE TABLE ModelStorageTable (ModelIdentityGUID GUID, ModelNormalizedPath STRING, ModelPath STRING); INSERT INTO ModelStorageTable VALUES (X'ad1a670f8aae2b458b8d467ebf402643','project\model.rvt','Project\Named_Model.rvt');"
    $map=Get-SynxModelLocationMap @($db);$map['0f671aad-ae8a-452b-8b8d-467ebf402643'].Name|Should -Be 'Named_Model.rvt';$map['0f671aad-ae8a-452b-8b8d-467ebf402643'].ModelPath|Should -Be 'Project\Named_Model.rvt'
  }
}
Describe 'AutoSync log parser' {
  It 'handles models with no log events' {$state=Get-SynxModelEventState -Events @();$state.Hangs.Count|Should -Be 0;$state.Errors.Count|Should -Be 0;$state.Last.Count|Should -Be 0}
  It 'handles an empty log path list' {@(Get-AutoSyncLogAnalysis -Paths @()).Count|Should -Be 0}
  It 'extracts a stuck cache GUID and loop number' {$line='2026-09-15 00:06:37,750 INFO TID(6) LOGGER(ServerLogger) MSG(Comment: Loop 453 : 1 threads are still not done for Model: C:\ProgramData\Autodesk\Revit Server 2022\Cache\11111111-2222-4333-8444-555555555555\Data)';$event=ConvertFrom-AutoSyncLogLine $line;$event.Type|Should -Be 'StuckThread';$event.Guid|Should -Be '11111111-2222-4333-8444-555555555555';$event.Loop|Should -Be 453}
  It 'classifies host lookup failures' {$event=ConvertFrom-AutoSyncLogLine '2026-09-15 00:26:42,532 INFO MSG(Comment: Failed to get IP addresses for 203.0.113.10:36942: No such host is known)';$event.Type|Should -Be 'HostResolution';$event.Level|Should -Be 'WARN';$event.HostNode|Should -Be '203.0.113.10:36942'}
  It 'recognizes successful synchronization' {(ConvertFrom-AutoSyncLogLine '2026-09-15 00:26:43,208 INFO MSG(Comment: Data is up-to-date with central.)').Level|Should -Be 'OK'}
  It 'clears historical hangs after a later successful synchronization' {$events=@((ConvertFrom-AutoSyncLogLine '2026-09-15 00:01:00,000 INFO MSG(Comment: Loop 1 : 1 threads are still not done for Model: C:\Cache\11111111-2222-4333-8444-555555555555\Data)'),(ConvertFrom-AutoSyncLogLine '2026-09-15 00:02:00,000 INFO MSG(Comment: Data is up-to-date with central.)'));$state=Get-SynxModelEventState $events;$state.Hangs.Count|Should -Be 0}
}
