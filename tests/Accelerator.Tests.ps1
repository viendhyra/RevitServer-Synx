BeforeAll { Import-Module (Join-Path $PSScriptRoot '../src/Accelerator.psm1') -Force }
Describe 'GitHub bootstrap' {
  It 'can be piped from irm to iex without a BOM prefix' {
    $path=Join-Path $PSScriptRoot '../Run.ps1';$bytes=[IO.File]::ReadAllBytes($path)
    $bytes[0]|Should -Be 0x24
    $text=[Text.Encoding]::UTF8.GetString($bytes);@($text.ToCharArray()|Where-Object{[int]$_-gt127}).Count|Should -Be 0
    $tokens=$null;$errors=$null;[void][System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors);$errors.Count|Should -Be 0
  }
  It 'parses the graphical application script and contains every required control' {
    $scriptPath=Join-Path $PSScriptRoot '../RevitServer-Synx.ps1'
    $text=[IO.File]::ReadAllText($scriptPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    $errors.Count|Should -Be 0

    [xml]$xaml=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../ui/MainWindow.xaml'),[Text.Encoding]::UTF8)
    $xamlText=$xaml.OuterXml
    Add-Type -AssemblyName PresentationFramework
    $reader=New-Object Xml.XmlNodeReader $xaml
    $view=[Windows.Markup.XamlReader]::Load($reader)
    foreach($name in @('ModelsGrid','ErrorsGrid','DiagnosisCard','DiagnosisTitleText','DiagnosisConfidenceText','DiagnosisEvidenceText','DiagnosisActionText','RepairButton','BatchRepairButton','CacheCheckButton','OpenDiagnosticButton','OldHostCombo','NewHostText','TestHostButton','MigrateHostButton','LoadHostNamesButton','OpenHistoryButton','RepairProgress','RepairDetails')){
      $xamlText|Should -Match ('x:Name="'+[regex]::Escape($name)+'"')
      $view.FindName($name)|Should -Not -BeNullOrEmpty
    }
  }
}
Describe 'Persistent incident history' {
  It 'stores failure and repair records beside database backups' {
    $root=Join-Path $TestDrive 'Revit Server 2024';$guid='11111111-2222-4333-8444-555555555555'
    [void](Write-SynxIncidentHistory -InstanceRoot $root -Type FailureDetected -Guid $guid -Name 'Model.rvt' -Status 'ЗАВИСАНИЕ' -HangCount 3 -EventTime (Get-Date) -EpisodeKey 'episode-1')
    [void](Write-SynxIncidentHistory -InstanceRoot $root -Type RepairSuccess -Guid $guid -Name 'Model.rvt' -ActionRoot (Join-Path $root 'SynxBackup\Repair_test'))
    $path=Get-SynxHistoryPath $root
    $path|Should -Be (Join-Path $root 'SynxBackup\SynxIncidentHistory.jsonl')
    Test-Path -LiteralPath $path|Should -BeTrue
    $history=@(Read-SynxIncidentHistory $root);$history.Count|Should -Be 2
    (Get-SynxLatestRepairTime -History $history -Guid $guid)|Should -Not -BeNullOrEmpty
  }
  It 'accepts both IIS state object formats' {
    ConvertTo-SynxAppPoolState ([pscustomobject]@{Value='Started'})|Should -Be 'Started'
    ConvertTo-SynxAppPoolState 'Stopped'|Should -Be 'Stopped'
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
Describe 'Host address migration helpers' {
  It 'splits IPv4, DNS and bracketed IPv6 endpoints without losing the port' {
    $a=Split-SynxHostNode '185.77.240.202:36942';$a.Address|Should -Be '185.77.240.202';$a.Port|Should -Be '36942'
    $b=Split-SynxHostNode 'revit-host.local:36943';$b.Address|Should -Be 'revit-host.local';$b.Port|Should -Be '36943'
    $c=Split-SynxHostNode '[2001:db8::10]:36942';$c.Address|Should -Be '2001:db8::10';$c.Port|Should -Be '36942'
  }
  It 'groups every GUID by the stored Host address and preserves its ports' {
    $root=Join-Path $TestDrive 'Revit Server 2024';$cache=Join-Path $root 'Cache';New-Item -ItemType Directory -Path $cache -Force|Out-Null;$db=Join-Path $cache 'HostNodeForCachedModels.db3';[IO.File]::WriteAllBytes($db,[byte[]]@())
    Invoke-SynxSqliteExecute $db "CREATE TABLE HostNodeForCachedModels (ModelIdentityGUID STRING PRIMARY KEY, HostNode STRING); INSERT INTO HostNodeForCachedModels VALUES ('11111111-2222-4333-8444-555555555555','old-host:36942'); INSERT INTO HostNodeForCachedModels VALUES ('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee','old-host:36943');"
    $instance=[pscustomobject]@{HostDatabase=$db};$groups=@(Get-SynxHostAddressSummary $instance);$groups.Count|Should -Be 1;$groups[0].ModelCount|Should -Be 2;$groups[0].Ports|Should -Be '36942, 36943'
  }
}
Describe 'Cache quarantine move' {
  It 'moves the selected GUID directory atomically with its Data folder' {
    $source=Join-Path $TestDrive 'Cache\11111111-2222-4333-8444-555555555555';$destination=Join-Path $TestDrive 'SynxQuarantine\11111111-2222-4333-8444-555555555555_test'
    New-Item -ItemType Directory -Path (Join-Path $source 'Data') -Force|Out-Null;Set-Content -LiteralPath (Join-Path $source 'Data\sample.bin') -Value 'test'
    Move-SynxCacheDirectory -Source $source -Destination $destination|Should -BeTrue
    Test-Path -LiteralPath $source|Should -BeFalse;Test-Path -LiteralPath (Join-Path $destination 'Data\sample.bin')|Should -BeTrue
  }
}
Describe 'Cache file inspection' {
  It 'writes a report and detects a zero-length file' {
    $cache=Join-Path $TestDrive 'Cache\11111111-2222-4333-8444-555555555555';$reports=Join-Path $TestDrive 'reports';New-Item -ItemType Directory -Path $cache -Force|Out-Null;[IO.File]::WriteAllBytes((Join-Path $cache 'empty.bin'),[byte[]]@())
    $result=Test-SynxCacheFiles -CachePath $cache -ReportDirectory $reports;$result.FileCount|Should -Be 1;$result.IssueCount|Should -Be 1;Test-Path -LiteralPath $result.ReportPath|Should -BeTrue
  }
  It 'captures surrounding AutoSync log lines only for the requested GUID' {
    $guid='11111111-2222-4333-8444-555555555555';$other='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';$log=Join-Path $TestDrive 'AutoSyncLog.log'
    @('before','Model: C:\Cache\'+$guid+'\Data','after','Model: C:\Cache\'+$other+'\Data')|Set-Content -LiteralPath $log -Encoding UTF8
    $context=@(Get-SynxGuidLogContext -Guid $guid -Paths @($log) -Before 1 -After 1);$context.Count|Should -Be 3;($context.Text-join' ')|Should -Match ([regex]::Escape($guid));($context.Text-join' ')|Should -Not -Match ([regex]::Escape($other))
  }
  It 'identifies a physical zero-byte cache file as a high-confidence cause' {
    $guid='22222222-3333-4444-8555-666666666666';$cache=Join-Path $TestDrive "Cache\$guid";$reports=Join-Path $TestDrive 'diagnostics';New-Item -ItemType Directory -Path $cache -Force|Out-Null;[IO.File]::WriteAllBytes((Join-Path $cache 'history.1.dat'),[byte[]]@())
    $model=[pscustomobject]@{Guid=$guid;Name='Broken.rvt';ModelPath='Project\Broken.rvt';HostNode='';Status='ЗАВИСАНИЕ';RepeatFailure=$false;HangCount=4;LastMessage='';CachePath=$cache}
    $result=Test-SynxModelDiagnostics -Model $model -LogPaths @() -ReportDirectory $reports;$result.Reason|Should -Be 'В кэше есть физически пустые файлы';$result.Confidence|Should -Be 'Высокая';Test-Path -LiteralPath $result.ReportPath|Should -BeTrue
  }
  It 'treats StreamLength zero as a low-confidence WCF hypothesis, not proof' {
    $guid='33333333-4444-4555-8666-777777777777';$cache=Join-Path $TestDrive "Cache\$guid";$reports=Join-Path $TestDrive 'wcf-diagnostics';$log=Join-Path $TestDrive 'WcfAutoSync.log';New-Item -ItemType Directory -Path $cache -Force|Out-Null;Set-Content -LiteralPath (Join-Path $cache 'history.1.dat') -Value 'not empty';@("Model: C:\Cache\$guid\Data",'<h:StreamLength>0</h:StreamLength>')|Set-Content -LiteralPath $log -Encoding UTF8
    $model=[pscustomobject]@{Guid=$guid;Name='Wcf.rvt';ModelPath='Project\Wcf.rvt';HostNode='';Status='ЗАВИСАНИЕ';RepeatFailure=$false;HangCount=4;LastMessage='';CachePath=$cache}
    $result=Test-SynxModelDiagnostics -Model $model -LogPaths @($log) -ReportDirectory $reports;$result.Reason|Should -Be 'WCF показывает StreamLength=0';$result.Confidence|Should -Be 'Низкая'
  }
}
Describe 'AutoSync log parser' {
  It 'handles models with no log events' {$state=Get-SynxModelEventState -Events @();$state.Hangs.Count|Should -Be 0;$state.Errors.Count|Should -Be 0;$state.Last.Count|Should -Be 0}
  It 'handles an empty log path list' {@(Get-AutoSyncLogAnalysis -Paths @()).Count|Should -Be 0}
  It 'extracts a stuck cache GUID and loop number' {$line='2026-09-15 00:06:37,750 INFO TID(6) LOGGER(ServerLogger) MSG(Comment: Loop 453 : 1 threads are still not done for Model: C:\ProgramData\Autodesk\Revit Server 2022\Cache\11111111-2222-4333-8444-555555555555\Data)';$event=ConvertFrom-AutoSyncLogLine $line;$event.Type|Should -Be 'StuckThread';$event.Guid|Should -Be '11111111-2222-4333-8444-555555555555';$event.Loop|Should -Be 453}
  It 'classifies host lookup failures' {$event=ConvertFrom-AutoSyncLogLine '2026-09-15 00:26:42,532 INFO MSG(Comment: Failed to get IP addresses for 203.0.113.10:36942: No such host is known)';$event.Type|Should -Be 'HostResolution';$event.Level|Should -Be 'WARN';$event.HostNode|Should -Be '203.0.113.10:36942'}
  It 'recognizes successful synchronization' {(ConvertFrom-AutoSyncLogLine '2026-09-15 00:26:43,208 INFO MSG(Comment: Data is up-to-date with central.)').Level|Should -Be 'OK'}
  It 'clears historical hangs after a later successful synchronization' {$events=@((ConvertFrom-AutoSyncLogLine '2026-09-15 00:01:00,000 INFO MSG(Comment: Loop 1 : 1 threads are still not done for Model: C:\Cache\11111111-2222-4333-8444-555555555555\Data)'),(ConvertFrom-AutoSyncLogLine '2026-09-15 00:02:00,000 INFO MSG(Comment: Data is up-to-date with central.)'));$state=Get-SynxModelEventState $events;$state.Hangs.Count|Should -Be 0}
  It 'ignores failures older than the last successful repair' {$events=@((ConvertFrom-AutoSyncLogLine '2026-09-15 00:01:00,000 INFO MSG(Comment: Loop 1 : 1 threads are still not done for Model: C:\Cache\11111111-2222-4333-8444-555555555555\Data)'),(ConvertFrom-AutoSyncLogLine '2026-09-15 00:03:00,000 INFO MSG(Comment: Loop 2 : 1 threads are still not done for Model: C:\Cache\11111111-2222-4333-8444-555555555555\Data)'));$state=Get-SynxModelEventState $events -After ([datetime]'2026-09-15 00:02:00');$state.Hangs.Count|Should -Be 1;$state.Hangs[0].Loop|Should -Be 2}
}
