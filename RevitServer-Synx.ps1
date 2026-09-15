[CmdletBinding()]
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Import-Module (Join-Path $PSScriptRoot 'src\Accelerator.psm1') -Force
$xamlPath=Join-Path $PSScriptRoot 'ui\MainWindow.xaml';[xml]$xaml=[IO.File]::ReadAllText($xamlPath,[Text.Encoding]::UTF8);$reader=New-Object Xml.XmlNodeReader $xaml;$window=[Windows.Markup.XamlReader]::Load($reader)
$names=@('AdminStatusText','InstanceCombo','RefreshButton','SummaryText','LoadNamesButton','OpenLogButton','ModelsGrid','ErrorsGrid','SelectedText','RepairButton','OpenCacheButton','RepairStepText','RepairProgress','RepairDetails','StatusText');$c=@{}
foreach($name in $names){$control=$window.FindName($name);if($null-eq$control){throw "Элемент интерфейса не найден: $name"};$c[$name]=$control}
$isAdmin=Test-SynxAdministrator;$c.AdminStatusText.Text=if($isAdmin){'Администратор — ремонт доступен'}else{'Просмотр — для ремонта нужны права администратора'};$script:instances=@();$script:analysis=$null
function Show-Error([string]$Message){[void][Windows.MessageBox]::Show($window,$Message,'RevitServer Synx',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)}
function Load-Instances{try{$script:instances=@(Get-RevitAcceleratorInstances);$c.InstanceCombo.ItemsSource=$script:instances;if($script:instances.Count){$c.InstanceCombo.SelectedIndex=0;$c.SummaryText.Text="Найдено экземпляров: $($script:instances.Count). Нажмите «Прочитать логи и базы»."}else{$c.SummaryText.Text='Revit Server Accelerator в ProgramData не найден.'}}catch{Show-Error $_.Exception.Message}}
function Refresh-Analysis{
  $instance=$c.InstanceCombo.SelectedItem;if($null-eq$instance){return}
  try{
    $c.StatusText.Text='Чтение AutoSyncLog и SQLite-баз...';$window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)
    $script:analysis=Get-AcceleratorInventory $instance;$models=@($script:analysis.Models);$visibleEvents=@();$stuck=0;$bad=0
    foreach($event in @($script:analysis.Events)){if(($null -ne $event) -and ($event.Level -in @('FAIL','WARN'))){$visibleEvents+=,$event}}
    foreach($model in $models){if($model.Status-eq'ЗАВИСАНИЕ'){$stuck++}elseif($model.Status-eq'ОШИБКА'){$bad++}}
    $c.ModelsGrid.ItemsSource=$models;$c.ErrorsGrid.ItemsSource=if($visibleEvents.Count){@($visibleEvents|Sort-Object Time -Descending)}else{@()}
    $c.SummaryText.Text="Моделей: $($models.Count); зависших: $stuck; с ошибками: $bad; имён: $($script:analysis.ResolvedNames); Host DB: $($script:analysis.DatabaseIntegrity); Status DB: $($script:analysis.StatusDatabaseIntegrity); CacheStatus: $($script:analysis.CacheStatus)"
    $c.StatusText.Text='Проверка завершена. Зависшие модели подняты вверх списка.'
  }catch{$c.StatusText.Text='Ошибка проверки';Show-Error $_.Exception.Message}
}
$c.InstanceCombo.Add_SelectionChanged({$script:analysis=$null;$c.ModelsGrid.ItemsSource=$null;$c.ErrorsGrid.ItemsSource=$null;$c.RepairButton.IsEnabled=$false;$c.OpenCacheButton.IsEnabled=$false})
$c.RefreshButton.Add_Click({Refresh-Analysis})
$c.ModelsGrid.Add_SelectionChanged({$m=$c.ModelsGrid.SelectedItem;if($null-eq$m){$c.SelectedText.Text='Выберите строку слева';$c.RepairButton.IsEnabled=$false;$c.OpenCacheButton.IsEnabled=$false;return};$c.SelectedText.Text="Имя: $($m.Name)`nПуть модели: $($m.ModelPath)`nGUID: $($m.Guid)`nHost: $($m.HostNode)`nСостояние: $($m.Status)`nЗависаний: $($m.HangCount)`nКаталог: $($m.CachePath)";$c.RepairButton.IsEnabled=[bool]$isAdmin;$c.OpenCacheButton.IsEnabled=[bool](Test-Path -LiteralPath $m.CachePath)})
$c.LoadNamesButton.Add_Click({$instance=$c.InstanceCombo.SelectedItem;if($null-eq$instance){return};$dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Title='Выберите ModelLocationTable.db3 с Revit Server Host';$dialog.Filter='ModelLocationTable.db3|ModelLocationTable.db3|SQLite (*.db3)|*.db3';if($dialog.ShowDialog($window)){$instance.LocationDatabases=@(@($instance.LocationDatabases)+$dialog.FileName|Sort-Object -Unique);Refresh-Analysis}})
$c.OpenLogButton.Add_Click({$instance=$c.InstanceCombo.SelectedItem;if($null-ne$instance-and@($instance.LogPaths).Count){Start-Process notepad.exe -ArgumentList ('"'+$instance.LogPaths[0]+'"')}})
$c.OpenCacheButton.Add_Click({$m=$c.ModelsGrid.SelectedItem;if($null-ne$m-and(Test-Path -LiteralPath $m.CachePath)){Start-Process explorer.exe -ArgumentList ('"'+$m.CachePath+'"')}})
$c.RepairButton.Add_Click({
  $m=$c.ModelsGrid.SelectedItem;if($null-eq$m){return}
  try{$preview=New-AcceleratorRepairPreview $m;$serviceText=if(@($preview.Services).Count){$preview.Services-join"`n"}else{'Не найдены'};$poolText=if(@($preview.Pools).Count){$preview.Pools-join"`n"}else{'Не найдены'};$message="Модель: $($preview.Name)`nПуть: $($preview.ModelPath)`nGUID: $($preview.Guid)`nHost: $($preview.HostNode)`n`nСлужбы:`n$serviceText`n`nIIS-пулы:`n$poolText`n`nБудут удалены все активные локальные данные этого GUID: кэш и привязка к Host. Базы будут скопированы и проверены. ModelLocationTable и центральная модель не изменяются.`n`nПродолжить?";if([Windows.MessageBox]::Show($window,$message,'Подтверждение ремонта',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)-ne[Windows.MessageBoxResult]::Yes){return};$c.RepairProgress.Value=0;$c.RepairDetails.Clear();$c.RepairButton.IsEnabled=$false;$c.RefreshButton.IsEnabled=$false;$c.StatusText.Text='Выполняется ремонт. Не закрывайте окно...';$progress={param($percent,$text)$c.RepairProgress.Value=$percent;$c.RepairStepText.Text="$percent% — $text";$c.RepairDetails.AppendText("[$(Get-Date -Format HH:mm:ss)] $text`r`n");$c.RepairDetails.ScrollToEnd();$window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)};$result=Invoke-AcceleratorModelRepair $m -ProgressCallback $progress -Confirm:$false;$c.StatusText.Text="$($result.Message) Отчёт: $($result.ActionRoot)";Refresh-Analysis}catch{$c.StatusText.Text='Ремонт завершился с ошибкой; выполнена попытка автоматического отката.';Show-Error $_.Exception.Message}finally{$c.RefreshButton.IsEnabled=$true;if($null-ne$c.ModelsGrid.SelectedItem){$c.RepairButton.IsEnabled=[bool]$isAdmin}}
})
Load-Instances
[void]$window.ShowDialog()
