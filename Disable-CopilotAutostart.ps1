#Requires -Version 5.1
<#
==============================================================================
  Copilot Autostart Killer
  Полное отключение Microsoft Copilot из автозагрузки Windows
  (БЕЗ удаления самого приложения)

  By LowiKLive
==============================================================================
  ПОЧЕМУ ЭТОТ СКРИПТ ВООБЩЕ НУЖЕН:
  Приложение Copilot ставит себя в автозагрузку через скрытый механизм
  Windows "startup task" (windows.startupTask в манифесте пакета).
  Поэтому его часто НЕ видно ни в папке "Автозагрузка", ни в Run-ключах
  реестра, ни в Планировщике задач - и обычным способом его не выключить.

  ЧТО ДЕЛАЕТ СКРИПТ:
   1. Находит эту скрытую задачу автозапуска Copilot.
   2. Переводит её в состояние DisabledByPolicy (State = 3) -
      это не "выключено пользователем", а принудительный запрет.
   3. Включает политику Windows "Turn off Windows Copilot".
   4. Ставит в Планировщик задач маленький "сторож", который при каждом
      входе в систему возвращает запрет, если обновление Copilot
      снова включит автозапуск.

  ЧЕГО СКРИПТ НЕ ДЕЛАЕТ:
   - НЕ удаляет приложение Copilot (оно остаётся установленным
     и запускается вручную как обычно).
   - НЕ трогает другие программы и их автозагрузку.
   - НЕ отправляет никаких данных в интернет.

  Перед изменениями скрипт сохраняет исходные значения в
  %LOCALAPPDATA%\CopilotAutostartGuard\backup.json - чтобы
  "3_Вернуть_как_было.bat" вернул именно то, что было.

  Нужны права администратора - скрипт сам запросит UAC.
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
$Script:GuardPs1 = Join-Path $Script:GuardDir 'guard.ps1'
$Script:BackupPath = Join-Path $Script:GuardDir 'backup.json'

# ---------------------------------------------------------------------------
#  Вывод
# ---------------------------------------------------------------------------
function Write-Header {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  Copilot Autostart Killer' -ForegroundColor Cyan
    Write-Host '  Полное отключение Microsoft Copilot из автозагрузки' -ForegroundColor Cyan
    Write-Host "  $Script:Brand" -ForegroundColor DarkCyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Ok    { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Info  { param($m) Write-Host "  [..]   $m" -ForegroundColor Gray }
function Write-Warn2 { param($m) Write-Host "  [!]    $m" -ForegroundColor Yellow }
function Write-Err2  { param($m) Write-Host "  [X]    $m" -ForegroundColor Red }

function Exit-Script {
    param([int]$Code = 0)
    if (-not $NoPause) {
        Write-Host ''
        Read-Host 'Нажмите Enter, чтобы закрыть окно'
    }
    exit $Code
}

# ---------------------------------------------------------------------------
#  Права администратора
# ---------------------------------------------------------------------------
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
#  Кто на самом деле сидит за компьютером
#  Нужно, чтобы не отрапортовать "ГОТОВО" чужому администратору:
#  при вводе логина/пароля ДРУГОГО админа в UAC все HKCU-изменения
#  ушли бы в чужой профиль, а у пользователя автозапуск остался бы включён.
# ---------------------------------------------------------------------------
function Get-InteractiveUserName {
    try {
        $sid = (Get-Process -Id $PID).SessionId
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop
        foreach ($pr in $procs) {
            if ($pr.SessionId -ne $sid) { continue }
            try {
                $owner = Invoke-CimMethod -InputObject $pr -MethodName GetOwner -ErrorAction Stop
                if ($owner -and $owner.User) {
                    return ("{0}\{1}" -f $owner.Domain, $owner.User)
                }
            } catch { }
        }
    } catch { }
    return $null
}

function Test-SameUser {
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $interactive = Get-InteractiveUserName

    if (-not $interactive) {
        Write-Warn2 'Не удалось определить пользователя активной сессии - продолжаю без этой проверки.'
        return $true
    }
    if ($interactive -ne $me) {
        Write-Host ''
        Write-Err2 'Запущено под ДРУГИМ администратором!'
        Write-Host ''
        Write-Info ("  Текущий пользователь : {0}" -f $me)
        Write-Info ("  Пользователь за ПК   : {0}" -f $interactive)
        Write-Host ''
        Write-Host '  В окне UAC вы ввели логин/пароль другого администратора.' -ForegroundColor Yellow
        Write-Host '  В этом режиме настройки ушли бы в чужой профиль,' -ForegroundColor Yellow
        Write-Host '  а у вас Copilot продолжал бы запускаться.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Что делать: войдите в Windows под своим аккаунтом' -ForegroundColor Yellow
        Write-Host '  и запустите скрипт ещё раз.' -ForegroundColor Yellow
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
#  Поиск задач автозапуска Copilot
#  Ищем только пакеты Copilot / OfficeHub и НЕ трогаем чужие startup-задачи
#  (например Claude или OpenAI.Codex).
# ---------------------------------------------------------------------------
function Get-CopilotFamilyNames {
    $families = @()
    $base = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'

    # 1) из установленных пакетов
    try {
        $apps = Get-AppxPackage -ErrorAction SilentlyContinue
        foreach ($a in $apps) {
            if ($a.PackageFamilyName -and ($a.Name -match 'Copilot|OfficeHub')) {
                $families += $a.PackageFamilyName
            }
        }
    } catch { }

    # 2) из реестра (на случай, если запрос пакетов недоступен)
    if (Test-Path $base) {
        try {
            foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
                if ($k.PSChildName -match 'Copilot|OfficeHub') {
                    $families += $k.PSChildName
                }
            }
        } catch { }
    }

    return @($families | Where-Object { $_ } | Sort-Object -Unique)
}

function Test-CopilotPackageInstalled {
    try {
        $apps = Get-AppxPackage -ErrorAction SilentlyContinue
        foreach ($a in $apps) {
            if ($a.Name -match 'Copilot|OfficeHub') { return $true }
        }
    } catch { }
    # запасной признак: файл приложения на месте
    if (Test-Path 'C:\Program Files (x86)\Microsoft\Copilot\Application\copilotapp.exe') { return $true }
    if (Test-Path 'C:\Program Files\Microsoft\Copilot\Application\copilotapp.exe') { return $true }
    return $false
}

function Get-ManifestTaskIds {
    param([string]$Family)
    $ids = @()
    try {
        $pkg = Get-AppxPackage -ErrorAction SilentlyContinue |
               Where-Object { $_.PackageFamilyName -eq $Family } |
               Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $m = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
            if (Test-Path $m) {
                $txt = Get-Content $m -Raw -ErrorAction SilentlyContinue
                if ($txt) {
                    # берём TaskId ТОЛЬКО из элемента StartupTask, а не откуда попало
                    $rx = '<[A-Za-z0-9]*:?StartupTask\b[^>]*?TaskId\s*=\s*"([^"]+)"'
                    foreach ($mm in [regex]::Matches($txt, $rx, 'IgnoreCase')) {
                        $ids += $mm.Groups[1].Value
                    }
                }
            }
        }
    } catch { }
    return @($ids | Sort-Object -Unique)
}

function Get-CopilotStartupTasks {
    $base = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    $result = @()

    foreach ($fam in (Get-CopilotFamilyNames)) {
        $famPath = Join-Path $base $fam
        $ids = @()

        # задачи, которые уже зарегистрированы в реестре
        if (Test-Path $famPath) {
            try {
                foreach ($sub in Get-ChildItem $famPath -ErrorAction SilentlyContinue) {
                    $k = Get-Item $sub.PSPath -ErrorAction SilentlyContinue
                    if ($k) {
                        $names = $k.GetValueNames()
                        if (($names -contains 'State') -or ($names -contains 'UserEnabledStartupOnce')) {
                            $ids += $sub.PSChildName
                        }
                    }
                }
            } catch { }
        }

        # если в реестре ещё нет - берём TaskId из манифеста пакета
        if (@($ids).Count -eq 0) {
            $ids = Get-ManifestTaskIds -Family $fam
        }
        # известный запасной вариант для Microsoft 365 Copilot
        if (@($ids).Count -eq 0 -and $fam -match 'OfficeHub') {
            $ids = @('WebViewHostStartupId')
        }

        foreach ($id in ($ids | Sort-Object -Unique)) {
            $path = Join-Path $famPath $id
            $state = $null
            $uev = $null
            $exists = Test-Path $path
            if ($exists) {
                try {
                    $v = (Get-Item $path).GetValue('State')
                    if ($null -ne $v) { $state = [int]$v }
                    $v2 = (Get-Item $path).GetValue('UserEnabledStartupOnce')
                    if ($null -ne $v2) { $uev = [int]$v2 }
                } catch { }
            }
            $result += [pscustomobject]@{
                Family = $fam
                TaskId = $id
                Path   = $path
                Exists = $exists
                State  = $state
                UserEnabledStartupOnce = $uev
            }
        }
    }

    return $result
}

function Convert-StateName {
    param($State)
    if ($null -eq $State) { return 'не зарегистрирована' }
    switch ([int]$State) {
        0 { return 'Disabled (выключена)' }
        1 { return 'DisabledByUser (выключена пользователем)' }
        2 { return 'ENABLED (включена!)' }
        3 { return 'DisabledByPolicy (запрещена политикой)' }
        4 { return 'EnabledByPolicy (включена политикой!)' }
        5 { return 'DisabledByUser+Policy (выключена)' }
        default { return "неизвестно ($State)" }
    }
}

# ---------------------------------------------------------------------------
#  Резервная копия исходного состояния
#  Пишется только один раз, чтобы повторный запуск не затёр "как было".
# ---------------------------------------------------------------------------
function Save-Backup {
    param($Tasks, $PolicyStates)

    if (Test-Path $Script:BackupPath) {
        Write-Info "Резервная копия уже есть: $Script:BackupPath"
        return $true
    }

    try {
        if (-not (Test-Path $Script:GuardDir)) {
            New-Item -ItemType Directory -Path $Script:GuardDir -Force -ErrorAction Stop | Out-Null
        }

        $taskBackup = @()
        foreach ($t in $Tasks) {
            $taskBackup += [pscustomobject]@{
                Family = $t.Family
                TaskId = $t.TaskId
                Existed = [bool]$t.Exists
                State = $t.State
                UserEnabledStartupOnce = $t.UserEnabledStartupOnce
            }
        }

        $obj = [pscustomobject]@{
            Created = (Get-Date -Format 's')
            Brand   = $Script:Brand
            Tasks   = @($taskBackup)
            Policies = @($PolicyStates)
        }

        $json = $obj | ConvertTo-Json -Depth 6
        Set-Content -Path $Script:BackupPath -Value $json -Encoding UTF8 -ErrorAction Stop
        Write-Ok "Исходное состояние сохранено: $Script:BackupPath"
        return $true
    } catch {
        Write-Warn2 "Не удалось сохранить резервную копию: $($_.Exception.Message)"
        return $false
    }
}

function Get-PolicyStates {
    $result = @()
    $items = @(
        @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot' },
        @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot' },
        @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsAI';      Name = 'TurnOffWindowsCopilot' }
    )
    foreach ($it in $items) {
        $existed = $false
        $val = $null
        if (Test-Path $it.Path) {
            try {
                $v = (Get-ItemProperty -Path $it.Path -Name $it.Name -ErrorAction SilentlyContinue).$($it.Name)
                if ($null -ne $v) { $existed = $true; $val = [int]$v }
            } catch { }
        }
        $result += [pscustomobject]@{
            Path    = $it.Path
            Name    = $it.Name
            Existed = $existed
            Value   = $val
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
#  Установка запрета
# ---------------------------------------------------------------------------
function Set-StartupTaskDisabled {
    param($Task)

    $before = $Task.State
    $path = $Task.Path

    if (-not (Test-Path $path)) {
        try {
            New-Item -Path $path -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Err2 "Не удалось создать ключ: $path"
            return $false
        }
    }

    try {
        New-ItemProperty -Path $path -Name 'State' -Value 3 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $path -Name 'UserEnabledStartupOnce' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Err2 "Не удалось записать State: $($_.Exception.Message)"
        return $false
    }

    $after = $null
    try { $after = [int](Get-Item $path).GetValue('State') } catch { }

    if ($after -eq 3) {
        Write-Ok ("Задача автозапуска: {0}\{1}" -f $Task.Family, $Task.TaskId)
        Write-Info ("     Было: {0}  ->  Стало: {1}" -f (Convert-StateName $before), (Convert-StateName $after))
        return $true
    }

    Write-Err2 ("Не удалось запретить {0}\{1} (State = {2})" -f $Task.Family, $Task.TaskId, $after)
    return $false
}

function Set-PolicyValue {
    param([string]$Path, [string]$Name, [int]$Value)
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Err2 "Политика $Name : $($_.Exception.Message)"
        return $false
    }
}

# ---------------------------------------------------------------------------
#  Сторож (переустанавливает запрет при каждом входе в систему)
# ---------------------------------------------------------------------------
$Script:GuardCode = @'
# ==========================================================================
#  Copilot Autostart Guard  -  By LowiKLive
#  Runs at user logon. Re-applies "disabled by policy" to the Copilot
#  windows.startupTask in case an app update turns autostart back on.
#  State: 0=Disabled, 1=DisabledByUser, 2=Enabled, 3=DisabledByPolicy,
#         4=EnabledByPolicy, 5=DisabledByUser+Policy
#  Note: only fixes startup tasks that already exist; never creates new ones.
# ==========================================================================
$ErrorActionPreference = 'Continue'
$base = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
$log  = Join-Path $env:LOCALAPPDATA 'CopilotAutostartGuard\guard.log'
$Want = 3

function Log([string]$m) {
    try {
        $dir = Split-Path -Parent $log
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $log -Value ((Get-Date -Format 's') + ' - ' + $m) -ErrorAction SilentlyContinue
    } catch { }
}

try {
    $families = @()
    if (Test-Path $base) {
        foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
            if ($k.PSChildName -match 'Copilot|OfficeHub') { $families += $k.PSChildName }
        }
    }
    try {
        foreach ($a in (Get-AppxPackage -ErrorAction SilentlyContinue)) {
            if ($a.PackageFamilyName -and ($a.Name -match 'Copilot|OfficeHub')) {
                $families += $a.PackageFamilyName
            }
        }
    } catch { }

    $families = @($families | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($fam in $families) {
        $famPath = Join-Path $base $fam
        if (-not (Test-Path $famPath)) { continue }

        foreach ($sub in Get-ChildItem $famPath -ErrorAction SilentlyContinue) {
            try {
                $names = (Get-Item $sub.PSPath).GetValueNames()
                if (-not ($names -contains 'State')) { continue }

                $cur = (Get-Item $sub.PSPath).GetValue('State')
                if ($cur -ne $Want) {
                    New-ItemProperty -Path $sub.PSPath -Name 'State' -Value $Want -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                    New-ItemProperty -Path $sub.PSPath -Name 'UserEnabledStartupOnce' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                    Log ('forced ' + $fam + '\' + $sub.PSChildName + ' State ' + $cur + ' -> ' + $Want)
                }
            } catch {
                Log ('ERROR ' + $fam + '\' + $sub.PSChildName + ': ' + $_.Exception.Message)
            }
        }
    }
} catch {
    Log ('FATAL: ' + $_.Exception.Message)
}
'@

function Install-Guard {
    try {
        if (-not (Test-Path $Script:GuardDir)) {
            New-Item -ItemType Directory -Path $Script:GuardDir -Force -ErrorAction Stop | Out-Null
        }
        Set-Content -Path $Script:GuardPs1 -Value $Script:GuardCode -Encoding UTF8 -ErrorAction Stop
        Write-Ok "Сторож скопирован: $Script:GuardPs1"
    } catch {
        Write-Err2 "Не удалось записать сторожа: $($_.Exception.Message)"
        return $false
    }

    $user = "$env:USERDOMAIN\$env:USERNAME"
    try {
        $existing = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction Stop
        }

        $argument = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Script:GuardPs1
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $Script:TaskName `
            -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description "By LowiKLive - keeps Microsoft Copilot autostart disabled" `
            -ErrorAction Stop | Out-Null

        Write-Ok "Сторож установлен в Планировщик задач: $Script:TaskName"
        return $true
    } catch {
        Write-Err2 "Не удалось поставить сторожа: $($_.Exception.Message)"
        return $false
    }
}

# ===========================================================================
#  НАЧАЛО
# ===========================================================================
Write-Header

if (-not (Test-Admin)) {
    Write-Info 'Нужны права администратора. Запрашиваю UAC...'
    try {
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine -ErrorAction Stop | Out-Null
    } catch {
        Write-Err2 "Не удалось получить права администратора: $($_.Exception.Message)"
        Write-Host ''
        Write-Host '  Запустите файл 1_Отключить_автозапуск_Copilot.bat' -ForegroundColor Yellow
        Write-Host '  и нажмите "Да" в окне UAC.' -ForegroundColor Yellow
        Exit-Script 1
    }
    exit 0
}

# Защита от запуска под чужим администратором
if (-not (Test-SameUser)) {
    Exit-Script 1
}

$failures = 0

# --- 0. Что вообще есть на машине? ---------------------------------------
$installed = Test-CopilotPackageInstalled
$tasks = Get-CopilotStartupTasks
$taskCount = @($tasks).Count

if ((-not $installed) -and ($taskCount -eq 0)) {
    Write-Warn2 'Microsoft Copilot на этом компьютере не найден.'
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  НЕЧЕГО ОТКЛЮЧАТЬ - Copilot не установлен.' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Ничего в системе не менялось.' -ForegroundColor Gray
    Write-Host "  $Script:Brand" -ForegroundColor DarkCyan
    Exit-Script 0
}

# --- 1. Задача автозапуска ------------------------------------------------
Write-Host '1) Ищу скрытую задачу автозапуска Copilot...' -ForegroundColor White
Write-Host ''

# Резервная копия ДО любых изменений (даже если задача ещё не появилась)
$policyStates = Get-PolicyStates
if (-not (Save-Backup -Tasks $tasks -PolicyStates $policyStates)) {
    Write-Host ''
    Write-Err2 'Не удалось сохранить исходное состояние - изменения ОТМЕНЕНЫ.'
    Write-Info 'Скрипт не будет менять настройки, иначе откат станет невозможен.'
    Exit-Script 1
}

if ($taskCount -eq 0) {
    Write-Warn2 'Приложение Copilot установлено, но задача автозапуска не зарегистрирована.'
    Write-Info 'Похоже, Copilot ещё ни разу не запускался. Сторож включится,'
    Write-Info 'как только задача появится.'
} else {
    Write-Host ''

    foreach ($t in $tasks) {
        if (-not (Set-StartupTaskDisabled -Task $t)) { $failures++ }
    }
}

Write-Host ''
Write-Host '2) Включаю политику Windows "Turn off Windows Copilot"...' -ForegroundColor White
Write-Host ''

$policyOk = 0
if (Set-PolicyValue -Path 'HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1) { $policyOk++ }
if (Set-PolicyValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1) { $policyOk++ }
if (Set-PolicyValue -Path 'HKLM:\Software\Policies\Microsoft\Windows\WindowsAI' -Name 'TurnOffWindowsCopilot' -Value 1) { $policyOk++ }

if ($policyOk -eq 3) {
    Write-Ok 'Политики Copilot применены (HKLM + HKCU)'
} else {
    Write-Warn2 "Применено политик: $policyOk из 3"
    $failures++
}

Write-Host ''
Write-Host '3) Ставлю сторож, чтобы обновления не вернули автозапуск...' -ForegroundColor White
Write-Host ''

if (-not (Install-Guard)) { $failures++ }

# --- Немедленный прогон сторожа ------------------------------------------
if ($failures -eq 0) {
    try {
        Start-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    } catch { }
}

# --- 4. Итоговая проверка -------------------------------------------------
Write-Host ''
Write-Host '4) Проверка результата...' -ForegroundColor White
Write-Host ''

$verify = Get-CopilotStartupTasks
$verifyCount = @($verify).Count
$allOk = $true

if ($verifyCount -eq 0) {
    Write-Info 'Задач автозапуска Copilot не найдено.'
} else {
    foreach ($v in $verify) {
        $stateText = Convert-StateName $v.State
        if ($v.State -eq 3) {
            Write-Ok ("{0}\{1}  ->  {2}" -f $v.Family, $v.TaskId, $stateText)
        } else {
            Write-Err2 ("{0}\{1}  ->  {2}" -f $v.Family, $v.TaskId, $stateText)
            $allOk = $false
        }
    }
}

$guardTask = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
if ($guardTask) {
    Write-Ok "Сторож в Планировщике: $($guardTask.State)"
} else {
    Write-Err2 'Сторож в Планировщике не найден'
    $allOk = $false
}

$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'copilot' })
if ($running.Count -gt 0) {
    Write-Info "Сейчас запущено процессов Copilot: $($running.Count) (это не влияет на автозапуск)"
}

# --- Финальное сообщение --------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
if ($allOk -and $failures -eq 0) {
    Write-Host '  ГОТОВО. Copilot больше не запускается сам.' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Приложение Copilot НЕ удалено - оно осталось на месте' -ForegroundColor Gray
    Write-Host '  и запускается вручную как обычно.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Перезагрузка не нужна. Сторож будет проверять' -ForegroundColor Gray
    Write-Host '  настройку при каждом входе в Windows.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Откатить изменения: 3_Вернуть_как_было.bat' -ForegroundColor DarkGray
    Write-Host "  $Script:Brand" -ForegroundColor DarkCyan
    Exit-Script 0
} else {
    Write-Host '  ВНИМАНИЕ: не всё применилось.' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Попробуйте запустить ещё раз от имени администратора.' -ForegroundColor Yellow
    Write-Host "  $Script:Brand" -ForegroundColor DarkCyan
    Exit-Script 1
}
