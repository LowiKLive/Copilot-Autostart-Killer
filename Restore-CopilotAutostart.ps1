#Requires -Version 5.1
<#
==============================================================================
  Copilot Autostart Killer  -  ОТКАТ ИЗМЕНЕНИЙ
  Возвращает автозапуск Microsoft Copilot в исходное состояние и
  убирает сторожа из Планировщика задач.

  By LowiKLive
==============================================================================
  Что делает скрипт:
   1. Читает резервную копию, которую сохранил скрипт отключения
      (%LOCALAPPDATA%\CopilotAutostartGuard\backup.json).
   2. Удаляет задачу сторожа "CopilotAutostartGuard" и его папку.
   3. Возвращает задаче автозапуска Copilot ТО САМОЕ состояние,
      которое было до запуска скрипта отключения.
   4. Возвращает политики "TurnOffWindowsCopilot" к исходным значениям
      (если их не было - удаляет).

  Если резервной копии нет, скрипт честно сбрасывает автозапуск
  в состояние Windows по умолчанию (включено) и сообщает об этом.

  ВНИМАНИЕ: после отката Copilot снова будет запускаться сам при входе.
==============================================================================
#>

[CmdletBinding()]
param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$Script:Brand = 'By LowiKLive'
$Script:TaskName = 'CopilotAutostartGuard'
$Script:GuardDir = Join-Path $env:LOCALAPPDATA 'CopilotAutostartGuard'
$Script:BackupPath = Join-Path $Script:GuardDir 'backup.json'

function Exit-Script {
    param([int]$Code = 0)
    if (-not $NoPause) {
        Write-Host ''
        Read-Host 'Нажмите Enter, чтобы закрыть окно'
    }
    exit $Code
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-InteractiveUserName {
    try {
        $sid = (Get-Process -Id $PID).SessionId
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop
        foreach ($pr in $procs) {
            if ($pr.SessionId -ne $sid) { continue }
            try {
                $owner = Invoke-CimMethod -InputObject $pr -MethodName GetOwner -ErrorAction Stop
                if ($owner -and $owner.User) { return ("{0}\{1}" -f $owner.Domain, $owner.User) }
            } catch { }
        }
    } catch { }
    return $null
}

function Test-SameUser {
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $interactive = Get-InteractiveUserName
    if (-not $interactive) {
        Write-Host '  [!]    Не удалось определить пользователя активной сессии - продолжаю.' -ForegroundColor Yellow
        return $true
    }
    if ($interactive -ne $me) {
        Write-Host ''
        Write-Host "  [X]    Запущено под ДРУГИМ администратором ($me), а за ПК - $interactive." -ForegroundColor Red
        Write-Host '  В этом режиме откат затронул бы чужой профиль.' -ForegroundColor Yellow
        Write-Host '  Войдите в Windows под своим аккаунтом и запустите ещё раз.' -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Get-CopilotFamilyNames {
    $base = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    $families = @()
    try {
        foreach ($a in (Get-AppxPackage -ErrorAction SilentlyContinue)) {
            if ($a.PackageFamilyName -and ($a.Name -match 'Copilot|OfficeHub')) { $families += $a.PackageFamilyName }
        }
    } catch { }
    if (Test-Path $base) {
        foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
            if ($k.PSChildName -match 'Copilot|OfficeHub') { $families += $k.PSChildName }
        }
    }
    return @($families | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-CopilotStartupTasks {
    $base = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    $result = @()
    foreach ($fam in (Get-CopilotFamilyNames)) {
        $famPath = Join-Path $base $fam
        if (-not (Test-Path $famPath)) { continue }
        foreach ($sub in Get-ChildItem $famPath -ErrorAction SilentlyContinue) {
            try {
                $k = Get-Item $sub.PSPath
                if ($k.GetValueNames() -contains 'State') {
                    $result += [pscustomobject]@{
                        Family = $fam
                        TaskId = $sub.PSChildName
                        Path   = $sub.PSPath
                        State  = [int]$k.GetValue('State')
                    }
                }
            } catch { }
        }
    }
    return $result
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Copilot Autostart Killer  -  ОТКАТ ИЗМЕНЕНИЙ' -ForegroundColor Cyan
Write-Host "  $Script:Brand" -ForegroundColor DarkCyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Admin)) {
    Write-Host '  Нужны права администратора. Запрашиваю UAC...' -ForegroundColor Gray
    try {
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "  Не удалось получить права администратора: $($_.Exception.Message)" -ForegroundColor Red
        Exit-Script 1
    }
    exit 0
}

if (-not (Test-SameUser)) {
    Exit-Script 1
}

$failures = 0

# --- 0. Резервная копия (читать ДО удаления папки) -----------------------
$backup = $null
$hasBackup = $false
if (Test-Path $Script:BackupPath) {
    try {
        $backup = Get-Content -Path $Script:BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hasBackup = $true
        Write-Host '  [..]   Найдена резервная копия исходного состояния' -ForegroundColor Gray
    } catch {
        Write-Host "  [!]    Резервная копия повреждена: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host '  [..]   Резервной копии нет - будет сброс к состоянию по умолчанию' -ForegroundColor Gray
}

# --- Следов работы набора нет? Тогда вообще ничего не трогаем ------------
$guardTaskExisted = $false
if (Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue) {
    $guardTaskExisted = $true
}

if ((-not $hasBackup) -and (-not $guardTaskExisted) -and (-not (Test-Path $Script:GuardDir))) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  Следов работы набора не найдено - откатывать нечего.' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Настройки Copilot и политики Windows НЕ изменялись.' -ForegroundColor Gray
    Write-Host "  $Script:Brand" -ForegroundColor DarkCyan
    Exit-Script 0
}
Write-Host ''

# --- 1. Сторож ------------------------------------------------------------
Write-Host '1) Удаляю сторожа из Планировщика задач...' -ForegroundColor White
if ($guardTaskExisted) {
    try {
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "  [OK]   Задача $Script:TaskName удалена" -ForegroundColor Green
    } catch {
        Write-Host "  [X]    Не удалось удалить задачу: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }
} else {
    Write-Host '  [..]   Задачи сторожа нет (уже удалена)' -ForegroundColor Gray
}

if (Test-Path $Script:GuardDir) {
    try {
        # backup.json НЕ удаляем: иначе повторный откат "забудет" исходное
        # состояние и включит автозапуск. Убираем только файлы сторожа.
        Get-ChildItem -Path $Script:GuardDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'backup.json' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        Write-Host "  [OK]   Файлы сторожа удалены (резервная копия сохранена)" -ForegroundColor Green
    } catch {
        Write-Host "  [!]    Не удалось удалить файлы сторожа: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host ''

# --- 2. Задача автозапуска -> исходное состояние -------------------------
Write-Host '2) Возвращаю автозапуск Copilot...' -ForegroundColor White
$tasks = Get-CopilotStartupTasks
if (@($tasks).Count -eq 0) {
    Write-Host '  [..]   Задач автозапуска Copilot не найдено' -ForegroundColor Gray
}
foreach ($t in $tasks) {
    $b = $null
    if ($hasBackup -and $backup.Tasks) {
        $b = @($backup.Tasks) | Where-Object { $_.Family -eq $t.Family -and $_.TaskId -eq $t.TaskId } | Select-Object -First 1
    }

    try {
        if ($b) {
            if (-not $b.Existed) {
                # до скрипта ключа не было - убираем созданный нами
                Remove-Item -Path $t.Path -Recurse -Force -ErrorAction Stop
                Write-Host ("  [OK]   {0}\{1}: ключ удалён (до скрипта его не было)" -f $t.Family, $t.TaskId) -ForegroundColor Green
            } else {
                $orig = $b.State
                if ($null -eq $orig) { $orig = 2 }
                New-ItemProperty -Path $t.Path -Name 'State' -Value ([int]$orig) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                if ($null -ne $b.UserEnabledStartupOnce) {
                    New-ItemProperty -Path $t.Path -Name 'UserEnabledStartupOnce' -Value ([int]$b.UserEnabledStartupOnce) -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                }
                Write-Host ("  [OK]   {0}\{1}: State = {2} (исходное значение)" -f $t.Family, $t.TaskId, [int]$orig) -ForegroundColor Green
            }
        } else {
            # копии нет - честно ставим состояние Windows по умолчанию
            New-ItemProperty -Path $t.Path -Name 'State' -Value 2 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $t.Path -Name 'UserEnabledStartupOnce' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Host ("  [OK]   {0}\{1}: State = 2 (по умолчанию, исходное значение неизвестно)" -f $t.Family, $t.TaskId) -ForegroundColor Yellow
        }
    } catch {
        Write-Host ("  [X]    {0}\{1}: {2}" -f $t.Family, $t.TaskId, $_.Exception.Message) -ForegroundColor Red
        $failures++
    }
}
Write-Host ''

# --- 3. Политики -> исходные значения ------------------------------------
Write-Host '3) Возвращаю политики Windows...' -ForegroundColor White
$pols = @(
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot' },
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot' },
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsAI';      Name = 'TurnOffWindowsCopilot' }
)
foreach ($p in $pols) {
    $short = $p.Path -replace '^.*\\Policies\\', ''
    $b = $null
    if ($hasBackup -and $backup.Policies) {
        $b = @($backup.Policies) | Where-Object { $_.Path -eq $p.Path -and $_.Name -eq $p.Name } | Select-Object -First 1
    }
    try {
        if ($b) {
            if ($b.Existed) {
                if (-not (Test-Path $p.Path)) { New-Item -Path $p.Path -Force | Out-Null }
                New-ItemProperty -Path $p.Path -Name $p.Name -Value ([int]$b.Value) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                Write-Host ("  [OK]   {0}\{1} = {2} (исходное значение)" -f $short, $p.Name, [int]$b.Value) -ForegroundColor Green
            } else {
                if (Test-Path $p.Path) {
                    Remove-ItemProperty -Path $p.Path -Name $p.Name -Force -ErrorAction SilentlyContinue
                }
                Write-Host ("  [OK]   {0}\{1} удалено (до скрипта не задавалось)" -f $short, $p.Name) -ForegroundColor Green
            }
        } else {
            # копии нет - убираем то, что ставили
            if (Test-Path $p.Path) {
                $cur = (Get-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction SilentlyContinue).$($p.Name)
                if ($null -ne $cur) {
                    Remove-ItemProperty -Path $p.Path -Name $p.Name -Force -ErrorAction Stop
                    Write-Host ("  [OK]   {0}\{1} удалено" -f $short, $p.Name) -ForegroundColor Green
                } else {
                    Write-Host ("  [..]   {0}\{1} не задано" -f $short, $p.Name) -ForegroundColor Gray
                }
            }
        }
    } catch {
        Write-Host ("  [!]    Не удалось вернуть {0}: {1}" -f $p.Name, $_.Exception.Message) -ForegroundColor Yellow
        $failures++
    }
}
Write-Host ''

# --- Итог -----------------------------------------------------------------
Write-Host '============================================================' -ForegroundColor Cyan
if ($failures -eq 0) {
    if ($hasBackup) {
        Write-Host '  ОТКАТ ВЫПОЛНЕН. Восстановлено исходное состояние.' -ForegroundColor Yellow
    } else {
        Write-Host '  ОТКАТ ВЫПОЛНЕН. Автозапуск сброшен к состоянию по умолчанию.' -ForegroundColor Yellow
    }
} else {
    Write-Host '  Откат выполнен частично, были ошибки (см. выше).' -ForegroundColor Yellow
}
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
$finalTasks = Get-CopilotStartupTasks
$finalEnabled = @($finalTasks | Where-Object { $_.State -eq 2 -or $_.State -eq 4 })
if ($finalEnabled.Count -gt 0) {
    Write-Host '  Автозапуск включён - Copilot будет запускаться сам при входе.' -ForegroundColor Gray
    Write-Host '  Чтобы снова отключить: 1_Отключить_автозапуск_Copilot.bat' -ForegroundColor DarkGray
} else {
    Write-Host '  Автозапуск остался ВЫКЛЮЧЕННЫМ (как и был до скрипта).' -ForegroundColor Gray
    Write-Host '  Copilot сам запускаться не будет.' -ForegroundColor Gray
}
Write-Host ''
Write-Host "  $Script:Brand" -ForegroundColor DarkCyan

if ($failures -gt 0) {
    Exit-Script 1
} else {
    Exit-Script 0
}
