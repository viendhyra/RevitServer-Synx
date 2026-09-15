[CmdletBinding()]
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Import-Module (Join-Path $PSScriptRoot 'src\Accelerator.psm1') -Force
$xamlPath=Join-Path $PSScriptRoot 'ui\MainWindow.xaml';[xml]$xaml=[IO.File]::ReadAllText($xamlPath,[Text.Encoding]::UTF8);$reader=New-Object Xml.XmlNodeReader $xaml;$window=[Windows.Markup.XamlReader]::Load($reader)
$names=@('AdminStatusText','InstanceCombo','RefreshButton','SummaryText','LoadNamesButton','OpenLogButton','OpenHistoryButton','OldHostCombo','NewHostText','TestHostButton','MigrateHostButton','LoadHostNamesButton','HostStatusText','ModelsGrid','ErrorsGrid','SelectedText','RepairButton','BatchRepairButton','CacheCheckButton','OpenCacheButton','RepairStepText','RepairProgress','RepairDetails','StatusText');$c=@{}
foreach($name in $names){$control=$window.FindName($name);if($null-eq$control){throw "Элемент интерфейса не найден: $name"};$c[$name]=$control}
$isAdmin=Test-SynxAdministrator;$c.AdminStatusText.Text=if($isAdmin){'Администратор — ремонт доступен'}else{'Просмотр — для ремонта нужны права администратора'};$script:instances=@();$script:analysis=$null;$script:hostTest=$null
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
    $c.BatchRepairButton.IsEnabled=[bool]($isAdmin -and ($stuck -gt 0))
    $c.OpenHistoryButton.IsEnabled=[bool](Test-Path -LiteralPath $script:analysis.HistoryPath -PathType Leaf)
    $repeat=@($models|Where-Object RepeatFailure).Count
    $oldSelection=if($null-ne$c.OldHostCombo.SelectedItem){[string]$c.OldHostCombo.SelectedItem.Address}else{''};$hostGroups=@(Get-SynxHostAddressSummary $instance);$c.OldHostCombo.ItemsSource=$hostGroups
    $preferred='';foreach($event in @($visibleEvents)){if($event.Type-eq'HostResolution'-and$event.HostNode){$preferred=(Split-SynxHostNode ([string]$event.HostNode)).Address;break}}
    for($i=0;$i-lt$hostGroups.Count;$i++){if(($preferred-and$hostGroups[$i].Address-eq$preferred)-or((-not$preferred)-and$oldSelection-and$hostGroups[$i].Address-eq$oldSelection)){$c.OldHostCombo.SelectedIndex=$i;break}}
    if(($c.OldHostCombo.SelectedIndex-lt0)-and$hostGroups.Count){$c.OldHostCombo.SelectedIndex=0}
    $c.HostStatusText.Text=if($hostGroups.Count){"Найдено адресов: $($hostGroups.Count). Выберите устаревший Host и введите новый."}else{'В Host DB нет адресов моделей.'};$script:hostTest=$null;$c.MigrateHostButton.IsEnabled=$false
    $c.SummaryText.Text="Моделей: $($models.Count); зависших: $stuck; повторных: $repeat; с ошибками: $bad; имён: $($script:analysis.ResolvedNames); Host DB: $($script:analysis.DatabaseIntegrity); Status DB: $($script:analysis.StatusDatabaseIntegrity); журнал: $($script:analysis.HistoryStatus)"
    $c.StatusText.Text='Проверка завершена. Зависшие модели подняты вверх списка.'
  }catch{$c.StatusText.Text='Ошибка проверки';Show-Error $_.Exception.Message}
}
$c.InstanceCombo.Add_SelectionChanged({$script:analysis=$null;$script:hostTest=$null;$c.ModelsGrid.ItemsSource=$null;$c.ErrorsGrid.ItemsSource=$null;$c.OldHostCombo.ItemsSource=$null;$c.RepairButton.IsEnabled=$false;$c.BatchRepairButton.IsEnabled=$false;$c.CacheCheckButton.IsEnabled=$false;$c.OpenCacheButton.IsEnabled=$false;$c.OpenHistoryButton.IsEnabled=$false;$c.MigrateHostButton.IsEnabled=$false})
$c.RefreshButton.Add_Click({Refresh-Analysis})
$c.ModelsGrid.Add_SelectionChanged({$m=$c.ModelsGrid.SelectedItem;if($null-eq$m){$c.SelectedText.Text='Выберите строку слева';$c.RepairButton.IsEnabled=$false;$c.CacheCheckButton.IsEnabled=$false;$c.OpenCacheButton.IsEnabled=$false;return};$repeatText=if($m.RepeatFailure){'ДА — GUID снова упал после ремонта'}else{'нет'};$c.SelectedText.Text="Имя: $($m.Name)`nПуть модели: $($m.ModelPath)`nGUID: $($m.Guid)`nHost: $($m.HostNode)`nСостояние: $($m.Status)`nПовтор после ремонта: $repeatText`nСлучаев: $($m.IncidentCount); ремонтов: $($m.RepairCount)`nЗависаний: $($m.HangCount)`nКаталог: $($m.CachePath)";$exists=[bool](Test-Path -LiteralPath $m.CachePath);$c.RepairButton.IsEnabled=[bool]$isAdmin;$c.CacheCheckButton.IsEnabled=$exists;$c.OpenCacheButton.IsEnabled=$exists})
$c.LoadNamesButton.Add_Click({$instance=$c.InstanceCombo.SelectedItem;if($null-eq$instance){return};$dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Title='Выберите ModelLocationTable.db3 с Revit Server Host';$dialog.Filter='ModelLocationTable.db3|ModelLocationTable.db3|SQLite (*.db3)|*.db3';if($dialog.ShowDialog($window)){$instance.LocationDatabases=@(@($instance.LocationDatabases)+$dialog.FileName|Sort-Object -Unique);Refresh-Analysis}})
$c.OpenLogButton.Add_Click({$instance=$c.InstanceCombo.SelectedItem;if($null-ne$instance-and@($instance.LogPaths).Count){Start-Process notepad.exe -ArgumentList ('"'+$instance.LogPaths[0]+'"')}})
$c.OpenHistoryButton.Add_Click({if(($null-ne$script:analysis) -and (Test-Path -LiteralPath $script:analysis.HistoryPath -PathType Leaf)){Start-Process notepad.exe -ArgumentList ('"'+$script:analysis.HistoryPath+'"')}})
$c.OpenCacheButton.Add_Click({$m=$c.ModelsGrid.SelectedItem;if($null-ne$m-and(Test-Path -LiteralPath $m.CachePath)){Start-Process explorer.exe -ArgumentList ('"'+$m.CachePath+'"')}})
$c.CacheCheckButton.Add_Click({
  $m=$c.ModelsGrid.SelectedItem;if($null-eq$m){return}
  try{$c.StatusText.Text="Проверка файлов кэша $($m.Guid)...";$window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background);$folder=Join-Path (Join-Path $m.InstanceRoot 'SynxBackup') 'CacheInspectionManual';$result=Test-SynxCacheFiles -CachePath $m.CachePath -ReportDirectory $folder;$c.StatusText.Text="Проверено файлов: $($result.FileCount); объём: $([Math]::Round($result.TotalBytes/1MB,1)) МБ; проблем: $($result.IssueCount). Отчёт: $($result.ReportPath)";if($result.ReportPath-and(Test-Path -LiteralPath $result.ReportPath)){Start-Process notepad.exe -ArgumentList ('"'+$result.ReportPath+'"')}}catch{$c.StatusText.Text='Ошибка проверки файлов кэша';Show-Error $_.Exception.Message}
})
$c.OldHostCombo.Add_SelectionChanged({$script:hostTest=$null;$c.MigrateHostButton.IsEnabled=$false;if($null-ne$c.OldHostCombo.SelectedItem){$c.HostStatusText.Text="Старый адрес: $($c.OldHostCombo.SelectedItem.Address); моделей: $($c.OldHostCombo.SelectedItem.ModelCount); порты: $($c.OldHostCombo.SelectedItem.Ports)"}})
$c.NewHostText.Add_TextChanged({$script:hostTest=$null;$c.MigrateHostButton.IsEnabled=$false})
$c.TestHostButton.Add_Click({
  $group=$c.OldHostCombo.SelectedItem;if($null-eq$group){Show-Error 'Сначала выберите старый Host.';return}
  try{$ports=@(([string]$group.Ports)-split',\s*'|Where-Object{$_});$script:hostTest=Test-SynxHostEndpoint -Address $c.NewHostText.Text -Ports $ports;$checks=@($script:hostTest.Checks|ForEach-Object{"$($_.Port): $(if($_.Open){'доступен'}else{'НЕТ СОЕДИНЕНИЯ'})"});$c.HostStatusText.Text="DNS/IP: $(@($script:hostTest.ResolvedAddresses)-join', '); $($checks-join'; ')";$c.MigrateHostButton.IsEnabled=[bool]($isAdmin-and$script:hostTest.Resolved-and$script:hostTest.AllPortsOpen);if(-not$script:hostTest.AllPortsOpen){Show-Error "Новый Host не отвечает на всех используемых портах. Миграция заблокирована.`n`n$($checks-join"`n")"}}catch{$c.MigrateHostButton.IsEnabled=$false;Show-Error $_.Exception.Message}
})
$c.LoadHostNamesButton.Add_Click({
  $instance=$c.InstanceCombo.SelectedItem;if($null-eq$instance){return};$host=if($c.NewHostText.Text.Trim()){$c.NewHostText.Text.Trim()}elseif($null-ne$c.OldHostCombo.SelectedItem){[string]$c.OldHostCombo.SelectedItem.Address}else{''}
  try{$path=Import-SynxHostModelNames -Instance $instance -HostAddress $host;$instance.LocationDatabases=@(@($instance.LocationDatabases)+$path|Sort-Object -Unique);Refresh-Analysis;$c.StatusText.Text="Имена моделей загружены из $path"}catch{Show-Error $_.Exception.Message}
})
$c.MigrateHostButton.Add_Click({
  $instance=$c.InstanceCombo.SelectedItem;$group=$c.OldHostCombo.SelectedItem;if(($null-eq$instance)-or($null-eq$group)-or($null-eq$script:hostTest)){return};$new=$c.NewHostText.Text.Trim()
  $affectedGuids=@($group.Models|ForEach-Object{$_.Guid});$named=@($script:analysis.Models|Where-Object{$affectedGuids-contains$_.Guid});$lines=@($named|ForEach-Object{"$(if($_.Name-ne'—'){$_.Name}else{$_.Guid}) — $($_.HostNode)"});$list=($lines|Select-Object -First 14)-join"`n";if($lines.Count-gt14){$list+="`n... и ещё $($lines.Count-14)"}
  $message="Системная смена Host для $($group.ModelCount) моделей:`n$($group.Address) → $new`nПорты сохраняются: $($group.Ports)`n`n$list`n`nAutoSync и IIS-пул будут остановлены. Будет создан бэкап ТОЛЬКО баз; все затронутые кэши переместятся в карантин и загрузятся заново с нового Host. При ошибке выполняется откат.`n`nПродолжить?"
  if([Windows.MessageBox]::Show($window,$message,'Миграция адреса Revit Server Host',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)-ne[Windows.MessageBoxResult]::Yes){return}
  $c.RepairProgress.Value=0;$c.RepairDetails.Clear();$c.MigrateHostButton.IsEnabled=$false;$c.RepairButton.IsEnabled=$false;$c.BatchRepairButton.IsEnabled=$false;$c.RefreshButton.IsEnabled=$false;$c.InstanceCombo.IsEnabled=$false;$c.ModelsGrid.IsEnabled=$false;$c.StatusText.Text='Выполняется миграция Host. Не закрывайте окно...'
  try{$progress={param($percent,$text)$c.RepairProgress.Value=$percent;$c.RepairStepText.Text="$percent% — $text";$c.RepairDetails.AppendText("[$(Get-Date -Format HH:mm:ss)] $text`r`n");$c.RepairDetails.ScrollToEnd();$window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)};$result=Invoke-SynxHostAddressMigration -Instance $instance -OldAddress $group.Address -NewAddress $new -Models @($script:analysis.Models) -ProgressCallback $progress -Confirm:$false;Refresh-Analysis;$c.StatusText.Text="Адрес исправлен для $($result.AffectedCount) моделей. Бэкап: $($result.BackupPath). Карантин: $($result.Quarantine)"}catch{$c.StatusText.Text='Миграция завершилась с ошибкой; выполнена попытка отката.';Show-Error $_.Exception.Message}finally{$c.RefreshButton.IsEnabled=$true;$c.InstanceCombo.IsEnabled=$true;$c.ModelsGrid.IsEnabled=$true}
})
$c.BatchRepairButton.Add_Click({
  if($null -eq $script:analysis){return}
  $stuckModels=@();foreach($model in @($script:analysis.Models)){if(($null -ne $model) -and ($model.Status -eq 'ЗАВИСАНИЕ')){$stuckModels+=,$model}}
  if($stuckModels.Count -eq 0){return}
  $lines=@($stuckModels|ForEach-Object{"$($_.Name)  [$($_.Guid)]"});$preview=($lines|Select-Object -First 12)-join"`n";if($lines.Count -gt 12){$preview+="`n... и ещё $($lines.Count-12)"}
  $message="Найдено зависших моделей: $($stuckModels.Count).`n`n$preview`n`nДля каждой модели будет создан отдельный бэкап базы, удалён локальный кэш GUID и привязка к Host. Центральные модели не изменяются.`n`nИсправить все?"
  if([Windows.MessageBox]::Show($window,$message,'Пакетный ремонт',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning) -ne [Windows.MessageBoxResult]::Yes){return}
  $c.RepairProgress.Value=0;$c.RepairDetails.Clear();$c.RepairButton.IsEnabled=$false;$c.BatchRepairButton.IsEnabled=$false;$c.RefreshButton.IsEnabled=$false;$c.InstanceCombo.IsEnabled=$false;$c.ModelsGrid.IsEnabled=$false
  try{
    for($i=0;$i -lt $stuckModels.Count;$i++){
      $model=$stuckModels[$i];$number=$i+1;$total=$stuckModels.Count;$label=if($model.Name -and $model.Name -ne '—'){$model.Name}else{$model.Guid}
      $progress={param($percent,$text)$overall=[Math]::Min(100,[int](($i*100+$percent)/$total));$c.RepairProgress.Value=$overall;$c.RepairStepText.Text="$overall% — [$number/$total] $label — $text";$c.RepairDetails.AppendText("[$(Get-Date -Format HH:mm:ss)] [$number/$total] $label — $text`r`n");$c.RepairDetails.ScrollToEnd();$window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)}.GetNewClosure()
      [void](Invoke-AcceleratorModelRepair $model -ProgressCallback $progress -Confirm:$false)
    }
    Refresh-Analysis
    $remaining=@($script:analysis.Models|Where-Object{$_.Status -eq 'ЗАВИСАНИЕ'}).Count
    $c.RepairProgress.Value=100;$c.RepairStepText.Text="100% — исправлено моделей: $($stuckModels.Count)";$c.StatusText.Text="Пакетный ремонт завершён. Исправлено: $($stuckModels.Count); осталось зависших: $remaining."
  }catch{Refresh-Analysis;$c.StatusText.Text="Пакетный ремонт остановлен на модели $number из $total.";Show-Error $_.Exception.Message}
  finally{$c.RefreshButton.IsEnabled=$true;$c.InstanceCombo.IsEnabled=$true;$c.ModelsGrid.IsEnabled=$true;if($null-ne$c.ModelsGrid.SelectedItem){$c.RepairButton.IsEnabled=[bool]$isAdmin}}
})
$c.RepairButton.Add_Click({
  $m=$c.ModelsGrid.SelectedItem;if($null-eq$m){return}
  try{
    $preview=New-AcceleratorRepairPreview $m;$serviceText=if(@($preview.Services).Count){$preview.Services-join"`n"}else{'Не найдены'};$poolText=if(@($preview.Pools).Count){$preview.Pools-join"`n"}else{'Не найдены'}
    $message="Модель: $($preview.Name)`nПуть: $($preview.ModelPath)`nGUID: $($preview.Guid)`nHost: $($preview.HostNode)`n`nСлужбы:`n$serviceText`n`nIIS-пулы:`n$poolText`n`nБудут удалены все активные локальные данные этого GUID: кэш и привязка к Host. Базы будут скопированы и проверены. ModelLocationTable и центральная модель не изменяются.`n`nПродолжить?"
    if([Windows.MessageBox]::Show($window,$message,'Подтверждение ремонта',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning) -ne [Windows.MessageBoxResult]::Yes){return}
    $c.RepairProgress.Value=0;$c.RepairDetails.Clear();$c.RepairButton.IsEnabled=$false;$c.BatchRepairButton.IsEnabled=$false;$c.RefreshButton.IsEnabled=$false;$c.InstanceCombo.IsEnabled=$false;$c.ModelsGrid.IsEnabled=$false;$c.StatusText.Text='Выполняется ремонт. Не закрывайте окно...'
    $progress={param($percent,$text)$c.RepairProgress.Value=$percent;$c.RepairStepText.Text="$percent% — $text";$c.RepairDetails.AppendText("[$(Get-Date -Format HH:mm:ss)] $text`r`n");$c.RepairDetails.ScrollToEnd();$window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)}
    $result=Invoke-AcceleratorModelRepair $m -ProgressCallback $progress -Confirm:$false
    Refresh-Analysis
    $remaining=@($script:analysis.Models|Where-Object{$_.Status -eq 'ЗАВИСАНИЕ'}).Count
    $c.StatusText.Text="GUID $($result.Guid) исправлен. Других зависших моделей: $remaining. Отчёт: $($result.ActionRoot)"
  }catch{$c.StatusText.Text='Ремонт завершился с ошибкой; выполнена попытка автоматического отката.';Show-Error $_.Exception.Message}
  finally{$c.RefreshButton.IsEnabled=$true;$c.InstanceCombo.IsEnabled=$true;$c.ModelsGrid.IsEnabled=$true;if($null-ne$c.ModelsGrid.SelectedItem){$c.RepairButton.IsEnabled=[bool]$isAdmin}}
})
Load-Instances
[void]$window.ShowDialog()
