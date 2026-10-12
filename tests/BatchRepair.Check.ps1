$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../RevitServer-Synx.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors.Message -join "`n")}
$batch=$ast.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-eq'Start-SynxJob' -and $n.Extent.Text.Contains("-Title 'Пакетный ремонт.")},$true)
$elements=$batch.CommandElements
for($k=0;$k-lt$elements.Count;$k++){if($elements[$k].Extent.Text-eq'-Work'){$work=$elements[$k+1].ScriptBlock.GetScriptBlock();break}}
$script:progressLog=[Collections.ArrayList]::new()
$progress={param($Percent,$Text) [void]$script:progressLog.Add([pscustomobject]@{Percent=$Percent;Text=$Text})}
$script:repaired=[Collections.ArrayList]::new()
# Вложенные функции имеют свои счётчики и параметры; прогресс пакета должен их игнорировать.
function Invoke-AcceleratorModelRepair {param($Model,$ProgressCallback,$Confirm)
    $i=40;$total=0;$number=99;$label='wrong';$Progress=$null
    [void]$script:repaired.Add($Model.Guid)
    & $ProgressCallback 50 'Step'
    if($Model.Guid-eq'fail'){throw 'Test repair failure'}
    & $ProgressCallback 100 'Done'
}
$models=@([pscustomobject]@{Guid='first';Name='First'},[pscustomobject]@{Guid='second';Name='Second'})
$result=& $work $models $progress
if($result-ne2-or$script:progressLog[0].Percent-ne25-or$script:progressLog[2].Percent-ne75-or$script:progressLog[3].Percent-ne100){throw 'Batch progress must retain its own counters.'}
if($script:progressLog[2].Text-notlike '[[]2/2] Second*'){throw 'Batch progress must retain the model label.'}
$script:repaired.Clear();$failed=$false
try{& $work @([pscustomobject]@{Guid='fail';Name='Broken'},$models[1]) $progress}catch{
    $failed=$true
    if($_.Exception.Message-notlike '*Broken*Test repair failure*'){throw 'Batch error must identify the failed model and reason.'}
}
if(-not$failed-or$script:repaired.Count-ne1){throw 'Batch must stop after a failed repair.'}
$confirm=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq'Confirm-Action'},$true)
Invoke-Expression $confirm.Extent.Text
Add-Type -TypeDefinition @'
namespace Windows {
    public enum MessageBoxButton { YesNo }
    public enum MessageBoxImage { Warning }
    public enum MessageBoxResult { Yes }
    public static class MessageBox {
        public static MessageBoxResult Show(object window, string message, string title, MessageBoxButton button, MessageBoxImage image) {
            if (((System.Collections.Hashtable)window)["Enabled"].Equals(true)) throw new System.Exception("Timer active during confirmation");
            return MessageBoxResult.Yes;
        }
    }
}
'@
$script:liveTimer=@{Enabled=$true}
$script:liveTimer | Add-Member ScriptMethod Stop {$this.Enabled=$false}
$script:liveTimer | Add-Member ScriptMethod Start {$this.Enabled=$true}
$window=$script:liveTimer;$script:analysis=[pscustomobject]@{}
if(-not(Confirm-Action 'test' 'test')-or-not$script:liveTimer.Enabled){throw 'Confirmation must pause monitoring and resume it afterward.'}
'Batch repair checks passed.'
