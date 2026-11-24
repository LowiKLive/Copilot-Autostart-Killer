#Requires -Version 5.1
<#
==============================================================================
  Copilot Autostart Killer  -  ПРОВЕРКА СТАТУСА
  Показывает, включён ли автозапуск Microsoft Copilot прямо сейчас.

  By LowiKLive
==============================================================================
  Скрипт только ЧИТАЕТ настройки. Ничего не меняет.
  Права администратора не нужны.
==============================================================================
#>

[CmdletBinding()]
param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$Script:Brand = 'By LowiKLive'
$Script:TaskName = 'CopilotAutostartGuard'

function Exit-Script {
    param([int]$Code = 0)
    if (-not $NoPause) {
        Write-Host ''
        Read-Host 'Нажмите Enter, чтобы закрыть окно'
    }
    exit $Code
}

function Convert-StateName {
    param($State)
    if ($null -eq $State) { return 'не зарегистрирована' }
    switch ([int]$State) {
        0 { return 'ВЫКЛЮЧЕНА (Disabled)' }
        1 { return 'ВЫКЛЮЧЕНА (пользователем)' }
        2 { return 'ВКЛЮЧЕНА (автозапуск работает!)' }
        3 { return 'ВЫКЛЮЧЕНА (запрет политикой)' }
        4 { return 'ВКЛЮЧЕНА (политикой!)' }
        5 { return 'ВЫКЛЮЧЕНА (пользователем + политикой)' }
        default { return "неизвестное состояние ($State)" }
    }
}

function Get-CopilotStartupTasks {
    $base = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    $result = @()
    $families = @()

    try {
        foreach ($a in (Get-AppxPackage -ErrorAction SilentlyContinue)) {
            if ($a.PackageFamilyName -and ($a.Name -match 'Copilot|OfficeHub')) {
                $families += $a.PackageFamilyName
            }
        }
    } catch { }

    if (Test-Path $base) {
        foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
            if ($k.PSChildName -match 'Copilot|OfficeHub') { $families += $k.PSChildName }
        }
    }

    $families = @($families | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($fam in $families) {
        $famPath = Join-Path $base $fam
        if (-not (Test-Path $famPath)) { continue }
        foreach ($sub in Get-ChildItem $famPath -ErrorAction SilentlyContinue) {
            try {
                $k = Get-Item $sub.PSPath
                if ($k.GetValueNames() -contains 'State') {
                    $result += [pscustomobject]@{
                        Family = $fam
                        TaskId = $sub.PSChildName
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
Write-Host '  Copilot Autostart Killer  -  ПРОВЕРКА СТАТУСА' -ForegroundColor Cyan
Write-Host "  $Script:Brand" -ForegroundColor DarkCyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

# --- Приложение установлено? ---------------------------------------------
Write-Host 'Приложение Copilot:' -ForegroundColor White
$app = $null
try {
    $app = Get-AppxPackage -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'Copilot|OfficeHub' } |
           Select-Object -First 1
} catch { }

if ($app) {
    Write-Host ("  Установлено: {0}" -f $app.PackageFullName) -ForegroundColor Gray
} else {
    Write-Host '  Не найдено (или запрос пакетов недоступен)' -ForegroundColor Gray
}
Write-Host ''

# --- Задача автозапуска ---------------------------------------------------
Write-Host 'Скрытая задача автозапуска:' -ForegroundColor White
$tasks = Get-CopilotStartupTasks
if (@($tasks).Count -eq 0) {
    Write-Host '  Задач автозапуска Copilot не найдено.' -ForegroundColor Gray
}
foreach ($t in $tasks) {
    $stateName = Convert-StateName $t.State
    $color = if ($t.State -eq 2 -or $t.State -eq 4) { 'Red' } elseif ($t.State -eq 3 -or $t.State -eq 0 -or $t.State -eq 5) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0}\{1}" -f $t.Family, $t.TaskId) -ForegroundColor Gray
    Write-Host ("     State = {0}  ->  {1}" -f $t.State, $stateName) -ForegroundColor $color
}
Write-Host ''

# --- Сторож ---------------------------------------------------------------
Write-Host 'Сторож в Планировщике задач:' -ForegroundColor White
$guard = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
if ($guard) {
    $info = Get-ScheduledTaskInfo -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    Write-Host ("  {0}  ->  {1}" -f $Script:TaskName, $guard.State) -ForegroundColor Green
    if ($info) {
        Write-Host ("     Последний запуск: {0}" -f $info.LastRunTime) -ForegroundColor Gray
    }
} else {
    Write-Host '  Не установлен' -ForegroundColor Yellow
}
Write-Host ''

# --- Политики -------------------------------------------------------------
Write-Host 'Политики Windows:' -ForegroundColor White
$checks = @(
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot' },
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot' },
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsAI';      Name = 'TurnOffWindowsCopilot' }
)
foreach ($c in $checks) {
    $val = $null
    if (Test-Path $c.Path) {
        try { $val = (Get-ItemProperty -Path $c.Path -Name $c.Name -ErrorAction SilentlyContinue).$($c.Name) } catch { }
    }
    $short = $c.Path -replace '^.*\\Policies\\', ''
    if ($val -eq 1) {
        Write-Host ("  {0}\{1} = 1" -f $short, $c.Name) -ForegroundColor Green
    } else {
        Write-Host ("  {0}\{1} = {2}" -f $short, $c.Name, $val) -ForegroundColor Yellow
    }
}
Write-Host ''

# --- Процессы -------------------------------------------------------------
Write-Host 'Запущенные процессы Copilot:' -ForegroundColor White
$procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'copilot' })
if ($procs.Count -eq 0) {
    Write-Host '  нет' -ForegroundColor Gray
} else {
    foreach ($p in $procs) {
        Write-Host ("  {0} (PID {1})" -f $p.ProcessName, $p.Id) -ForegroundColor Gray
    }
}
Write-Host ''

# --- Вердикт --------------------------------------------------------------
$enabled = @($tasks | Where-Object { $_.State -eq 2 -or $_.State -eq 4 })
Write-Host '============================================================' -ForegroundColor Cyan
if ($enabled.Count -gt 0) {
    Write-Host '  АВТОЗАПУСК ВКЛЮЧЁН - Copilot будет стартовать сам.' -ForegroundColor Red
    Write-Host '  Запустите: 1_Отключить_автозапуск_Copilot.bat' -ForegroundColor Yellow
} elseif (@($tasks).Count -eq 0) {
    if ($app) {
        Write-Host '  Задача автозапуска не зарегистрирована.' -ForegroundColor Green
        Write-Host '  Приложение установлено, но автозапуска сейчас нет.' -ForegroundColor Gray
    } else {
        Write-Host '  Copilot не установлен - автозапуска нет.' -ForegroundColor Green
    }
} else {
    Write-Host '  Автозапуск ВЫКЛЮЧЕН. Copilot сам не запустится.' -ForegroundColor Green
}
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  $Script:Brand" -ForegroundColor DarkCyan

Exit-Script 0
