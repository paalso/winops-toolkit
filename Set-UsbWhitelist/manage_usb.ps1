<#
    .SYNOPSIS
        Автономный скрипт управления белыми списками USB-устройств.
    .DESCRIPTION
        Включает жесткую блокировку съемных дисков, формирует белый список,
        очищает кэш PnP-устройств и применяет групповые политики.
#>

# Проверка прав Администратора
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "КРИТИЧЕСКАЯ ОШИБКА: Этот скрипт должен быть запущен ОТ ИМЕНИ АДМИНИСТРАТОРА!"
    Pause
    Exit
}

# Определение путей (ищет папку USB_Lists в родительской директории)
$AutomationFolder = $PSScriptRoot
$USBListFolder = Join-Path (Split-Path $AutomationFolder -Parent) "USB_Lists"

# --- ОЧИСТКА БИНАРНОГО КЭША MMC (ИСПРАВЛЕНИЕ ЗА ТИРАНИЯ ПОЛИТИК) ---
$PolFile = "C:\Windows\System32\GroupPolicy\Machine\Registry.pol"
if (Test-Path $PolFile) {
    # Снимаем системные атрибуты, если они есть, и удаляем файл политик MMC
    Set-ItemProperty -Path $PolFile -Name Attributes -Value "Normal" -ErrorAction SilentlyContinue
    Remove-Item -Path $PolFile -Force -ErrorAction SilentlyContinue
    Write-Host " Старый файл конфигурации MMC (Registry.pol) успешно сброшен." -ForegroundColor Yellow
}
# ------------------------------------------------------------------



#=======================================================================
# 1. АВТООПРЕДЕЛЕНИЕ ТЕКУЩЕЙ ФЛЕШКИ (ЗАЩИТА ОТ САМОБЛОКИРОВКИ)
#=======================================================================
$ScriptDrive = Split-Path -Path $PSScriptRoot -Qualifier
$CurrentDriveInfo = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $ScriptDrive }

$SelfInstanceID = $null
if ($CurrentDriveInfo.DriveType -eq 2) {
    Write-Host "Скрипт запущен со съемного диска $ScriptDrive. Ищем его Instance ID..." -ForegroundColor Cyan
    
    $Partition = Get-CimInstance -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='$ScriptDrive'} WHERE ResultClass=Win32_DiskPartition"
    if ($Partition) {
        $DiskDrive = Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($Partition.DeviceID)'} WHERE ResultClass=Win32_DiskDrive"
        if ($DiskDrive) {
            $PnpID = $DiskDrive.PNPDeviceID
            if ($PnpID -match "USBSTOR") {
                $SelfInstanceID = $PnpID
                Write-Host "[ЗАЩИТА] Текущая рабочая флешка определена: $SelfInstanceID" -ForegroundColor Green
            }
        }
    }
}

if ($null -eq $SelfInstanceID) {
    Write-Host "[КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ] Не удалось определить ID текущей флешки! Она МОЖЕТ БЫТЬ ЗАБЛОКИРОВАНА!" -ForegroundColor Red
}

#=======================================================================
# 2. ГЛАВНОЕ МЕНЮ ВЫБОРА
#=======================================================================
Write-Host "`n=== ГЛАВНОЕ МЕНЮ НАСТРОЙКИ USB ===" -ForegroundColor Cyan
Write-Host "[1] Добавить конкретное подключенное сейчас устройство в белый список"
Write-Host "[2] Импортировать разрешенные ID устройств из файла (.txt)"
Write-Host "=================================="

$MainMenuSelection = $null
while ($MainMenuSelection -notin @(1, 2)) {
    $UserChoice = Read-Host "Выберите вариант (1 или 2)"
    if ($UserChoice -match "^\d+$") { $MainMenuSelection = [int]$UserChoice }
}

$DevicesToAllow = @()

# ВАРИАНТ 1: Выбор из подключенных
if ($MainMenuSelection -eq 1) {
    $AllConnectedDisks = Get-PnpDevice -Class "DiskDrive" -Status "OK" | Where-Object { $_.InstanceId -match "USBSTOR" }
    
    $ConnectedDisks = @()
    foreach ($Disk in $AllConnectedDisks) {
        if ($null -ne $SelfInstanceID -and $Disk.InstanceId -eq $SelfInstanceID) { continue }
        $ConnectedDisks += $Disk
    }
    
    if ($ConnectedDisks.Count -eq 0) {
        Write-Host "`nДругие активные USB-накопители не найдены. Будет разрешена только текущая флешка." -ForegroundColor Yellow
    } else {
        Write-Host "`n--- Список других подключенных USB-устройств ---" -ForegroundColor Cyan
        for ($i = 0; $i -lt $ConnectedDisks.Count; $i++) {
            Write-Host "[$($i + 1)] $($ConnectedDisks[$i].FriendlyName) | ID: $($ConnectedDisks[$i].InstanceId)"
        }
        
        $DeviceSelection = $null
        while ($null -eq $DeviceSelection -or $DeviceSelection -lt 1 -or $DeviceSelection -gt $ConnectedDisks.Count) {
            $UserDevChoice = Read-Host "Выберите номер устройства для добавления в белый список (1-$($ConnectedDisks.Count))"
            if ($UserDevChoice -match "^\d+$") { $DeviceSelection = [int]$UserDevChoice }
        }
        $DevicesToAllow += $ConnectedDisks[$DeviceSelection - 1].InstanceId
    }
}
# ВАРИАНТ 2: Чтение из файла
else {
    if (!(Test-Path $USBListFolder)) {
        Write-Host "Ошибка: Папка '$USBListFolder' не найдена." -ForegroundColor Red
        Pause; Exit
    }

    $TxtFiles = Get-ChildItem -Path $USBListFolder -Filter "*.txt"
    if ($TxtFiles.Count -eq 0) {
        Write-Host "В папке '$USBListFolder' не найдено текстовых файлов." -ForegroundColor Red
        Pause; Exit
    }

    Write-Host "`n--- Доступные списки разрешенных устройств ---" -ForegroundColor Cyan
    for ($i = 0; $i -lt $TxtFiles.Count; $i++) {
        Write-Host "[$($i + 1)] $($TxtFiles[$i].Name)"
    }

    $FileSelection = $null
    while ($null -eq $FileSelection -or $FileSelection -lt 1 -or $FileSelection -gt $TxtFiles.Count) {
        $UserFileChoice = Read-Host "Выберите номер файла (1-$($TxtFiles.Count))"
        if ($UserFileChoice -match "^\d+$") { $FileSelection = [int]$UserFileChoice }
    }

    $SelectedFile = $TxtFiles[$FileSelection - 1]
    $FileContent = Get-Content -Path $SelectedFile.FullName | Where-Object { $_.Trim() -ne "" }
    
    if ($FileContent.Count -eq 0) {
        Write-Host "Ошибка: Выбранный файл пуст!" -ForegroundColor Red
        Pause; Exit
    }
    $DevicesToAllow += $FileContent
}

#=======================================================================
# 3. ВЫБОР РЕЖИМА: ОЧИСТИТЬ ИЛИ ДОПИСАТЬ
#=======================================================================
Write-Host "`n--- Режим применения политик ---" -ForegroundColor Cyan
Write-Host "[1] Очистить старый белый список и создать новый (Текущая флешка + выбор)"
Write-Host "[2] Сохранить старый белый список и дописать новые устройства"

$ModeSelection = $null
while ($ModeSelection -notin @(1, 2)) {
    $UserMode = Read-Host "Выберите режим (1 или 2)"
    if ($UserMode -match "^\d+$") { $ModeSelection = [int]$UserMode }
}
# =======================================================================
# 4. НАСТРОЙКА РЕЕСТРА И ПОЛИТИК БЛОКИРОВКИ
# =======================================================================
$RegistryPathPolicy = "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
$RegistryPathAllow  = "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Restrictions\AllowInstanceIDs"

if (!(Test-Path $RegistryPathPolicy)) { New-Item -Path $RegistryPathPolicy -Force | Out-Null }

# Сбор существующих ID (если выбран режим дополнения)
$ExistingIDs = @()
if ($ModeSelection -eq 2 -and (Test-Path $RegistryPathAllow)) {
    $ExistingProperties = Get-ItemProperty -Path $RegistryPathAllow -ErrorAction SilentlyContinue
    foreach ($Prop in $ExistingProperties.PSObject.Properties) {
        if ($Prop.Name -match "^\d+$") { $ExistingIDs += $Prop.Value }
    }
}

# --- ЖЕСТКОЕ ИСПРАВЛЕНИЕ БАГА ОБНОВЛЕНИЯ ---
# Полностью удаляем весь раздел со всеми старыми флешками
if (Test-Path $RegistryPathAllow) {
    Remove-Item -Path $RegistryPathAllow -Recurse -Force -ErrorAction SilentlyContinue
}
# Создаем раздел заново — теперь он гарантированно пустой!
New-Item -Path $RegistryPathAllow -Force | Out-Null
# -------------------------------------------

# Итоговый массив белого списка
$FinalAllowList = @()

# Текущая рабочая флешка ВСЕГДА идет первой (Защита)
if ($null -ne $SelfInstanceID) { $FinalAllowList += $SelfInstanceID.Trim() }

# Наполнение чистыми уникальными ID
foreach ($Id in ($ExistingIDs + $DevicesToAllow)) {
    $Clean = $Id.Trim()
    if ($Clean -notin $FinalAllowList) { $FinalAllowList += $Clean }
}

# Запись белого списка в реестр
$counter = 1
Write-Host "`nЗапись разрешенных устройств в реестр..." -ForegroundColor Yellow
foreach ($DeviceID in $FinalAllowList) {
    # Теперь запись пойдет в гарантированно чистый раздел
    New-ItemProperty -Path $RegistryPathAllow -Name "$counter" -Value $DeviceID -PropertyType String -Force | Out-Null
    if ($DeviceID -eq $SelfInstanceID) {
        Write-Host " [$counter] [ВШИТАЯ ЗАЩИТА (Текущая флешка)]: $DeviceID" -ForegroundColor Green
    } else {
        Write-Host " [$counter] [Разрешено пользователем]: $DeviceID" -ForegroundColor Gray
    }
    $counter++
}

#=======================================================================
# 5. ОЧИСТКА КЭША ДРАЙВЕРОВ СТАРЫХ USB
#=======================================================================
Write-Host "`nОчистка кэша ранее подключенных USB-устройств..." -ForegroundColor Yellow
$OldDevices = Get-PnpDevice -Class "DiskDrive" | Where-Object { $_.InstanceId -match "USBSTOR" -and $_.InstanceId -ne $SelfInstanceID }

foreach ($Device in $OldDevices) {
    try {
        pnputil /remove-device $Device.InstanceId | Out-Null
        Write-Host " Кэш очищен для: $($Device.FriendlyName)" -ForegroundColor Gray
    } catch {
        Write-Host " Не удалось очистить кэш для: $($Device.FriendlyName)" -ForegroundColor Red
    }
}

#=======================================================================
# 6. ИНТЕГРАЦИЯ СТРУКТУРЫ ИЗ 111.REG И АКТИВАЦИЯ ПОЛИТИК
#=======================================================================
$CustomMessageTitle = "Несанкціоноване підлюченя пристрою"
$CustomMessageText  = "Підключення цього пристрою заблоковано політикою безпеки. Зверніться до СЗІ"

# Тотальная блокировка по умолчанию 
New-ItemProperty -Path $RegistryPathPolicy -Name "DenyUnspecified" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $RegistryPathPolicy -Name "AllowInstanceIDs" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $RegistryPathPolicy -Name "AllowDeviceIDsFirst" -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $RegistryPathPolicy -Name "AllowDeviceInstanceIDs" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $RegistryPathPolicy -Name "AllowDenyLayered" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $RegistryPathPolicy -Name "DenyDeviceClasses" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $RegistryPathPolicy -Name "DenyDeviceClassesRetroactive" -Value 1 -PropertyType DWord -Force | Out-Null

# Кастомные тексты ошибок MMC
#New-ItemProperty -Path $RegistryPathPolicy -Name "DenyMessageTitle" -Value $CustomMessageTitle -PropertyType String -Force | Out-Null
#New-ItemProperty -Path $RegistryPathPolicy -Name "DenyMessageText" -Value $CustomMessageText -PropertyType String -Force | Out-Null

# Подраздел DeniedPolicy 
$RegistryPathDeniedPolicy = "$RegistryPathPolicy\DeniedPolicy"
if (!(Test-Path $RegistryPathDeniedPolicy)) { New-Item -Path $RegistryPathDeniedPolicy -Force | Out-Null }
New-ItemProperty -Path $RegistryPathDeniedPolicy -Name "DetailText" -Value $CustomMessageTitle -PropertyType String -Force | Out-Null
New-ItemProperty -Path $RegistryPathDeniedPolicy -Name "SimpleText" -Value $CustomMessageText -PropertyType String -Force | Out-Null

# Подраздел DenyDeviceClasses 
$RegistryPathDenyClasses = "$RegistryPathPolicy\DenyDeviceClasses"
if (!(Test-Path $RegistryPathDenyClasses)) { New-Item -Path $RegistryPathDenyClasses -Force | Out-Null }

$DeviceClassesToDeny = @{
    "1" = "{6bdd1fc6-810f-11d0-bec7-08002be2092f}"
    "2" = "{4d36e970-e325-11ce-bfc1-08002be10318}"
    "3" = "{4d36e96d-e325-11ce-bfc1-08002be10318}"
    "4" = "{eec5ad98-8080-425f-992a-dabf3de3f69a}"
    "5" = "{eec5ad98-8080-425f-992a-dabf3de3f69a}"
    "6" = "{4d36e967-e325-11ce-bfc1-08002be10318}"
    "7" = "{4d36e972-e325-11ce-bfc1-08002be10318}"
    "8" = "{4d36e979-e325-11ce-bfc1-08002be10318}"
    "9" = "{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}"
}
foreach ($Key in $DeviceClassesToDeny.Keys) {
    New-ItemProperty -Path $RegistryPathDenyClasses -Name $Key -Value $DeviceClassesToDeny[$Key] -PropertyType String -Force | Out-Null
}

#=======================================================================
# 7. ОБНОВЛЕНИЕ СИСТЕМНЫХ ПОЛИТИК
#=======================================================================
Write-Host "`nПрименение политик безопасности Windows (gpupdate)..." -ForegroundColor Yellow
gpupdate /force

Write-Host "`n[КОМПЛЕКТ УСПЕШНО ПРИМЕНЕН] Посторонние съемные устройства полностью заблокированы!" -ForegroundColor Green
Pause