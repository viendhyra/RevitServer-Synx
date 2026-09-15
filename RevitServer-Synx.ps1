[CmdletBinding()]
param([string]$OutputRoot='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Import-Module (Join-Path $PSScriptRoot 'src\Accelerator.psm1') -Force
if(-not$OutputRoot){$OutputRoot=Join-Path $env:ProgramData 'RevitServer-Synx'}
try{New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}catch{$OutputRoot=Join-Path $env:TEMP 'RevitServer-Synx';New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
$xamlPath=Join-Path $PSScriptRoot 'ui\MainWindow.xaml';[xml]$xaml=[IO.File]::ReadAllText($xamlPath,[Text.Encoding]::UTF8);$reader=New-Object Xml.XmlNodeReader $xaml;$window=[Windows.Markup.XamlReader]::Load($reader)
$names=@('AdminStatusText','InstanceCombo','RefreshButton','SummaryText','OpenLogButton','ModelsGrid','ErrorsGrid','SelectedText','RepairButton','OpenCacheButton','StatusText');$c=@{}
foreach($name in $names){$control=$window.FindName($name);if($null-eq$control){throw "Элемент интерфейса не найден: $name"};$c[$name]=$control}
$isAdmin=Test-SynxAdministrator;$c.AdminStatusText.Text=if($isAdmin){'Администратор — ремонт доступен'}else{'Просмотр — для ремонта нужны права администратора'};$script:instances=@();$script:analysis=$null
function Show-Error([string]$Message){[void][Windows.MessageBox]::Show($window,$Message,'RevitServer Synx',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)}
function Load-Instances{try{$script:instances=@(Get-RevitAcceleratorInstances);$c.InstanceCombo.ItemsSource=$script:instances;if($script:instances.Count){$c.InstanceCombo.SelectedIndex=0;$c.SummaryText.Text="Найдено экземпляров: $($script:instances.Count). Нажмите «Прочитать логи и базы»."}else{$c.SummaryText.Text='Revit Server Accelerator в ProgramData не найден.'}}catch{Show-Error $_.Exception.Message}}
function Refresh-Analysis{
  $instance=$c.InstanceCombo.SelectedItem;if($null-eq$instance){return}
  try{$c.StatusText.Text='Чтение AutoSyncLog и SQLite-баз...';$window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background);$script:analysis=Get-AcceleratorInventory $instance;$c.ModelsGrid.ItemsSource=@($script:analysis.Models);$c.ErrorsGrid.ItemsSource=@($script:analysis.Events|Where-Object{$_.Level-in@('FAIL','WARN')}|Sort-Object Time -Descending);$stuck=@($script:analysis.Models|Where-Object Status -eq 'ЗАВИСАНИЕ').Count;$bad=@($script:analysis.Models|Where-Object Status -eq 'ОШИБКА').Count;$c.SummaryText.Text="Моделей: $(@($script:analysis.Models).Count); зависших: $stuck; с ошибками: $bad; Host DB: $($script:analysis.DatabaseIntegrity); Status DB: $($script:analysis.StatusDatabaseIntegrity); CacheStatus: $($script:analysis.CacheStatus)";$c.StatusText.Text='Проверка завершена. Выберите модель для просмотра или ремонта.'}catch{$c.StatusText.Text='Ошибка проверки';Show-Error $_.Exception.Message}
}
$c.InstanceCombo.Add_SelectionChanged({$script:analysis=$null;$c.ModelsGrid.ItemsSource=$null;$c.ErrorsGrid.ItemsSource=$null;$c.RepairButton.IsEnabled=$false;$c.OpenCacheButton.IsEnabled=$false})
$c.RefreshButton.Add_Click({Refresh-Analysis})
$c.ModelsGrid.Add_SelectionChanged({$m=$c.ModelsGrid.SelectedItem;if($null-eq$m){$c.SelectedText.Text='Выберите строку слева';$c.RepairButton.IsEnabled=$false;$c.OpenCacheButton.IsEnabled=$false;return};$c.SelectedText.Text="GUID: $($m.Guid)`nHost: $($m.HostNode)`nСостояние: $($m.Status)`nЗависаний: $($m.HangCount)`nКаталог: $($m.CachePath)";$c.RepairButton.IsEnabled=[bool]$isAdmin;$c.OpenCacheButton.IsEnabled=[bool](Test-Path -LiteralPath $m.CachePath)})
$c.OpenLogButton.Add_Click({$instance=$c.InstanceCombo.SelectedItem;if($null-ne$instance-and@($instance.LogPaths).Count){Start-Process notepad.exe -ArgumentList ('"'+$instance.LogPaths[0]+'"')}})
$c.OpenCacheButton.Add_Click({$m=$c.ModelsGrid.SelectedItem;if($null-ne$m-and(Test-Path -LiteralPath $m.CachePath)){Start-Process explorer.exe -ArgumentList ('"'+$m.CachePath+'"')}})
$c.RepairButton.Add_Click({
  $m=$c.ModelsGrid.SelectedItem;if($null-eq$m){return}
  try{$preview=New-AcceleratorRepairPreview $m;$serviceText=if(@($preview.Services).Count){$preview.Services-join"`n"}else{'Не найдены'};$poolText=if(@($preview.Pools).Count){$preview.Pools-join"`n"}else{'Не найдены'};$message="Выбран GUID:`n$($preview.Guid)`n`nHost:`n$($preview.HostNode)`n`nСлужбы:`n$serviceText`n`nIIS-пулы:`n$poolText`n`nПосле остановки компонентов будет создан и проверен бэкап файлов базы. Кэш копироваться не будет — каталог GUID только переместится в карантин. Затем удалится только эта локальная запись GUID. Центральная модель не изменяется.`n`nПродолжить?";if([Windows.MessageBox]::Show($window,$message,'Подтверждение ремонта',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)-ne[Windows.MessageBoxResult]::Yes){return};$c.StatusText.Text='Выполняется ремонт. Не закрывайте окно...';$result=Invoke-AcceleratorModelRepair $m $OutputRoot -Confirm:$false;$c.StatusText.Text="$($result.Message) Отчёт: $($result.ActionRoot)";Refresh-Analysis}catch{$c.StatusText.Text='Ремонт завершился с ошибкой; выполнена попытка автоматического отката.';Show-Error $_.Exception.Message}
})
Load-Instances
[void]$window.ShowDialog()
