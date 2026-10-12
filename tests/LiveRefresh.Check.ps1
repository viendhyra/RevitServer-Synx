$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../RevitServer-Synx.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors.Message -join "`n")}
$refresh=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq'Refresh-Analysis'},$true)
Invoke-Expression $refresh.Extent.Text
$c=@{InstanceCombo=[pscustomobject]@{SelectedItem=[pscustomobject]@{Year=2024}};StatusText=[pscustomobject]@{Text=''}}
$script:liveTimer=[pscustomobject]@{Stops=0;Starts=0}
$script:liveTimer | Add-Member ScriptMethod Stop {$this.Stops++}
$script:liveTimer | Add-Member ScriptMethod Start {$this.Starts++}
$script:calls=0
function Start-SynxJob {param($Title,$Arguments,$Context,$Work,$OnDone,[switch]$Background)
    $script:calls++;$script:captured=[pscustomobject]@{Context=$Context;Work=$Work;OnDone=$OnDone;Background=[bool]$Background}
}
$script:job=[pscustomobject]@{Critical=$true};Refresh-Analysis -Background
if($script:calls){throw 'Refresh must not overlap another job.'}
$script:job=$null;Refresh-Analysis -Background
if($script:calls-ne1-or-not$script:captured.Background-or$script:liveTimer.Stops-ne1){throw 'Live refresh must stop its timer and launch a background job.'}
& $script:captured.OnDone $null 'Busy database' $script:captured.Context
if($script:liveTimer.Starts-ne1){throw 'Background errors must schedule a retry without a dialog.'}
function Get-AcceleratorInventory {param($Instance,$ProgressCallback) [pscustomobject]@{Events=@([pscustomobject]@{Level='OK';Time=Get-Date;Type='UpToDate'},[pscustomobject]@{Level='FAIL';Time=Get-Date;Type='StuckThread'})}}
function Get-SynxHostAddressSummary {param($Instance) @()}
$result=& $script:captured.Work $c.InstanceCombo.SelectedItem {param($Percent,$Text)}
if(@($result.VisibleEvents).Count-ne2){throw 'Both completed syncs and failures must be visible.'}
[xml]$xaml=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../ui/MainWindow.xaml'))
$start=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq'Start-SynxJob'},$true)
Invoke-Expression $start.Extent.Text
function Update-Buttons {}
$fakePS=[pscustomobject]@{Stopped=$false}
$fakePS | Add-Member ScriptMethod BeginStop {param($Callback,$State) $this.Stopped=$true;[pscustomobject]@{IsCompleted=$false}}
$script:job=[pscustomobject]@{Background=$true;Cancelled=$false;PS=$fakePS;StopHandle=$null}
$script:pendingJob=$null
Start-SynxJob -Title 'Repair' -Critical -Arguments @{Model='selected'} -Work {} -OnDone {}
if(-not$fakePS.Stopped-or-not$script:job.Cancelled-or$script:pendingJob.Title-ne'Repair'-or-not$script:pendingJob.Critical){throw 'Manual actions must cancel background reading asynchronously and retain the requested job.'}
'Live refresh checks passed.'
