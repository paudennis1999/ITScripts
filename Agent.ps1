$agentConfigPath = "C:\ITScripts\agent-config.json"
$localConfigPath = "C:\ITScripts\config.json"

$scriptsPath = "C:\ITScripts\Scripts"
$logsPath = "C:\ITScripts\Logs"
$scheduleStatePath = "C:\ITScripts\schedule-state.json"

$logFile = Join-Path $logsPath "agent.log"

# Maximum number of log lines to keep
$maxLogLines = 200

# Available groups
$validGroups = @(
    "GROUP_A",
    "GROUP_B",
    "GROUP_C",
    "GROUP_A_SUB",
    "ALL"
)

# --------------------------------------------------
# GROUP HIERARCHY (one-way inheritance)
# --------------------------------------------------
# If a group appears here as a key, machines in that group can
# also download/execute scripts belonging to the groups listed
# as its value (the "parents"). This is NOT symmetrical: a
# machine in the parent group does NOT see scripts belonging to
# the sub-group.
#
# Current example: GROUP_A_SUB inherits from GROUP_A.
#   - A GROUP_A_SUB machine -> sees GROUP_A and GROUP_A_SUB scripts
#   - A GROUP_A machine      -> sees only GROUP_A scripts (not GROUP_A_SUB)
#
# To add a future sub-group, just add a new entry here, no need
# to touch the rest of the logic.

$groupHierarchy = @{
    "GROUP_A_SUB" = @("GROUP_A")
}

# --------------------------------------------------
# CREATE REQUIRED FOLDERS
# --------------------------------------------------

foreach ($folder in @($scriptsPath, $logsPath)) {

    if (-not (Test-Path $folder)) {

        New-Item `
            -ItemType Directory `
            -Path $folder `
            -Force |
            Out-Null
    }
}

# --------------------------------------------------
# LOGGING FUNCTION
# --------------------------------------------------

function Write-Log {

    param (
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp | $Message"

    Add-Content `
        -Path $logFile `
        -Value $logMessage

    # Keeps only the last 200 lines
    $lines = Get-Content -Path $logFile

    if ($lines.Count -gt $maxLogLines) {

        $lines |
            Select-Object -Last $maxLogLines |
            Set-Content -Path $logFile
    }

    Write-Host $logMessage
}

# --------------------------------------------------
# FILE NAME VALIDATION
# --------------------------------------------------

function Test-SafeFileName {

    param (
        [string]$FileName
    )

    # Blocks:
    # - empty values
    # - path traversal
    # - absolute paths
    # - folder separators

    if ([string]::IsNullOrWhiteSpace($FileName)) {

        return $false
    }

    if (
        $FileName -match '\.\.' -or
        $FileName -match '[\\/]' -or
        [System.IO.Path]::IsPathRooted($FileName)
    ) {

        return $false
    }

    return $true
}

# --------------------------------------------------
# SCHEDULE STATE (persisted between agent runs)
# --------------------------------------------------

function Get-ScheduleState {

    if (-not (Test-Path $scheduleStatePath)) {

        return @{}
    }

    try {

        $raw = Get-Content -Path $scheduleStatePath -Raw -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($raw)) {

            return @{}
        }

        $obj = $raw | ConvertFrom-Json

        $state = @{}

        foreach ($prop in $obj.PSObject.Properties) {

            $state[$prop.Name] = $prop.Value
        }

        return $state
    }
    catch {

        Write-Log `
            "WARN | schedule-state.json is invalid, it will be recreated | $($_.Exception.Message)"

        return @{}
    }
}

function Save-ScheduleState {

    param (
        [hashtable]$State
    )

    try {

        $State |
            ConvertTo-Json -Depth 5 |
            Set-Content -Path $scheduleStatePath
    }
    catch {

        Write-Log `
            "ERROR | Unable to save schedule-state.json | $($_.Exception.Message)"
    }
}

# --------------------------------------------------
# DAY NAME -> DayOfWeek CONVERSION
# --------------------------------------------------
# Accepts standard English day names (.NET), case-insensitive.

function ConvertTo-DayOfWeek {

    param (
        [string]$DayString
    )

    if ([string]::IsNullOrWhiteSpace($DayString)) {

        return $null
    }

    try {

        return [System.DayOfWeek]$DayString
    }
    catch {

        return $null
    }
}

# --------------------------------------------------
# SCHEDULE EVALUATION
# --------------------------------------------------

function Test-ShouldRunNow {

    param (
        [string]$ScriptName,
        [PSCustomObject]$Schedule,
        [hashtable]$State,
        [datetime]$Now
    )

    # No schedule defined -> legacy behavior (always run if enabled/execute)
    if (-not $Schedule -or -not $Schedule.type) {

        return $true
    }

    $type = $Schedule.type.ToString().ToLower()

    $entry = $State[$ScriptName]
    $lastRun = $null

    if ($entry -and $entry.lastRun) {

        try {
            $lastRun = [datetime]::Parse($entry.lastRun)
        }
        catch {
            $lastRun = $null
        }
    }

    switch ($type) {

        "manual" {

            # No automatic gating: the "execute" flag in the config remains the only control
            return $true
        }

        "interval" {

            $minutes = $Schedule.minutes

            if (-not $minutes -or $minutes -le 0) {

                Write-Log `
                    "WARN | $ScriptName | invalid schedule.minutes"

                return $false
            }

            if (-not $lastRun) {

                return $true
            }

            return ($Now - $lastRun).TotalMinutes -ge $minutes
        }

        "weekly" {

            $dayStr = $Schedule.day
            $timeStr = $Schedule.time

            if ([string]::IsNullOrWhiteSpace($dayStr)) {

                Write-Log `
                    "WARN | $ScriptName | invalid schedule.day"

                return $false
            }

            if ([string]::IsNullOrWhiteSpace($timeStr)) {

                Write-Log `
                    "WARN | $ScriptName | invalid schedule.time"

                return $false
            }

            $scheduledDay = ConvertTo-DayOfWeek -DayString $dayStr

            if ($null -eq $scheduledDay) {

                Write-Log `
                    "WARN | $ScriptName | invalid day: '$dayStr' (e.g. Monday, Tuesday...)"

                return $false
            }

            if ($Now.DayOfWeek -ne $scheduledDay) {

                return $false
            }

            try {

                $parsedTime = `
                    [datetime]::ParseExact($timeStr, "HH:mm", $null)
            }
            catch {

                Write-Log `
                    "WARN | $ScriptName | invalid time format: '$timeStr' (expected HH:mm)"

                return $false
            }

            $scheduledToday = Get-Date `
                -Hour $parsedTime.Hour `
                -Minute $parsedTime.Minute `
                -Second 0

            # Today's scheduled time hasn't arrived yet
            if ($Now -lt $scheduledToday) {

                return $false
            }

            # Already run today (avoids double execution on the same day)
            if ($lastRun -and $lastRun.Date -eq $Now.Date) {

                return $false
            }

            return $true
        }

        "daily" {

            $timeStr = $Schedule.time

            if ([string]::IsNullOrWhiteSpace($timeStr)) {

                Write-Log `
                    "WARN | $ScriptName | invalid schedule.time"

                return $false
            }

            try {

                $parsedTime = `
                    [datetime]::ParseExact($timeStr, "HH:mm", $null)
            }
            catch {

                Write-Log `
                    "WARN | $ScriptName | invalid time format: '$timeStr' (expected HH:mm)"

                return $false
            }

            $scheduledToday = Get-Date `
                -Hour $parsedTime.Hour `
                -Minute $parsedTime.Minute `
                -Second 0

            # Today's scheduled time hasn't arrived yet
            if ($Now -lt $scheduledToday) {

                return $false
            }

            # Already run today
            if ($lastRun -and $lastRun.Date -eq $Now.Date) {

                return $false
            }

            return $true
        }

        default {

            Write-Log `
                "WARN | $ScriptName | Unknown schedule type: '$type'"

            return $false
        }
    }
}

# --------------------------------------------------
# FTP DOWNLOAD
# --------------------------------------------------

function Download-FTPFile {

    param (
        [string]$Url,
        [string]$Username,
        [string]$Password,
        [string]$Destination,
        [string]$ExpectedHash = $null,
        [int]$TimeoutMs = 30000
    )

    $response = $null
    $stream = $null
    $fileStream = $null

    try {

        $request = [System.Net.FtpWebRequest]::Create($Url)

        $request.Method = `
            [System.Net.WebRequestMethods+Ftp]::DownloadFile

        $request.Credentials = `
            New-Object System.Net.NetworkCredential(
                $Username,
                $Password
            )

        $request.UsePassive = $true
        $request.UseBinary = $true

        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs

        $response = $request.GetResponse()

        $stream = $response.GetResponseStream()

        $fileStream = `
            [System.IO.File]::Create($Destination)

        $stream.CopyTo($fileStream)

        $fileStream.Flush()

        # --------------------------------------------------
        # SHA256 VERIFICATION
        # --------------------------------------------------

        if ($ExpectedHash) {

            $fileStream.Close()
            $fileStream = $null

            $actualHash = (
                Get-FileHash `
                    -Path $Destination `
                    -Algorithm SHA256
            ).Hash

            $actualHash = $actualHash.ToUpper()
            $ExpectedHash = $ExpectedHash.ToUpper()

            if ($actualHash -ne $ExpectedHash) {

                Write-Log `
                    "ERROR | Hash mismatch on $Destination | Expected: $ExpectedHash | Got: $actualHash"

                Remove-Item `
                    -Path $Destination `
                    -Force `
                    -ErrorAction SilentlyContinue

                return $false
            }

            Write-Log `
                "SUCCESS | SHA256 verified | $Destination"
        }

        return $true
    }

    catch [System.Net.WebException] {

        $ftpResponse = $_.Exception.Response

        $statusCode = if ($ftpResponse) {
            $ftpResponse.StatusCode
        }
        else {
            "N/A"
        }

        Write-Log `
            "ERROR | FTP | $Url | Status: $statusCode | $($_.Exception.Message)"

        return $false
    }

    catch {

        Write-Log `
            "ERROR | FTP | $Url | $($_.Exception.Message)"

        return $false
    }

    finally {

        if ($fileStream) {
            $fileStream.Dispose()
        }

        if ($stream) {
            $stream.Dispose()
        }

        if ($response) {
            $response.Dispose()
        }
    }
}

# --------------------------------------------------
# OVERLAPPING EXECUTION PROTECTION
# --------------------------------------------------
# Even though the Scheduled Task is configured with MultipleInstances
# IgnoreNew, this mutex acts as a second safety net: it also covers
# the case of a manual launch (e.g. testing from a console) while a
# scheduled run is already in progress.
#
# If the process terminates abnormally (crash, kill, etc.) without
# releasing the mutex, Windows marks it as "abandoned" and it is
# still freed on the next run (caught below via
# AbandonedMutexException), so no extra handling is required.

$mutexName = "Global\ITScriptsAgentMutex"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$mutexAcquired = $false

try {

    $mutexAcquired = $mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {

    # Mutex abandoned by a previous run that terminated abnormally
    $mutexAcquired = $true
}

if (-not $mutexAcquired) {

    Write-Log `
        "SKIP | Another instance of the agent is already running | Exiting immediately"

    $mutex.Dispose()

    exit 0
}

# --------------------------------------------------
# AGENT START
# --------------------------------------------------

Write-Log "========================================"
Write-Log "===== ITSCRIPTS AGENT START ====="
Write-Log "========================================"

$now = Get-Date

# --------------------------------------------------
# LOAD AGENT CONFIGURATION
# --------------------------------------------------

if (-not (Test-Path $agentConfigPath)) {

    Write-Log `
        "ERROR | agent-config.json not found: $agentConfigPath"

    exit 1
}

try {

    $agentConfig = `
        Get-Content `
            $agentConfigPath `
            -Raw `
            -Encoding UTF8 |
        ConvertFrom-Json
}
catch {

    Write-Log `
        "ERROR | agent-config.json is invalid | $($_.Exception.Message)"

    exit 1
}

# --------------------------------------------------
# READ FTP DATA
# --------------------------------------------------

$ftpServer = $agentConfig.ftpServer
$username = $agentConfig.username
$password = $agentConfig.password

# --------------------------------------------------
# VALIDATE FTP DATA
# --------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ftpServer)) {

    Write-Log `
        "ERROR | ftpServer not configured"

    exit 1
}

if ([string]::IsNullOrWhiteSpace($username)) {

    Write-Log `
        "ERROR | FTP username not configured"

    exit 1
}

if ([string]::IsNullOrWhiteSpace($password)) {

    Write-Log `
        "ERROR | FTP password not configured"

    exit 1
}

# --------------------------------------------------
# READ AGENT GROUP
# --------------------------------------------------

$agentGroup = $agentConfig.group

if ([string]::IsNullOrWhiteSpace($agentGroup)) {

    Write-Log `
        "ERROR | Group not defined in agent-config.json"

    Write-Log `
        "INFO | Valid groups: GROUP_A, GROUP_B, GROUP_C, GROUP_A_SUB, ALL"

    exit 1
}

$agentGroup = $agentGroup.ToUpper()

# --------------------------------------------------
# GROUP VALIDATION
# --------------------------------------------------

if ($agentGroup -notin $validGroups) {

    Write-Log `
        "ERROR | Invalid group: $agentGroup"

    Write-Log `
        "INFO | Valid groups: GROUP_A, GROUP_B, GROUP_C, GROUP_A_SUB, ALL"

    exit 1
}

Write-Log `
    "INFO | Agent group: $agentGroup"

# --------------------------------------------------
# EFFECTIVE GROUPS (own group + inherited parents)
# --------------------------------------------------

$agentEffectiveGroups = @($agentGroup)

if ($groupHierarchy.ContainsKey($agentGroup)) {

    $agentEffectiveGroups += $groupHierarchy[$agentGroup]

    Write-Log `
        "INFO | Effective groups (with inheritance): $($agentEffectiveGroups -join ', ')"
}

Write-Log `
    "INFO | FTP Server: $ftpServer"

# --------------------------------------------------
# DOWNLOAD CONFIG FROM THE SERVER
# --------------------------------------------------

Write-Log "FTP | Downloading config.json"

$configUrl = $ftpServer + "config.json"

$configDownloaded = Download-FTPFile `
    -Url $configUrl `
    -Username $username `
    -Password $password `
    -Destination $localConfigPath

if (-not $configDownloaded) {

    Write-Log `
        "ERROR | Unable to download config.json"

    exit 1
}

Write-Log `
    "SUCCESS | config.json downloaded"

# --------------------------------------------------
# READ CONFIG
# --------------------------------------------------

try {

    $config = `
        Get-Content `
            $localConfigPath `
            -Raw `
            -Encoding UTF8 |
        ConvertFrom-Json
}
catch {

    Write-Log `
        "ERROR | config.json is invalid | $($_.Exception.Message)"

    exit 1
}

# --------------------------------------------------
# SCRIPT LIST CHECK
# --------------------------------------------------

if (-not $config.scripts -or $config.scripts.Count -eq 0) {

    Write-Log `
        "WARN | No scripts defined in config.json"

    Write-Log `
        "===== AGENT END ====="

    exit 0
}

Write-Log `
    "INFO | Scripts present in config: $($config.scripts.Count)"

# --------------------------------------------------
# LOAD SCHEDULE STATE
# --------------------------------------------------

$scheduleState = Get-ScheduleState

# --------------------------------------------------
# PROCESS THE SCRIPTS
# --------------------------------------------------

foreach ($script in $config.scripts) {

    $scriptName = $script.name
    $scriptGroup = $script.group

    # --------------------------------------------------
    # SCRIPT NAME CHECK
    # --------------------------------------------------

    if (-not (Test-SafeFileName -FileName $scriptName)) {

        Write-Log `
            "ERROR | Invalid or unsafe script name: '$scriptName'"

        continue
    }

    # --------------------------------------------------
    # SCRIPT GROUP CHECK
    # --------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($scriptGroup)) {

        Write-Log `
            "SKIP | $scriptName | Group not defined"

        continue
    }

    $scriptGroup = $scriptGroup.ToUpper()

    if ($scriptGroup -notin $validGroups) {

        Write-Log `
            "SKIP | $scriptName | Invalid group: $scriptGroup"

        continue
    }

    # --------------------------------------------------
    # GROUP MEMBERSHIP CHECK
    # --------------------------------------------------

    $groupAllowed = $false

    # Case 1:
    # The script is ALL
    if ($scriptGroup -eq "ALL") {

        $groupAllowed = $true
    }

    # Case 2:
    # The machine belongs to ALL
    elseif ($agentGroup -eq "ALL") {

        $groupAllowed = $true
    }

    # Case 3:
    # The script's group is among the agent's effective groups
    # (its own group, or an inherited parent)
    elseif ($scriptGroup -in $agentEffectiveGroups) {

        $groupAllowed = $true
    }

    if (-not $groupAllowed) {

        Write-Log `
            "SKIP | $scriptName | Script group: $scriptGroup | Agent group: $agentGroup"

        continue
    }

    Write-Log `
        "MATCH | $scriptName | Group: $scriptGroup"

    # --------------------------------------------------
    # ENABLED CHECK
    # --------------------------------------------------

    if ($script.enabled -ne $true) {

        Write-Log `
            "SKIP | $scriptName | Disabled"

        continue
    }

    # --------------------------------------------------
    # DOWNLOAD SCRIPT
    # --------------------------------------------------

    $scriptUrl = `
        $ftpServer + "Scripts/" + $scriptName

    $localScriptPath = `
        Join-Path $scriptsPath $scriptName

    # --------------------------------------------------
    # RESOLVED PATH CHECK
    # --------------------------------------------------

    $resolvedScriptsPath = `
        [System.IO.Path]::GetFullPath($scriptsPath)

    $resolvedLocalPath = `
        [System.IO.Path]::GetFullPath($localScriptPath)

    if (
        -not $resolvedLocalPath.StartsWith(
            $resolvedScriptsPath,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {

        Write-Log `
            "ERROR | $scriptName | Resolved path outside $scriptsPath | Download blocked"

        continue
    }

    # --------------------------------------------------
    # DOWNLOAD
    # --------------------------------------------------

    Write-Log `
        "DOWNLOAD | $scriptName | Group: $scriptGroup"

    $expectedHash = $script.sha256

    $downloaded = Download-FTPFile `
        -Url $scriptUrl `
        -Username $username `
        -Password $password `
        -Destination $localScriptPath `
        -ExpectedHash $expectedHash

    if (-not $downloaded) {

        Write-Log `
            "ERROR | $scriptName | Download failed"

        continue
    }

    Write-Log `
        "SUCCESS | $scriptName | Download completed"

    # --------------------------------------------------
    # EXECUTE CHECK
    # --------------------------------------------------

    if ($script.execute -ne $true) {

        Write-Log `
            "SKIP | $scriptName | Execution disabled"

        continue
    }

    # --------------------------------------------------
    # SCHEDULE CHECK
    # --------------------------------------------------

    $shouldRun = Test-ShouldRunNow `
        -ScriptName $scriptName `
        -Schedule $script.schedule `
        -State $scheduleState `
        -Now $now

    if (-not $shouldRun) {

        $scheduleType = if ($script.schedule -and $script.schedule.type) {
            $script.schedule.type
        }
        else {
            "n/a"
        }

        Write-Log `
            "SKIP | $scriptName | Not time yet (schedule: $scheduleType)"

        continue
    }

    # --------------------------------------------------
    # EXECUTION
    # --------------------------------------------------

    Write-Log `
        "START | $scriptName"

    # Record the run time immediately, to avoid back-to-back
    # duplicate executions in case of long runs or errors.
    $scheduleState[$scriptName] = @{ lastRun = $now.ToString("o") }
    Save-ScheduleState -State $scheduleState

    try {

        & powershell.exe `
            -ExecutionPolicy Bypass `
            -File $localScriptPath

        if ($LASTEXITCODE -eq 0) {

            Write-Log `
                "SUCCESS | $scriptName | Execution completed"
        }
        else {

            Write-Log `
                "ERROR | $scriptName | ExitCode: $LASTEXITCODE"
        }
    }

    catch {

        Write-Log `
            "ERROR | $scriptName | $($_.Exception.Message)"
    }
}

# --------------------------------------------------
# AGENT END
# --------------------------------------------------

Write-Log "========================================"
Write-Log "===== ITSCRIPTS AGENT END ====="
Write-Log "========================================"

if ($mutexAcquired) {

    $mutex.ReleaseMutex()
}

$mutex.Dispose()
