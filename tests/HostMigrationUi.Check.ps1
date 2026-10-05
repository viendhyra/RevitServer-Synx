$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../RevitServer-Synx.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors.Message -join "`n")}
$update=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-Buttons'},$true)
Invoke-Expression $update.Extent.Text
$c=@{}
foreach($name in @('RefreshButton','InstanceCombo','LoadNamesButton','LoadHostNamesButton','TestHostButton','OldHostCombo','NewHostText','ModelsGrid','RepairButton','CacheCheckButton','OpenCacheButton','BatchRepairButton','MigrateHostButton','ClearCacheButton','OpenHistoryButton','OpenDiagnosticButton')){
    $c[$name]=[pscustomobject]@{IsEnabled=$false;SelectedItem=$null;Text=''}
}
$script:job=$null;$script:analysis=$null;$script:lastDiagnosticPath='';$isAdmin=$true
$c.InstanceCombo.SelectedItem=[pscustomobject]@{Year=2024}
$c.OldHostCombo.SelectedItem=[pscustomobject]@{Address='old.example'}
$c.NewHostText.Text='new.example'
foreach($result in @($null,[pscustomobject]@{Resolved=$false;AllPortsOpen=$false},[pscustomobject]@{Resolved=$true;AllPortsOpen=$false})){
    $script:hostTest=$result;Update-Buttons
    if(-not$c.MigrateHostButton.IsEnabled){throw 'Migration must be available without a successful endpoint check.'}
}
$c.NewHostText.Text=' ';Update-Buttons
if($c.MigrateHostButton.IsEnabled){throw 'An empty new address must disable migration.'}
$c.NewHostText.Text='new.example';$c.OldHostCombo.SelectedItem=$null;Update-Buttons
if($c.MigrateHostButton.IsEnabled){throw 'Migration requires a selected old Host.'}
$c.OldHostCombo.SelectedItem=[pscustomobject]@{Address='old.example'};$isAdmin=$false;Update-Buttons
if($c.MigrateHostButton.IsEnabled){throw 'Migration requires administrator privileges.'}
$isAdmin=$true;$script:job=[pscustomobject]@{};Update-Buttons
if($c.MigrateHostButton.IsEnabled){throw 'Migration must be disabled while a job is running.'}
'Host migration UI checks passed.'
