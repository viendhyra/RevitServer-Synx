# RevitServer-Synx

Графическая диагностика и точечный ремонт кэша Autodesk Revit Server Accelerator после аварийного выключения, зависания AutoSync или ошибок синхронизации отдельных моделей.

Обычное открытие программы ничего не изменяет. Ремонт выполняется только для выбранной модели после отдельного подтверждения.

## Быстрый запуск с GitHub

Откройте **Windows PowerShell от имени администратора** и выполните:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/viendhyra/RevitServer-Synx/main/Run.ps1 | iex
```

Команда загружает временную копию программы в `%TEMP%` и открывает графический интерфейс. Установка не требуется.

Более безопасный запуск с предварительным просмотром загрузчика:

```powershell
$url = 'https://raw.githubusercontent.com/viendhyra/RevitServer-Synx/main/Run.ps1'
$file = "$env:TEMP\Run-RevitServer-Synx.ps1"
Invoke-WebRequest -UseBasicParsing $url -OutFile $file
notepad $file
& $file
```

## Что проверяется

- установленные экземпляры `Revit Server 20xx` в `%ProgramData%\Autodesk`;
- `AutoSyncLog.log` и повторения `threads are still not done for Model`;
- GUID зависших моделей и номера циклов AutoSync;
- ошибки разрешения HostNode/IP;
- `HostNodeForCachedModels.db3` и привязки GUID → Host;
- `LocalServer_Cache.db3` и `CacheStatus`;
- целостность обеих SQLite-баз;
- наличие каталога `Cache\<GUID>`;
- осиротевшие каталоги без записи в базе.

Используется встроенная библиотека Windows `winsqlite3.dll`; Python и отдельный `sqlite3.exe` не требуются.

## Как выполняется ремонт

После выбора модели и нажатия **«Исправить выбранную модель»** программа:

1. сохраняет состояние служб и IIS-пулов;
2. останавливает Revit Server AutoSync выбранной версии;
3. останавливает соответствующий `RevitServerAppPool20xx`;
4. создаёт резервную копию обеих `.db3` и служебных journal/WAL-файлов;
5. проверяет размер и SHA-256 резервных копий баз;
6. переносит только `Cache\<выбранный GUID>` в `SynxQuarantine` без копирования кэша;
7. транзакционно удаляет только выбранный GUID из `HostNodeForCachedModels.db3`;
8. выполняет `PRAGMA integrity_check`;
9. запускает компоненты, которые работали до ремонта;
10. создаёт отчёт и `Rollback.ps1`.

Если шаг завершается ошибкой, программа пытается автоматически восстановить базу, каталог кэша и состояние компонентов.

Центральная модель на Revit Server Host, её имя, GUID и ссылки из других проектов не изменяются. При следующем обращении Accelerator заново получает кэш модели с Host.

## Состояния в таблице

- `OK` — ошибок по модели не найдено;
- `ЗАВИСАНИЕ` — AutoSync не завершил обработку модели минимум три раза;
- `ОШИБКА` — в логе найдена ошибка выбранного GUID;
- `НЕТ КЭША` — запись базы есть, каталога GUID нет;
- `БЕЗ ЗАПИСИ БД` — каталог GUID есть, привязки к HostNode нет.

Revit Server хранит в локальной базе Accelerator GUID и HostNode, но не читаемое имя RVT. Поэтому основной идентификатор в первой версии — GUID из `AutoSyncLog` и каталога `Cache`.

## Требования

- Windows Server 2016/2019/2022/2025 или совместимая Windows;
- Windows PowerShell 5.1;
- Autodesk Revit Server Accelerator;
- права администратора для ремонта;
- модуль IIS `WebAdministration`;
- доступ к `raw.githubusercontent.com` для запуска с GitHub.

Без прав администратора интерфейс работает в режиме просмотра.

## Резервные копии

```text
%ProgramData%\RevitServer-Synx\Repair_<GUID>_<дата>
```

Карантин располагается рядом с экземпляром Revit Server:

```text
%ProgramData%\Autodesk\Revit Server 2022\SynxQuarantine
```

Не удаляйте карантин до успешной проверки открытия и синхронизации модели.

Кэш не дублируется в папку резервной копии. Каталог выбранного GUID только перемещается на том же диске, поэтому операция выполняется быстро и не требует места для второй копии модели.

## Проверка после ремонта

1. Нажмите **«Прочитать логи и базы»** повторно.
2. Откройте модель через Accelerator.
3. Выполните синхронизацию с центральной моделью.
4. Убедитесь, что в новом фрагменте `AutoSyncLog.log` нет повторяющегося зависания этого GUID.
5. После проверки можно удалить старый каталог из `SynxQuarantine`.

## Лицензия

MIT
