param([ValidateSet("Disable", "Enable", "Status")][string]$Mode = "Disable")

 $ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = "." }

 $RegControlPath = "HKLM:\SOFTWARE\DefenderControl"

# Пути логирования определяются один раз при старте
 $Script:LogDir = Join-Path $ScriptRoot "Logs"
if (-not (Test-Path $Script:LogDir)) { New-Item -Path $Script:LogDir -ItemType Directory | Out-Null }
 $Script:LogFile = Join-Path $Script:LogDir "Log_$(Get-Date -Format 'yyyyMMdd').txt"

# ==========================================
# ОСНОВНЫЕ ФУНКЦИИ
# ==========================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO", [switch]$Silent)
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    if (-not $Silent) { Write-Host $entry }
    Add-Content -Path $Script:LogFile -Value $entry
}

function Test-IsSafeMode {
    try { return (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option" -ErrorAction Stop).OptionValue -eq 1 }
    catch { return $false }
}

function Get-NextStage {
    if (Test-Path $RegControlPath) {
        return (Get-ItemProperty $RegControlPath -Name "NextStage" -ErrorAction SilentlyContinue).NextStage
    }
    return $null
}

function Set-NextStage {
    param([int]$Stage)
    if (-not (Test-Path $RegControlPath)) { New-Item -Path $RegControlPath -Force | Out-Null }
    Set-ItemProperty -Path $RegControlPath -Name "NextStage" -Value $Stage -Force | Out-Null
}

function Clear-NextStage {
    if (Test-Path $RegControlPath) { Remove-Item -Path $RegControlPath -Recurse -Force -ErrorAction SilentlyContinue }
}

function Disable-ScheduleScanTasks {
    Write-Log "Планировщик: Отключение задач Schedule Scan*..."
    $tasks = Get-ScheduledTask -TaskName 'Schedule Scan*' -ErrorAction SilentlyContinue
    if ($tasks) {
        foreach ($task in $tasks) {
            $task | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Планировщик: Отключена задача $($task.TaskName) ($($task.TaskPath))"
        }
    } else {
        Write-Log "Планировщик: Задачи Schedule Scan* не найдены"
    }
}

function Enable-ScheduleScanTasks {
    Write-Log "Планировщик: Включение задач Schedule Scan*..."
    $tasks = Get-ScheduledTask -TaskName 'Schedule Scan*' -ErrorAction SilentlyContinue
    if ($tasks) {
        foreach ($task in $tasks) {
            $task | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Планировщик: Включена задача $($task.TaskName) ($($task.TaskPath))"
        }
    } else {
        Write-Log "Планировщик: Задачи Schedule Scan* не найдены"
    }
}

function Stop-DefenderProcesses {
    $procs = @("MsMpEng", "MpCmdRun", "SmartScreen", "SecurityHealthSystray", "SecurityHealthHost", "NisSrv", "MpDefenderCoreService")
    Stop-Process -Name $procs -Force -ErrorAction SilentlyContinue
}

function Disable-DefenderDefaultDefinitions {
    Write-Log "DISM: Отключение Windows-Defender-Default-Definitions..."
    $result = & dism.exe /Online /Disable-Feature /FeatureName:Windows-Defender-Default-Definitions /NoRestart 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "DISM: Windows-Defender-Default-Definitions отключён"
    } elseif ($LASTEXITCODE -eq 3010) {
        Write-Log "DISM: Windows-Defender-Default-Definitions отключён (требуется перезагрузка)" "WARNING"
    } else {
        Write-Log "DISM: Ошибка отключения Windows-Defender-Default-Definitions (код $LASTEXITCODE)" "WARNING"
    }
}

function Enable-DefenderDefaultDefinitions {
    Write-Log "DISM: Включение Windows-Defender-Default-Definitions..."
    $result = & dism.exe /Online /Enable-Feature /FeatureName:Windows-Defender-Default-Definitions /NoRestart 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "DISM: Windows-Defender-Default-Definitions включён"
    } elseif ($LASTEXITCODE -eq 3010) {
        Write-Log "DISM: Windows-Defender-Default-Definitions включён (требуется перезагрузка)" "WARNING"
    } else {
        Write-Log "DISM: Ошибка включения Windows-Defender-Default-Definitions (код $LASTEXITCODE)" "WARNING"
    }
}

function Get-DefenderDefaultDefinitionsState {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName "Windows-Defender-Default-Definitions" -ErrorAction Stop
        return $feature.State  # "Enabled" или "Disabled"
    } catch {
        return "Unknown"
    }
}

function Find-SmartScreenPath {
    $candidates = @(
        Join-Path $env:SystemRoot "System32\SmartScreen.exe"
        Join-Path $env:SystemRoot "System32\Microsoft\Windows SmartScreen\SmartScreen.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Disable-SmartScreenExe {
    $path = Find-SmartScreenPath
    if (-not $path) { Write-Log "SmartScreen.exe не найден"; return }
    $target = $path + "1"
    if (Test-Path $target) { Write-Log "SmartScreen.exe1 уже существует: $target"; return }
    try {
        Enable-Privilege
        Rename-Item -Path $path -NewName (Split-Path $target -Leaf) -Force -ErrorAction Stop
        Write-Log "SmartScreen: Переименован в $target"
    } catch { Write-Log "ОШИБКА переименования SmartScreen.exe: $_" "ERROR" }
}

function Enable-SmartScreenExe {
    $path = Find-SmartScreenPath
    $disabledPath = if ($path) { $path + "1" } else {
        $candidates = @(
            Join-Path $env:SystemRoot "System32\SmartScreen.exe1"
            Join-Path $env:SystemRoot "System32\Microsoft\Windows SmartScreen\SmartScreen.exe1"
        )
        foreach ($p in $candidates) { if (Test-Path $p) { $p; break } }
    }
    if (-not $disabledPath -or -not (Test-Path $disabledPath)) { Write-Log "SmartScreen.exe1 не найден"; return }
    $originalPath = $disabledPath.Substring(0, $disabledPath.Length - 1)
    try {
        Enable-Privilege
        Rename-Item -Path $disabledPath -NewName "SmartScreen.exe" -Force -ErrorAction Stop
        Write-Log "SmartScreen: Восстановлен из $disabledPath"
    } catch { Write-Log "ОШИБКА восстановления SmartScreen.exe: $_" "ERROR" }
}

function Get-WebThreatDefUserSvcs {
    @(@(Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services" -Name -ErrorAction SilentlyContinue) -like "webthreatdefusersvc*")
}

function Enable-Privilege {
    $definition = @"
    using System; using System.Runtime.InteropServices;
    public class AdjPriv {
        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)] internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)] internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
        [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
        [StructLayout(LayoutKind.Sequential, Pack = 1)] internal struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
        internal const int SE_PRIVILEGE_ENABLED = 0x00000002; internal const int TOKEN_QUERY = 0x00000008; internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
        public static bool EnablePrivilege(long processHandle, string privilege) {
            bool retVal; TokPriv1Luid tp; IntPtr hproc = new IntPtr(processHandle); IntPtr htok = IntPtr.Zero;
            retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok); tp.Count = 1; tp.Luid = 0; tp.Attr = SE_PRIVILEGE_ENABLED;
            retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid); retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero); return retVal;
        }
    }
"@
    if (-not ('AdjPriv' -as [type])) { Add-Type -TypeDefinition $definition }
    [AdjPriv]::EnablePrivilege((Get-Process -id $pid).Handle.ToInt64(), "SeTakeOwnershipPrivilege") | Out-Null
    [AdjPriv]::EnablePrivilege((Get-Process -id $pid).Handle.ToInt64(), "SeRestorePrivilege") | Out-Null
}

# ==========================================
# ФУНКЦИИ ПРИМЕНЕНИЯ ИЗМЕНЕНИЙ
# ==========================================

function Grant-AdminAccessRecursive {
    param([string]$PSPath)
    Enable-Privilege
    $regPath = $PSPath -replace '^HKLM:\\', ''
    
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($regPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($null -ne $key) {
            $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
            $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
            $acl.SetOwner($adminSID)
            $key.SetAccessControl($acl)
            $key.Close()
        }

        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($regPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($null -ne $key) {
            $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule($adminSID, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            $acl.AddAccessRule($rule)
            $key.SetAccessControl($acl)
            $key.Close()
        }

        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($regPath)
        if ($null -ne $key) {
            foreach ($subKeyName in $key.GetSubKeyNames()) {
                Grant-AdminAccessRecursive -PSPath "HKLM:\$regPath\$subKeyName"
            }
            $key.Close()
        }
    } catch { Write-Log "Сбой разблокировки $PSPath : $_" "WARNING" }
}

function Unlock-DefenderRegistry {
    Write-Log "ВЗЯТИЕ ВЛАДЕНИЯ HKLM:\SOFTWARE\Microsoft\Windows Defender..."
    Grant-AdminAccessRecursive -PSPath "HKLM:\SOFTWARE\Microsoft\Windows Defender"
    Grant-AdminAccessRecursive -PSPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    Grant-AdminAccessRecursive -PSPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center"
    Grant-AdminAccessRecursive -PSPath "HKLM:\SOFTWARE\Microsoft\Security Center"
    
    & reg.exe add "HKLM\SOFTWARE\Microsoft\Windows Defender\Features" /v "TamperProtection" /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\SOFTWARE\Microsoft\Windows Defender" /v "DisableAntiSpyware" /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    Write-Log "ВНИМАНИЕ: TamperProtection=0, DisableAntiSpyware=1"
}

function Apply-Registry {
    param([array]$Config, [bool]$SafeMode = $false, [bool]$EnableMode = $false)
    
    $typeMap = @{ "DWord" = "REG_DWORD"; "String" = "REG_SZ"; "ExpandString" = "REG_EXPAND_SZ" }

    if ($SafeMode) { Unlock-DefenderRegistry }

    foreach ($item in $Config) {
        $regPath = $item.Path -replace 'HKLM:\\', 'HKLM\'

        if ($item.Type -eq "DELETE") {
            & reg.exe delete "$regPath" /v "$($item.Name)" /f 2>&1 | Out-Null
            Write-Log "Реестр: Удалено свойство $($item.Name) из $regPath"
            continue
        }

        $regType = $typeMap[$item.Type]
        $valStr = $item.Value
        if ($item.Type -eq "String" -and [string]::IsNullOrEmpty($valStr)) { $valStr = '""' }
        
        if ([string]::IsNullOrEmpty($item.Name)) {
            & reg.exe add "$regPath" /ve /t $regType /d "$valStr" /f 2>&1 | Out-Null
        } else {
            & reg.exe add "$regPath" /v "$($item.Name)" /t $regType /d "$valStr" /f 2>&1 | Out-Null
        }

        try {
            if ([string]::IsNullOrEmpty($item.Name)) { 
                Write-Log "Реестр: (Default) задан в $($item.Path) [БЕЗ ПРОВЕРКИ]"
                continue 
            }

            if ($item.Path -match '\*') { 
                Write-Log "Реестр: $($item.Name) = $($item.Value) [ПРИМЕНЕНО]"
                continue 
            }

            if (-not (Test-Path $item.Path)) { throw "Путь отсутствует" }

            $checkVal = (Get-ItemProperty -Path $item.Path -Name $item.Name -ErrorAction Stop).($item.Name)
            
            if ($checkVal -eq $item.Value) {
                Write-Log "Реестр: $($item.Name) = $($item.Value) [ПРИМЕНЕНО]"
            } else {
                if ($SafeMode) {
                    Write-Log "КРИТИЧЕСКАЯ ОШИБКА Реестра (SafeMode): $($item.Name). Текущее: $checkVal, Ожидаемое: $($item.Value)" "ERROR"
                } elseif ($EnableMode) {
                    Write-Log "Реестр: $($item.Name) заблокирован активной защитой (Ожидаемо при включении)" "INFO"
                } else {
                    Write-Log "Реестр ЗАБЛОКИРОВАН TAMPER PROTECTION: $($item.Name). Будет применено в Safe Mode." "WARNING"
                }
            }
        } catch {
             Write-Log "ОШИБКА Реестра: $($item.Name). Будет применено в Safe Mode." "WARNING"
        }
    }
}

function Apply-Tasks {
    param([array]$Config, [string]$State)
    foreach ($task in $Config) {
        try {
            if ($State -eq "Disabled") { Disable-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction Stop | Out-Null }
            else { Enable-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction Stop | Out-Null }
            Write-Log "Задача: $State $($task.Name)"
        } catch { Write-Log "ОШИБКА Задачи: $($task.Name) - $_" "WARNING" }
    }
}

function Apply-ExplorerEPP {
    param([array]$Config)
    foreach ($key in $Config) {
        $regPath = $key -replace 'HKLM:\\', 'HKLM\'
        & reg.exe delete $regPath /f 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "Проводник: Удалено $regPath" }
    }
}

function Apply-Services {
    param([array]$Config, [bool]$SafeMode)
    
    $failed = [System.Collections.Generic.List[string]]::new()
    if ($SafeMode) { Enable-Privilege }

    $targetSvcs = [System.Collections.Generic.List[string]]::new()
    foreach ($svc in $Config) {
        if ($svc -eq "webthreatdefsvc") {
            $targetSvcs.Add("webthreatdefsvc")
            $dynSvcs = Get-WebThreatDefUserSvcs
            if ($dynSvcs.Count -gt 0) { 
                $targetSvcs.AddRange([string[]]$dynSvcs) 
            }
        } else {
            $targetSvcs.Add($svc)
        }
    }

    foreach ($svc in $targetSvcs) {
        if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svc")) { 
            Write-Log "Сервис ПРОПУЩЕН: $svc (Не найден)"
            continue 
        }

        # ИСПРАВЛЕНИЕ: В нормальном режиме даже не пытаемся отключить сервисы, чтобы не дразнить Tamper Protection
        if (-not $SafeMode) {
            Write-Log "Сервис: $svc Требуется Safe Mode"
            $failed.Add($svc)
            continue
        }

        # Код ниже выполняется только в Safe Mode
        $null = sc.exe config $svc start=disabled 2>$null
        $null = sc.exe stop $svc 2>$null
        
        $currentStart = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name "Start" -ErrorAction SilentlyContinue).Start
        
        if ($currentStart -eq 4) {
            Write-Log "Сервис: $svc Отключен через SCM"
        } else {
            Write-Log "Сбой SCM для $svc. Взятие владения..."
            try {
                $regPath = "SYSTEM\CurrentControlSet\Services\$svc"
                Grant-AdminAccessRecursive -PSPath "HKLM:\$regPath"
                Set-ItemProperty -Path "HKLM:\$regPath" -Name "Start" -Value 4 -Type DWord -Force -ErrorAction Stop
                Write-Log "Сервис: $svc Отключен через TakeOwnership"
            } catch { Write-Log "КРИТИЧЕСКАЯ ОШИБКА Сервиса: $svc - $_" "ERROR" }
        }
    }
    return $failed
}

function Enable-Services {
    param([array]$Config)
    
    $defaults = @{
        "WinDefend" = 2
        "WdNisSvc" = 3
        "Sense" = 3
        "SecurityHealthService" = 3
        "wscsvc" = 2
        "webthreatdefsvc" = 3
    }

    $targetSvcs = [System.Collections.Generic.List[string]]::new()
    foreach ($svc in $Config) {
        $targetSvcs.Add($svc)
        if ($svc -eq "webthreatdefsvc") {
            $dynSvcs = Get-WebThreatDefUserSvcs
            if ($dynSvcs.Count -gt 0) { 
                $targetSvcs.AddRange([string[]]$dynSvcs) 
            }
        }
    }

    foreach ($svc in $targetSvcs) {
        if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svc")) { 
            Write-Log "Сервис ПРОПУЩЕН: $svc (Не найден)"
            continue 
        }

        $startVal = 3
        if ($defaults.ContainsKey($svc)) { $startVal = $defaults[$svc] }

        try {
            Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name "Start" -Value $startVal -Type DWord -Force -ErrorAction Stop
            $startTypeStr = if ($startVal -eq 2) { "Automatic" } else { "Manual" }
            Write-Log "Сервис: $svc включен ($startTypeStr)"
        } catch { Write-Log "ОШИБКА включения сервиса $svc - $_" "ERROR" }
    }
}

function Apply-Drivers {
    param([array]$Config, [int]$StartValue = 4)
    foreach ($drv in $Config) {
        try {
            if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$drv")) { continue }
            Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$drv" -Name "Start" -Value $StartValue -Type DWord -Force -ErrorAction Stop
            if ($StartValue -eq 4) { Write-Log "Драйвер: $drv Отключен" }
            else { Write-Log "Драйвер: $drv Включен (Start=$StartValue)" }
        } catch { Write-Log "ОШИБКА Драйвера: $drv - $_" "ERROR" }
    }
}

# ==========================================
# УМНЫЙ АУДИТ СТАТУСА
# ==========================================

function Test-DefenderStatus {
    $baseSvcs = @("WinDefend", "WdNisSvc", "Sense", "SecurityHealthService", "wscsvc", "webthreatdefsvc", "wuauserv", "UsoSvc", "DoSvc")
    $allSvcs = [System.Collections.Generic.List[string]]::new()
    $allSvcs.AddRange([string[]]$baseSvcs)
    $dynSvcs = Get-WebThreatDefUserSvcs
    if ($dynSvcs.Count -gt 0) { $allSvcs.AddRange([string[]]$dynSvcs) }

    $config = Get-Content (Join-Path $ScriptRoot "Disabled.json") -Raw | ConvertFrom-Json
    $startMap = @{ 0 = "Boot"; 1 = "System"; 2 = "Auto"; 3 = "Manual"; 4 = "Disabled" }

    Write-Host ""
    Write-Host "  Services:" -ForegroundColor Cyan

    foreach ($svc in $allSvcs) {
        try {
            $s = Get-Service -Name $svc -ErrorAction Stop
            $regStart = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name "Start" -ErrorAction Stop).Start
            $startLabel = if ($startMap.ContainsKey($regStart)) { $startMap[$regStart] } else { "$regStart" }
            $running = $s.Status -eq "Running"
            $disabled = $startLabel -eq "Disabled"
            if ($running -and -not $disabled) { $color = "Green"; $state = "enabled" }
            elseif (-not $running -and $disabled) { $color = "Red"; $state = "disabled" }
            else { $color = "Yellow"; $state = "partial" }
            Write-Host ("    {0,-34} {1}" -f $svc, $state) -ForegroundColor $color
        } catch {
            Write-Host ("    {0,-34} {1}" -f $svc, "not found") -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  Drivers:" -ForegroundColor Cyan

    foreach ($drv in $config.Drivers) {
        try {
            $regStart = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$drv" -Name "Start" -ErrorAction Stop).Start
            $startLabel = if ($startMap.ContainsKey($regStart)) { $startMap[$regStart] } else { "$regStart" }
            if ($startLabel -eq "Disabled") { $color = "Red"; $state = "disabled" }
            else { $color = "Green"; $state = "enabled" }
            Write-Host ("    {0,-34} {1}" -f $drv, $state) -ForegroundColor $color
        } catch {
            Write-Host ("    {0,-34} {1}" -f $drv, "not found") -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  Processes:" -ForegroundColor Cyan

    $procs = @("MsMpEng", "SmartScreen", "SecurityHealthSystray", "NisSrv", "MpDefenderCoreService")
    foreach ($p in $procs) {
        $running = Get-Process -Name $p -ErrorAction SilentlyContinue
        if ($running) { Write-Host ("    {0,-34} running" -f $p) -ForegroundColor Green }
        else { Write-Host ("    {0,-34} stopped" -f $p) -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "  SmartScreen exe:" -ForegroundColor Cyan

    $ssPath = Find-SmartScreenPath
    $ssDisabled = $false
    $candidates = @(
        Join-Path $env:SystemRoot "System32\SmartScreen.exe1"
        Join-Path $env:SystemRoot "System32\Microsoft\Windows SmartScreen\SmartScreen.exe1"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { $ssDisabled = $true; break } }
    if ($ssDisabled) { Write-Host ("    {0,-34} {1}" -f "SmartScreen.exe", "renamed (disabled)") -ForegroundColor Red }
    elseif ($ssPath) { Write-Host ("    {0,-34} {1}" -f "SmartScreen.exe", "active") -ForegroundColor Green }
    else { Write-Host ("    {0,-34} {1}" -f "SmartScreen.exe", "not found") -ForegroundColor DarkGray }

    Write-Host ""
    Write-Host "  Registry:" -ForegroundColor Cyan

    $regChecks = @(
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"; Name = "DisableAntiSpyware"; Expected = 1; Label = "GPO DisableAntiSpyware" }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows Defender"; Name = "DisableAntiSpyware"; Expected = 1; Label = "Local DisableAntiSpyware" }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features"; Name = "TamperProtection"; Expected = 0; Label = "TamperProtection" }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection"; Name = "DisableRealtimeMonitoring"; Expected = 1; Label = "DisableRealtimeMonitoring" }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection"; Name = "DisableRealtimeMonitoring"; Expected = 1; Label = "GPO DisableRealtimeMonitor" }
    )

    foreach ($rc in $regChecks) {
        try {
            $val = (Get-ItemProperty -Path $rc.Path -Name $rc.Name -ErrorAction Stop).$rc.Name
            $ok = $val -eq $rc.Expected
            # ok = настройка для отключения применена -> красный (Defender выключен)
            $color = if ($ok) { "Red" } else { "Green" }
            Write-Host ("    {0,-34} {1}" -f $rc.Label, $val) -ForegroundColor $color
        } catch {
            Write-Host ("    {0,-34} not found" -f $rc.Label) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  Windows Features:" -ForegroundColor Cyan

    $featState = Get-DefenderDefaultDefinitionsState
    $featColor = switch ($featState) {
        "Enabled"  { "Green" }
        "Disabled" { "Red" }
        default    { "DarkGray" }
    }
    Write-Host ("    {0,-34} {1}" -f "Defender-Default-Definitions", $featState) -ForegroundColor $featColor

    Write-Host ""
    Write-Host "  Windows Update:" -ForegroundColor Cyan

    $wuSvcs = @("wuauserv", "UsoSvc", "DoSvc")
    foreach ($svc in $wuSvcs) {
        try {
            $s = Get-Service -Name $svc -ErrorAction Stop
            $regStart = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name "Start" -ErrorAction Stop).Start
            $startLabel = @{0="Boot";1="System";2="Auto";3="Manual";4="Disabled"}[$regStart]
            if ($startLabel -eq "Disabled") { $color = "Red"; $state = "disabled" }
            else { $color = "Green"; $state = "$startLabel" }
            Write-Host ("    {0,-34} {1}" -f $svc, $state) -ForegroundColor $color
        } catch {
            Write-Host ("    {0,-34} {1}" -f $svc, "not found") -ForegroundColor DarkGray
        }
    }

    try {
        $wuPolicies = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
        if ($wuPolicies -and $wuPolicies.NoAutoUpdate -eq 1) {
            Write-Host ("    {0,-34} {1}" -f "NoAutoUpdate", "1 (disabled)") -ForegroundColor Red
        } else {
            Write-Host ("    {0,-34} {1}" -f "NoAutoUpdate", "0 (enabled)") -ForegroundColor Green
        }
    } catch {
        Write-Host ("    {0,-34} {1}" -f "NoAutoUpdate", "not set") -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  Real-Time Protection (WMI):" -ForegroundColor Cyan

    try {
        $mpPref = Get-MpPreference -ErrorAction Stop
        $rtOff = $mpPref.DisableRealtimeMonitoring
        Write-Host ("    {0,-34} {1}" -f "DisableRealtimeMonitoring", $rtOff) -ForegroundColor $(if ($rtOff) { "Red" } else { "Green" })
        $bmOff = $mpPref.DisableBehaviorMonitoring
        Write-Host ("    {0,-34} {1}" -f "DisableBehaviorMonitoring", $bmOff) -ForegroundColor $(if ($bmOff) { "Red" } else { "Green" })
        $ioavOff = $mpPref.DisableIOAVProtection
        Write-Host ("    {0,-34} {1}" -f "DisableIOAVProtection", $ioavOff) -ForegroundColor $(if ($ioavOff) { "Red" } else { "Green" })
    } catch {
        Write-Host "    WMI Get-MpPreference unavailable (expected in Safe Mode)" -ForegroundColor DarkGray
    }

    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $tpOn = $mpStatus.IsTamperProtected
        Write-Host ("    {0,-34} {1}" -f "IsTamperProtected", $tpOn) -ForegroundColor $(if ($tpOn) { "Yellow" } else { "Green" })
        $avOn = $mpStatus.AntivirusEnabled
        Write-Host ("    {0,-34} {1}" -f "AntivirusEnabled", $avOn) -ForegroundColor $(if ($avOn) { "Green" } else { "Red" })
    } catch {
        Write-Host "    WMI Get-MpComputerStatus unavailable" -ForegroundColor DarkGray
    }

    Write-Host ""

    $svcOff = 0; $svcTotal = 0
    foreach ($svc in $allSvcs) {
        try {
            $s = Get-Service -Name $svc -ErrorAction Stop
            $regStart = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name "Start" -ErrorAction Stop).Start
            $svcTotal++
            if ($regStart -eq 4 -and $s.Status -eq "Stopped") { $svcOff++ }
        } catch { $svcTotal++ }
    }

    $drvOff = 0
    foreach ($drv in $config.Drivers) {
        try {
            $regStart = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$drv" -Name "Start" -ErrorAction Stop).Start
            if ($regStart -eq 4) { $drvOff++ }
        } catch {}
    }

    if ($svcOff -eq $svcTotal -and $drvOff -eq $config.Drivers.Count) {
        Write-Host "  Result: Defender fully disabled" -ForegroundColor Red
    } elseif ($svcOff -gt 0 -or $drvOff -gt 0) {
        Write-Host "  Result: Defender partially disabled ($svcOff/$svcTotal services, $drvOff/$($config.Drivers.Count) drivers)" -ForegroundColor Yellow
    } else {
        Write-Host "  Result: Defender enabled (default state)" -ForegroundColor Green
    }
    Write-Host ""
}

# ==========================================
# ГЛАВНАЯ ЛОГИКА ВЫПОЛНЕНИЯ
# ==========================================

 $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
 $principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode" -Verb RunAs
    exit
}

if ($Mode -eq "Status") {
    Stop-DefenderProcesses
    Test-DefenderStatus
    return
}

if ($Mode -eq "Enable") {
    Write-Log "=== ВКЛЮЧЕНИЕ ЗАПУЩЕНО ==="
    $config = Get-Content (Join-Path $ScriptRoot "Enabled.json") -Raw | ConvertFrom-Json
    Apply-Registry -Config $config.Registry -EnableMode $true
    Apply-Tasks -Config $config.Tasks -State "Ready"
    Apply-Drivers -Config $config.Drivers -StartValue 3
    Enable-Services -Config $config.Services
    Enable-DefenderDefaultDefinitions
    Enable-SmartScreenExe
    Enable-ScheduleScanTasks
    
    Write-Host "Defender включен. Перезагрузка через 5 секунд..." -ForegroundColor Green
    shutdown /r /t 5 /c "Defender Control: Перезагрузка для применения настроек"
    return
}

if ($Mode -eq "Disable") {
    
    $NextStage = Get-NextStage

    # Этап 3: финальный аудит после возврата из Safe Mode (обычный режим)
    if ($NextStage -eq 3 -and -not (Test-IsSafeMode)) {
        Write-Log "=== ЭТАП 3: ФИНАЛЬНЫЙ АУДИТ ==="
        Stop-DefenderProcesses
        Start-Sleep -Seconds 2
        Test-DefenderStatus
        Clear-NextStage
        Write-Log "=== АУДИТ ЗАВЕРШЕН ==="
        return
    }

    # Этап 2: работа в Safe Mode
    if (Test-IsSafeMode) {
        Write-Log "=== ЭТАП 2: БЕЗОПАСНЫЙ РЕЖИМ ==="
        $config = Get-Content (Join-Path $ScriptRoot "Disabled.json") -Raw | ConvertFrom-Json
        
        Apply-Registry -Config $config.Registry -SafeMode $true
        Apply-Drivers -Config $config.Drivers
        Apply-Services -Config $config.Services -SafeMode $true
        Disable-DefenderDefaultDefinitions
        Disable-SmartScreenExe
        Disable-ScheduleScanTasks
        
        Set-NextStage -Stage 3
        bcdedit /deletevalue "{current}" safeboot | Out-Null

        # Ключ со звёздочкой (*) — выполняется в том числе в Safe Mode
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" `
            -Name "*DefenderControl_Audit" `
            -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Disable" `
            -Force

        # Убираем RunOnce для Safe Mode (он уже отработал)
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" `
            -Name "*DefenderControl_SafeMode" -ErrorAction SilentlyContinue
        
        Write-Host "Операции в Safe Mode завершены. Возврат в Нормальный режим через 5 секунд..." -ForegroundColor Green
        shutdown /r /t 5 /c "Defender Control: Возврат в Нормальный режим для аудита"
        exit
    } 
    
    # Этап 1: обычный режим — подготовка и уход в Safe Mode
    else {
        Write-Log "=== ЭТАП 1: НОРМАЛЬНЫЙ РЕЖИМ ==="
        
        $config = Get-Content (Join-Path $ScriptRoot "Disabled.json") -Raw | ConvertFrom-Json

        Stop-DefenderProcesses
        
        Apply-Tasks -Config $config.Tasks -State "Disabled"
        Apply-ExplorerEPP -Config $config.ExplorerEPP
        $failedSvcs = Apply-Services -Config $config.Services -SafeMode $false
        
        Write-Log "Tamper Protection активен. Политики реестра и драйверы требуют Safe Mode."
        Set-NextStage -Stage 2
        bcdedit /set "{current}" safeboot minimal | Out-Null

        # Ключ со звёздочкой (*) — выполняется в Safe Mode автоматически
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" `
            -Name "*DefenderControl_SafeMode" `
            -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Disable" `
            -Force
        
        Write-Host "Перезагрузка в Safe Mode через 5 секунд..." -ForegroundColor Yellow
        shutdown /r /t 5 /c "Defender Control: Перезагрузка в Safe Mode"
        exit
    }
}