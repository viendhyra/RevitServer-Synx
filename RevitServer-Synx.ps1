[CmdletBinding()]
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$modulePath=Join-Path $PSScriptRoot 'src\Accelerator.psm1'
Import-Module $modulePath -Force
$xamlPath=Join-Path $PSScriptRoot 'ui\MainWindow.xaml';[xml]$xaml=[IO.File]::ReadAllText($xamlPath,[Text.Encoding]::UTF8);$reader=New-Object Xml.XmlNodeReader $xaml;$window=[Windows.Markup.XamlReader]::Load($reader)
$names=@('AdminStatusText','InstanceCombo','RefreshButton','SummaryText','LoadNamesButton','OpenLogButton','OpenHistoryButton','ClearCacheButton','OldHostCombo','NewHostText','TestHostButton','MigrateHostButton','LoadHostNamesButton','HostStatusText','ModelsGrid','ErrorsGrid','SelectedText','DiagnosisCard','DiagnosisTitleText','DiagnosisConfidenceText','DiagnosisEvidenceText','DiagnosisActionText','RepairButton','BatchRepairButton','CacheCheckButton','OpenDiagnosticButton','OpenCacheButton','RepairStepText','RepairProgress','RepairDetails','StatusText','JobProgress','AdminBadge','ModelsTab','ErrorsTab','HostExpander');$c=@{}
foreach($name in $names){$control=$window.FindName($name);if($null-eq$control){throw "Элемент интерфейса не найден: $name"};$c[$name]=$control}
$script:job=$null;$script:batchLimit=5
$isAdmin=Test-SynxAdministrator;$c.AdminStatusText.Text=if($isAdmin){'Администратор — ремонт доступен'}else{'Только просмотр — для ремонта нужны права администратора'};if(-not$isAdmin){$c.AdminBadge.Background='#78350F';$c.AdminStatusText.Foreground='#FEF3C7'};$script:instances=@();$script:analysis=$null;$script:hostTest=$null;$script:lastDiagnosticPath=''
function Show-Error([string]$Message){[void][Windows.MessageBox]::Show($window,$Message,'RevitServer Synx',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)}
function Confirm-Action([string]$Message,[string]$Title){[Windows.MessageBox]::Show($window,$Message,$Title,[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)-eq[Windows.MessageBoxResult]::Yes}
function Set-DiagnosisPanel($Model,[string]$Reason,[string]$Confidence,[string]$Evidence,[string]$Action){
  if($null-eq$Model){$c.DiagnosisTitleText.Text='Сначала выберите модель';$c.DiagnosisConfidenceText.Text='Уверенность: —';$c.DiagnosisEvidenceText.Text='Доказательства появятся после анализа.';$c.DiagnosisActionText.Text='—';$c.DiagnosisCard.Background='#F8FAFC';$c.DiagnosisCard.BorderBrush='#CBD5E1';return}
  $c.DiagnosisTitleText.Text=$Reason;$c.DiagnosisConfidenceText.Text="Уверенность: $Confidence";$c.DiagnosisEvidenceText.Text=$Evidence;$c.DiagnosisActionText.Text=$Action
  if($Confidence-eq'Высокая'){$c.DiagnosisCard.Background='#FEF2F2';$c.DiagnosisCard.BorderBrush='#FCA5A5'}elseif($Confidence-eq'Средняя'){$c.DiagnosisCard.Background='#FFFBEB';$c.DiagnosisCard.BorderBrush='#FCD34D'}else{$c.DiagnosisCard.Background='#EFF6FF';$c.DiagnosisCard.BorderBrush='#93C5FD'}
}
function Update-Buttons{
  $idle=$null-eq$script:job;$m=$c.ModelsGrid.SelectedItem
  $exists=[bool](($null-ne$m)-and(Test-Path -LiteralPath $m.CachePath))
  foreach($name in @('RefreshButton','InstanceCombo','LoadNamesButton','LoadHostNamesButton','TestHostButton','OldHostCombo','NewHostText','ModelsGrid')){$c[$name].IsEnabled=$idle}
  $stuck=0;if($null-ne$script:analysis){$stuck=@($script:analysis.Models|Where-Object{$_.Status-eq'ЗАВИСАНИЕ'}).Count}
  $c.RepairButton.IsEnabled=[bool]($idle-and$isAdmin-and($null-ne$m))
  $c.CacheCheckButton.IsEnabled=[bool]($idle-and$exists)
  $c.OpenCacheButton.IsEnabled=$exists
  $c.BatchRepairButton.IsEnabled=[bool]($idle-and$isAdmin-and($stuck-gt0))
  $c.MigrateHostButton.IsEnabled=[bool]($idle-and$isAdmin-and($null-ne$script:hostTest)-and$script:hostTest.Resolved-and$script:hostTest.AllPortsOpen)
  $c.ClearCacheButton.IsEnabled=[bool]($idle-and$isAdmin-and($null-ne$c.InstanceCombo.SelectedItem))
  $c.OpenHistoryButton.IsEnabled=[bool](($null-ne$script:analysis)-and(Test-Path -LiteralPath $script:analysis.HistoryPath -PathType Leaf))
  $c.OpenDiagnosticButton.IsEnabled=[bool]($script:lastDiagnosticPath-and(Test-Path -LiteralPath $script:lastDiagnosticPath -PathType Leaf))
}

# Долгая работа идёт в фоновом runspace, окно остаётся живым. Прогресс
# передаётся через synchronized-таблицу, её раз в 150 мс читает таймер
# UI-потока. Работа передаётся текстом: скриптблок привязан к своему
# runspace, и UI-блок, вызванный из фонового потока, падает или блокируется.
$script:jobBootstrap={
  param($ModulePath,$Sync,$WorkText,$Arguments)
  $ErrorActionPreference='Stop'
  try{
    Import-Module $ModulePath -Force
    $Arguments['Progress']={param($Percent,$Text)$Sync.Percent=[int]$Percent;$Sync.Text=[string]$Text;[void]$Sync.Log.Add("[$(Get-Date -Format HH:mm:ss)] $Text")}
    $Sync.Result=& ([scriptblock]::Create($WorkText)) @Arguments
  }catch{$Sync.Error=$_.Exception.Message}
}
function Start-SynxJob{
  # Critical — работа меняет службы и файлы: окно нельзя закрыть, шаги пишутся в журнал ремонта.
  param([Parameter(Mandatory)][string]$Title,[Parameter(Mandatory)][scriptblock]$Work,[hashtable]$Arguments=@{},[Parameter(Mandatory)][scriptblock]$OnDone,$Context=$null,[switch]$Critical)
  if($null-ne$script:job){return}
  $sync=[hashtable]::Synchronized(@{Percent=0;Text=$Title;Log=[Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList));Result=$null;Error=$null})
  $ps=[PowerShell]::Create()
  [void]$ps.AddScript($script:jobBootstrap.ToString()).AddArgument($modulePath).AddArgument($sync).AddArgument($Work.ToString()).AddArgument($Arguments)
  $script:job=[pscustomobject]@{PS=$ps;Handle=$null;Sync=$sync;OnDone=$OnDone;Context=$Context;Critical=[bool]$Critical;LogIndex=0}
  $script:job.Handle=$ps.BeginInvoke()
  $c.JobProgress.Value=0;$c.JobProgress.Visibility='Visible';$c.StatusText.Text=$Title
  if($Critical){$c.RepairProgress.Value=0;$c.RepairStepText.Text="0% — $Title";$c.RepairDetails.Clear()}
  Update-Buttons
  $script:timer.Start()
}
$script:timer=New-Object Windows.Threading.DispatcherTimer;$script:timer.Interval=[TimeSpan]::FromMilliseconds(150)
$script:timer.Add_Tick({
  $j=$script:job;if($null-eq$j){$script:timer.Stop();return}
  $finished=$j.Handle.IsCompleted
  $s=$j.Sync;$percent=[int]$s.Percent;$text=[string]$s.Text
  $c.JobProgress.Value=$percent;$c.StatusText.Text="$percent% — $text"
  if($j.Critical){
    $c.RepairProgress.Value=$percent;$c.RepairStepText.Text="$percent% — $text"
    $count=$s.Log.Count;if($count-gt$j.LogIndex){for($k=$j.LogIndex;$k-lt$count;$k++){$c.RepairDetails.AppendText([string]$s.Log[$k]+"`r`n")};$j.LogIndex=$count;$c.RepairDetails.ScrollToEnd()}
  }
  if(-not$finished){return}
  $script:timer.Stop()
  try{[void]$j.PS.EndInvoke($j.Handle)}catch{if(-not$s.Error){$s.Error=$_.Exception.Message}}
  $j.PS.Dispose();$script:job=$null;$c.JobProgress.Visibility='Collapsed'
  Update-Buttons
  try{& $j.OnDone $s.Result $s.Error $j.Context}catch{Show-Error $_.Exception.Message}
})
$window.Add_Closing({param($sender,$e)
  $j=$script:job;if($null-eq$j){return}
  if($j.Critical){$e.Cancel=$true;[void][Windows.MessageBox]::Show($window,'Идёт ремонт. Закрытие окна сейчас оставит службы остановленными, а состояние — рассогласованным. Дождитесь завершения.','RevitServer Synx',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning);return}
  $script:timer.Stop();try{[void]$j.PS.BeginStop($null,$null)}catch{}
})

function Load-Instances{try{$script:instances=@(Get-RevitAcceleratorInstances);$c.InstanceCombo.ItemsSource=$script:instances;if($script:instances.Count){$c.InstanceCombo.SelectedIndex=0;$c.SummaryText.Text="Найдено экземпляров: $($script:instances.Count). Нажмите «Прочитать логи и базы»."}else{$c.SummaryText.Text='Revit Server Accelerator в ProgramData не найден.'};Update-Buttons}catch{Show-Error $_.Exception.Message}}
function Show-Analysis($Result){
  $script:analysis=$Result.Analysis;$models=@($script:analysis.Models);$visibleEvents=@($Result.VisibleEvents);$stuck=0;$bad=0
  foreach($model in $models){if($model.Status-eq'ЗАВИСАНИЕ'){$stuck++}elseif($model.Status-eq'ОШИБКА'){$bad++}}
  $c.ModelsGrid.ItemsSource=$models;$c.ErrorsGrid.ItemsSource=$visibleEvents
  $c.ModelsTab.Header="Модели · $($models.Count)";$c.ErrorsTab.Header="Ошибки AutoSync · $($visibleEvents.Count)"
  $repeat=@($models|Where-Object RepeatFailure).Count
  $oldSelection=if($null-ne$c.OldHostCombo.SelectedItem){[string]$c.OldHostCombo.SelectedItem.Address}else{''};$hostGroups=@($Result.Hosts);$c.OldHostCombo.ItemsSource=$hostGroups
  $preferred='';foreach($event in @($visibleEvents)){if($event.Type-eq'HostResolution'-and$event.HostNode){$preferred=(Split-SynxHostNode ([string]$event.HostNode)).Address;break}}
  for($i=0;$i-lt$hostGroups.Count;$i++){if(($preferred-and$hostGroups[$i].Address-eq$preferred)-or((-not$preferred)-and$oldSelection-and$hostGroups[$i].Address-eq$oldSelection)){$c.OldHostCombo.SelectedIndex=$i;break}}
  if(($c.OldHostCombo.SelectedIndex-lt0)-and$hostGroups.Count){$c.OldHostCombo.SelectedIndex=0}
  if($preferred){$c.HostExpander.IsExpanded=$true}
  $c.HostStatusText.Text=if($hostGroups.Count){"Найдено адресов: $($hostGroups.Count). Выберите устаревший Host и введите новый."}else{'В Host DB нет адресов моделей.'};$script:hostTest=$null
  $c.SummaryText.Text="Моделей: $($models.Count); зависших: $stuck; повторных: $repeat; с ошибками: $bad; имён: $($script:analysis.ResolvedNames); Host DB: $($script:analysis.DatabaseIntegrity); Status DB: $($script:analysis.StatusDatabaseIntegrity); журнал: $($script:analysis.HistoryStatus)"
  $c.StatusText.Text='Проверка завершена. Зависшие модели подняты вверх списка.'
  Update-Buttons
}
function Get-StuckCount{@($script:analysis.Models|Where-Object{$_.Status -eq 'ЗАВИСАНИЕ'}).Count}
function Refresh-Analysis{
  # Then вызывается после успешного чтения — для итогового текста после ремонта.
  param([scriptblock]$Then,$ThenContext)
  $instance=$c.InstanceCombo.SelectedItem;if($null-eq$instance){return}
  Start-SynxJob -Title 'Чтение AutoSyncLog и SQLite-баз...' -Arguments @{Instance=$instance} -Context @{Then=$Then;Context=$ThenContext} -Work {
    param($Instance,$Progress)
    $analysis=Get-AcceleratorInventory $Instance -ProgressCallback $Progress
    & $Progress 96 'Группировка адресов Host'
    $hosts=@(Get-SynxHostAddressSummary $Instance)
    # Фильтр и сортировка событий здесь, а не в UI-потоке: их десятки тысяч.
    & $Progress 98 'Подготовка списка ошибок'
    $visible=@($analysis.Events|Where-Object{($null-ne$_)-and($_.Level-in@('FAIL','WARN'))}|Sort-Object Time -Descending)
    [pscustomobject]@{Analysis=$analysis;Hosts=$hosts;VisibleEvents=$visible}
  } -OnDone {
    param($Result,$ErrorText,$Context)
    if($ErrorText){$c.StatusText.Text='Ошибка проверки';Show-Error $ErrorText;return}
    Show-Analysis $Result
    if($Context.Then){& $Context.Then $Context.Context}
  }
}

$c.InstanceCombo.Add_SelectionChanged({$script:analysis=$null;$script:hostTest=$null;$script:lastDiagnosticPath='';$c.ModelsGrid.ItemsSource=$null;$c.ErrorsGrid.ItemsSource=$null;$c.OldHostCombo.ItemsSource=$null;$c.ModelsTab.Header='Модели';$c.ErrorsTab.Header='Ошибки AutoSync';Set-DiagnosisPanel $null '' '' '' '';Update-Buttons})
$c.RefreshButton.Add_Click({Refresh-Analysis})
$c.ModelsGrid.Add_SelectionChanged({$m=$c.ModelsGrid.SelectedItem;$script:lastDiagnosticPath='';Update-Buttons;if($null-eq$m){$c.SelectedText.Text='Выберите строку слева';Set-DiagnosisPanel $null '' '' '' '';return};$repeatText=if($m.RepeatFailure){'ДА — GUID снова упал после ремонта'}else{'нет'};$c.SelectedText.Text="Имя: $($m.Name)`nПуть модели: $($m.ModelPath)`nGUID: $($m.Guid)`nHost: $($m.HostNode)`nСостояние: $($m.Status)`nПовтор после ремонта: $repeatText`nСлучаев: $($m.IncidentCount); ремонтов: $($m.RepairCount)`nЗависаний: $($m.HangCount)`nКаталог: $($m.CachePath)";Set-DiagnosisPanel $m $m.Diagnosis $m.DiagnosisConfidence $m.DiagnosisEvidence $m.DiagnosisAction})
$c.LoadNamesButton.Add_Click({$instance=$c.InstanceCombo.SelectedItem;if($null-eq$instance){return};$dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Title='Выберите ModelLocationTable.db3 с Revit Server Host';$dialog.Filter='ModelLocationTable.db3|ModelLocationTable.db3|SQLite (*.db3)|*.db3';if($dialog.ShowDialog($window)){$instance.LocationDatabases=@(@($instance.LocationDatabases)+$dialog.FileName|Sort-Object -Unique);Refresh-Analysis}})
$c.OpenLogButton.Add_Click({$instance=$c.InstanceCombo.SelectedItem;if($null-ne$instance-and@($instance.LogPaths).Count){Start-Process notepad.exe -ArgumentList ('"'+$instance.LogPaths[0]+'"')}})
$c.OpenHistoryButton.Add_Click({if(($null-ne$script:analysis) -and (Test-Path -LiteralPath $script:analysis.HistoryPath -PathType Leaf)){Start-Process notepad.exe -ArgumentList ('"'+$script:analysis.HistoryPath+'"')}})
$c.OpenCacheButton.Add_Click({$m=$c.ModelsGrid.SelectedItem;if($null-ne$m-and(Test-Path -LiteralPath $m.CachePath)){Start-Process explorer.exe -ArgumentList ('"'+$m.CachePath+'"')}})
$c.OpenDiagnosticButton.Add_Click({if($script:lastDiagnosticPath-and(Test-Path -LiteralPath $script:lastDiagnosticPath -PathType Leaf)){Start-Process notepad.exe -ArgumentList ('"'+$script:lastDiagnosticPath+'"')}})
$c.CacheCheckButton.Add_Click({
  $m=$c.ModelsGrid.SelectedItem;if(($null-eq$m)-or($null-eq$script:analysis)){return}
  $folder=Join-Path (Join-Path $m.InstanceRoot 'SynxBackup') 'ModelDiagnostics'
  Start-SynxJob -Title "Определение причины зависания $($m.Guid)..." -Arguments @{Model=$m;LogPaths=@($script:analysis.Instance.LogPaths);ReportDirectory=$folder} -Context $m -Work {
    param($Model,$LogPaths,$ReportDirectory,$Progress)
    Test-SynxModelDiagnostics -Model $Model -LogPaths $LogPaths -ReportDirectory $ReportDirectory -ProgressCallback $Progress
  } -OnDone {
    param($Result,$ErrorText,$m)
    if($ErrorText){$c.StatusText.Text='Ошибка глубокой диагностики модели';Show-Error $ErrorText;return}
    $script:lastDiagnosticPath=$Result.ReportPath;$m.Diagnosis=$Result.Reason;$m.DiagnosisConfidence=$Result.Confidence;$m.DiagnosisEvidence=@($Result.Evidence)-join"`n";$m.DiagnosisAction=$Result.Action;$c.ModelsGrid.Items.Refresh()
    if($c.ModelsGrid.SelectedItem-eq$m){Set-DiagnosisPanel $m $m.Diagnosis $m.DiagnosisConfidence $m.DiagnosisEvidence $m.DiagnosisAction}
    Update-Buttons
    $dbText=@($Result.Cache.DatabaseChecks|ForEach-Object{"$([IO.Path]::GetFileName($_.Path))=$($_.Integrity)"})-join'; ';$last=if($Result.Cache.LastWriteTime){([datetime]$Result.Cache.LastWriteTime).ToString('dd.MM HH:mm:ss')}else{'нет'}
    $c.StatusText.Text="Причина: $($Result.Reason) ($($Result.Confidence)). Файлов: $($Result.Cache.FileCount); SQLite: $dbText; последний файл: $last. Отчёт: $($Result.ReportPath)"
  }
})
$c.OldHostCombo.Add_SelectionChanged({$script:hostTest=$null;Update-Buttons;if($null-ne$c.OldHostCombo.SelectedItem){$c.HostStatusText.Text="Старый адрес: $($c.OldHostCombo.SelectedItem.Address); моделей: $($c.OldHostCombo.SelectedItem.ModelCount); порты: $($c.OldHostCombo.SelectedItem.Ports)"}})
$c.NewHostText.Add_TextChanged({$script:hostTest=$null;Update-Buttons})
$c.TestHostButton.Add_Click({
  $group=$c.OldHostCombo.SelectedItem;if($null-eq$group){Show-Error 'Сначала выберите старый Host.';return}
  $ports=@(([string]$group.Ports)-split',\s*'|Where-Object{$_})
  Start-SynxJob -Title "Проверка DNS и портов $($c.NewHostText.Text)..." -Arguments @{Address=$c.NewHostText.Text;Ports=$ports} -Work {
    param($Address,$Ports,$Progress)
    Test-SynxHostEndpoint -Address $Address -Ports $Ports
  } -OnDone {
    param($Result,$ErrorText)
    if($ErrorText){$script:hostTest=$null;Update-Buttons;$c.StatusText.Text='Проверка адреса не выполнена';Show-Error $ErrorText;return}
    $script:hostTest=$Result;Update-Buttons
    $checks=@($Result.Checks|ForEach-Object{"$($_.Port): $(if($_.Open){'доступен'}else{'НЕТ СОЕДИНЕНИЯ'})"})
    $c.HostStatusText.Text="DNS/IP: $(@($Result.ResolvedAddresses)-join', '); $($checks-join'; ')";$c.StatusText.Text='Проверка адреса завершена'
    if(-not$Result.AllPortsOpen){Show-Error "Новый Host не отвечает на всех используемых портах. Миграция заблокирована.`n`n$($checks-join"`n")"}
  }
})
$c.LoadHostNamesButton.Add_Click({
  $instance=$c.InstanceCombo.SelectedItem;if($null-eq$instance){return}
  $hostAddress=if($c.NewHostText.Text.Trim()){$c.NewHostText.Text.Trim()}elseif($null-ne$c.OldHostCombo.SelectedItem){[string]$c.OldHostCombo.SelectedItem.Address}else{''}
  Start-SynxJob -Title "Копирование ModelLocationTable.db3 с $hostAddress..." -Arguments @{Instance=$instance;HostAddress=$hostAddress} -Context $instance -Work {
    param($Instance,$HostAddress,$Progress)
    Import-SynxHostModelNames -Instance $Instance -HostAddress $HostAddress
  } -OnDone {
    param($Result,$ErrorText,$instance)
    if($ErrorText){$c.StatusText.Text='Имена моделей не получены';Show-Error $ErrorText;return}
    $instance.LocationDatabases=@(@($instance.LocationDatabases)+$Result|Sort-Object -Unique)
    Refresh-Analysis -ThenContext $Result -Then {param($path)$c.StatusText.Text="Имена моделей загружены из $path"}
  }
})
$c.MigrateHostButton.Add_Click({
  $instance=$c.InstanceCombo.SelectedItem;$group=$c.OldHostCombo.SelectedItem;if(($null-eq$instance)-or($null-eq$group)-or($null-eq$script:hostTest)){return};$new=$c.NewHostText.Text.Trim()
  $affectedGuids=@($group.Models|ForEach-Object{$_.Guid});$named=@($script:analysis.Models|Where-Object{$affectedGuids-contains$_.Guid});$lines=@($named|ForEach-Object{"$(if($_.Name-ne'—'){$_.Name}else{$_.Guid}) — $($_.HostNode)"});$list=($lines|Select-Object -First 14)-join"`n";if($lines.Count-gt14){$list+="`n... и ещё $($lines.Count-14)"}
  $message="Системная смена Host для $($group.ModelCount) моделей:`n$($group.Address) → $new`nПорты сохраняются: $($group.Ports)`n`n$list`n`nAutoSync и IIS-пул будут остановлены. Будет создан бэкап ТОЛЬКО баз; все затронутые кэши переместятся в карантин и загрузятся заново с нового Host. При ошибке выполняется откат.`n`nПродолжить?"
  if(-not(Confirm-Action $message 'Миграция адреса Revit Server Host')){return}
  Start-SynxJob -Critical -Title 'Выполняется миграция Host. Не закрывайте окно...' -Arguments @{Instance=$instance;OldAddress=$group.Address;NewAddress=$new;Models=@($script:analysis.Models)} -Work {
    param($Instance,$OldAddress,$NewAddress,$Models,$Progress)
    Invoke-SynxHostAddressMigration -Instance $Instance -OldAddress $OldAddress -NewAddress $NewAddress -Models $Models -ProgressCallback $Progress -Confirm:$false
  } -OnDone {
    param($Result,$ErrorText)
    if($ErrorText){$c.StatusText.Text='Миграция завершилась с ошибкой; выполнена попытка отката.';Show-Error $ErrorText;Refresh-Analysis;return}
    Refresh-Analysis -ThenContext $Result -Then {param($r)$c.StatusText.Text="Адрес исправлен для $($r.AffectedCount) моделей. Бэкап: $($r.BackupPath). Карантин: $($r.Quarantine)"}
  }
})
$c.BatchRepairButton.Add_Click({
  if($null -eq $script:analysis){return}
  $allStuck=@();foreach($model in @($script:analysis.Models)){if(($null -ne $model) -and ($model.Status -eq 'ЗАВИСАНИЕ')){$allStuck+=,$model}}
  if($allStuck.Count -eq 0){return}
  # Одно подтверждение не должно сносить кэш всего сервера.
  $stuckModels=@($allStuck|Select-Object -First $script:batchLimit)
  $lines=@($stuckModels|ForEach-Object{"$($_.Name)  [$($_.Guid)]"});$preview=$lines-join"`n"
  $tail=if($allStuck.Count -gt $stuckModels.Count){"`n`nОстальные ($($allStuck.Count-$stuckModels.Count)) — отдельным запуском после проверки результата."}else{''}
  $message="Зависших моделей: $($allStuck.Count). За один пакет обрабатывается не более $($script:batchLimit):`n`n$preview$tail`n`nДля каждой модели будет создан отдельный бэкап базы, удалён локальный кэш GUID и привязка к Host. Центральные модели не изменяются.`n`nИсправить?"
  if(-not(Confirm-Action $message 'Пакетный ремонт')){return}
  Start-SynxJob -Critical -Title 'Пакетный ремонт. Не закрывайте окно...' -Arguments @{Models=$stuckModels} -Work {
    param($Models,$Progress)
    $total=@($Models).Count
    for($i=0;$i -lt $total;$i++){
      $model=$Models[$i];$number=$i+1;$label=if($model.Name -and $model.Name -ne '—'){$model.Name}else{$model.Guid}
      # $i, $number, $label и $Progress берутся из этой области при вызове из модуля.
      $step={param($percent,$text)& $Progress ([Math]::Min(100,[int](($i*100+$percent)/$total))) "[$number/$total] $label — $text"}
      try{[void](Invoke-AcceleratorModelRepair $model -ProgressCallback $step -Confirm:$false)}catch{throw "Пакетный ремонт остановлен на модели $number из $total ($label): $($_.Exception.Message)"}
    }
    $total
  } -OnDone {
    param($Result,$ErrorText)
    if($ErrorText){Show-Error $ErrorText;Refresh-Analysis -Then {$c.StatusText.Text="Пакетный ремонт остановлен с ошибкой; осталось зависших: $(Get-StuckCount)."};return}
    Refresh-Analysis -ThenContext $Result -Then {param($count)$c.RepairProgress.Value=100;$c.RepairStepText.Text="100% — исправлено моделей: $count";$c.StatusText.Text="Пакетный ремонт завершён. Исправлено: $count; осталось зависших: $(Get-StuckCount)."}
  }
})
$c.RepairButton.Add_Click({
  $m=$c.ModelsGrid.SelectedItem;if($null-eq$m){return}
  Start-SynxJob -Title 'Поиск AutoSync и IIS-пула для ремонта...' -Arguments @{Model=$m} -Context $m -Work {
    param($Model,$Progress)
    New-AcceleratorRepairPreview $Model
  } -OnDone {
    param($preview,$ErrorText,$m)
    if($ErrorText){$c.StatusText.Text='Не удалось подготовить ремонт';Show-Error $ErrorText;return}
    $serviceText=if(@($preview.Services).Count){$preview.Services-join"`n"}else{'Не найдены'};$poolText=if(@($preview.Pools).Count){$preview.Pools-join"`n"}else{'Не найдены'}
    $message="Модель: $($preview.Name)`nПуть: $($preview.ModelPath)`nGUID: $($preview.Guid)`nHost: $($preview.HostNode)`n`nСлужбы:`n$serviceText`n`nIIS-пулы:`n$poolText`n`nБудут удалены все активные локальные данные этого GUID: кэш и привязка к Host. Базы будут скопированы и проверены. ModelLocationTable и центральная модель не изменяются.`n`nПродолжить?"
    $c.StatusText.Text='Готово'
    if(-not(Confirm-Action $message 'Подтверждение ремонта')){return}
    Start-SynxJob -Critical -Title 'Выполняется ремонт. Не закрывайте окно...' -Arguments @{Model=$m} -Work {
      param($Model,$Progress)
      Invoke-AcceleratorModelRepair $Model -ProgressCallback $Progress -Confirm:$false
    } -OnDone {
      param($Result,$ErrorText)
      if($ErrorText){$c.StatusText.Text='Ремонт завершился с ошибкой; выполнена попытка автоматического отката.';Show-Error $ErrorText;Refresh-Analysis;return}
      Refresh-Analysis -ThenContext $Result -Then {param($r)$c.StatusText.Text="GUID $($r.Guid) исправлен. Других зависших моделей: $(Get-StuckCount). Отчёт: $($r.ActionRoot)"}
    }
  }
})
$c.ClearCacheButton.Add_Click({
  $instance=$c.InstanceCombo.SelectedItem;if($null-eq$instance){return}
  Start-SynxJob -Title 'Подготовка полной очистки кэша...' -Arguments @{Instance=$instance} -Context $instance -Work {
    param($Instance,$Progress)
    & $Progress 20 'Поиск AutoSync и IIS-пула'
    $targets=Get-AcceleratorRepairTargets ([pscustomobject]@{Year=$Instance.Year;InstanceRoot=$Instance.Root})
    & $Progress 70 'Подсчёт содержимого кэша'
    $items=@(Get-ChildItem -LiteralPath $Instance.CachePath -Force -ErrorAction SilentlyContinue)
    [pscustomobject]@{Services=@($targets.Services|ForEach-Object{"$($_.DisplayName) [$($_.State)]"});Pools=@($targets.Pools|ForEach-Object{"$($_.Name) [$($_.State)]"});PoolError=$targets.PoolError;GuidCount=@($items|Where-Object{$_.PSIsContainer-and$_.Name-match'^[0-9a-fA-F-]{36}$'}).Count;Other=@($items|Where-Object{-not($_.PSIsContainer-and$_.Name-match'^[0-9a-fA-F-]{36}$')}|ForEach-Object{$_.Name})}
  } -OnDone {
    param($preview,$ErrorText,$instance)
    if($ErrorText){$c.StatusText.Text='Не удалось подготовить очистку';Show-Error $ErrorText;return}
    $c.StatusText.Text='Готово'
    if(-not@($preview.Services).Count-or-not@($preview.Pools).Count){Show-Error "Для $($instance.Name) не найдены служба AutoSync или IIS-пул. Очистка без их остановки небезопасна и заблокирована.`n$($preview.PoolError)";return}
    if(($preview.GuidCount-eq0)-and(@($preview.Other).Count-eq0)){$c.StatusText.Text="Кэш $($instance.CachePath) уже пуст.";return}
    $otherText=if(@($preview.Other).Count){@($preview.Other)-join', '}else{'нет'}
    $message="ПОЛНАЯ ОЧИСТКА КЭША $($instance.Name)`n`nКаталог: $($instance.CachePath)`nКаталогов моделей (GUID): $($preview.GuidCount)`nСлужебные файлы: $otherText`n`nСлужбы:`n$(@($preview.Services)-join"`n")`n`nIIS-пулы:`n$(@($preview.Pools)-join"`n")`n`nПорядок: остановка AutoSync и IIS-пула → перемещение ВСЕГО содержимого Cache (включая HostNodeForCachedModels.db3 и LocalServer_Cache.db3) в SynxQuarantine → проверка → запуск. Ничего не удаляется; создаётся Rollback.ps1. При ошибке содержимое возвращается автоматически.`n`nНа время очистки Accelerator недоступен. После неё каждая модель заново загрузится с Host при первом открытии — это нагрузка на канал. Попросите пользователей закрыть модели этого Accelerator.`n`nОчистить весь кэш?"
    if(-not(Confirm-Action $message 'Полная очистка кэша Accelerator')){return}
    Start-SynxJob -Critical -Title 'Полная очистка кэша. Не закрывайте окно...' -Arguments @{Instance=$instance} -Work {
      param($Instance,$Progress)
      Invoke-SynxFullCacheClear -Instance $Instance -ProgressCallback $Progress -Confirm:$false
    } -OnDone {
      param($Result,$ErrorText)
      if($ErrorText){$c.StatusText.Text='Очистка завершилась с ошибкой; выполнена попытка отката.';Show-Error $ErrorText;Refresh-Analysis;return}
      Refresh-Analysis -ThenContext $Result -Then {param($r)$c.StatusText.Text="Кэш очищен: в карантине элементов $($r.ItemCount), моделей $($r.GuidCount). Карантин: $($r.Quarantine). Откат: $($r.ActionRoot)\Rollback.ps1"}
    }
  }
})
Load-Instances
[void]$window.ShowDialog()
