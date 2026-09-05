# ============================================================
# ITSCRIPTS - INSTALLER
# ============================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

$InstallPath = "C:\ITScripts"

$ScriptsPath = Join-Path $InstallPath "Scripts"
$LogsPath = Join-Path $InstallPath "Logs"

$AgentPath = Join-Path $InstallPath "Agent.ps1"
$AgentConfigPath = Join-Path $InstallPath "agent-config.json"

$TaskName = "ITScripts Agent"

# ------------------------------------------------------------
# DEFAULT FTP SERVER
# ------------------------------------------------------------
# Replace with your own FTP server before deploying.

$DefaultFTPServer = "ftp://ftp.example.com/ITScripts/"

$ValidGroups = @(
    "GROUP_A",
    "GROUP_B",
    "GROUP_C",
    "GROUP_A_SUB",
    "ALL"
)

# ============================================================
# FUNCTIONS
# ============================================================

function Write-InstallerLog {

    param (
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Write-Host "$timestamp | $Message"
}

function Test-Administrator {

    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        Security.Principal.WindowsPrincipal($currentUser)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Select-AgentGroup {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "         ITSCRIPTS GROUP SELECTION"
    Write-Host "========================================"
    Write-Host ""

    Write-Host "[1] GROUP_A"
    Write-Host "[2] GROUP_B"
    Write-Host "[3] GROUP_C"
    Write-Host "[4] GROUP_A_SUB"
    Write-Host "[5] ALL"
    Write-Host ""

    while ($true) {

        $selection = Read-Host "Select the group"

        switch ($selection) {

            "1" {
                return "GROUP_A"
            }

            "2" {
                return "GROUP_B"
            }

            "3" {
                return "GROUP_C"
            }

            "4" {
                return "GROUP_A_SUB"
            }

            "5" {
                return "ALL"
            }

            default {
                Write-Host ""
                Write-Host "Invalid choice. Enter a number from 1 to 5." `
                    -ForegroundColor Yellow
                Write-Host ""
            }
        }
    }
}

# ============================================================
# ADMINISTRATOR CHECK
# ============================================================

if (-not (Test-Administrator)) {

    Write-Host ""
    Write-Host "ERROR: this installer must be run as administrator." `
        -ForegroundColor Red
    Write-Host ""

    exit 1
}

# ============================================================
# START
# ============================================================

Clear-Host

Write-InstallerLog "========================================"
Write-InstallerLog "===== ITSCRIPTS INSTALLER START ====="
Write-InstallerLog "========================================"

# ============================================================
# GROUP SELECTION
# ============================================================

$AgentGroup = Select-AgentGroup

Write-Host ""

Write-InstallerLog "INFO | Selected group: $AgentGroup"

# ============================================================
# CONFIRMATION
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "SELECTED CONFIGURATION"
Write-Host "========================================"
Write-Host ""
Write-Host "Install path : $InstallPath"
Write-Host "Group        : $AgentGroup"
Write-Host "FTP Server   : $DefaultFTPServer"
Write-Host "Task         : $TaskName"
Write-Host ""

$confirmation = Read-Host "Confirm installation? (Y/N)"

if ($confirmation.ToUpper() -ne "Y") {

    Write-Host ""
    Write-InstallerLog "INFO | Installation cancelled by the user"
    Write-Host ""

    exit 0
}

# ============================================================
# FTP SERVER DATA
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "FTP CONFIGURATION"
Write-Host "========================================"
Write-Host ""

# ------------------------------------------------------------
# DEFAULT FTP SERVER
# ------------------------------------------------------------

$ftpServer = $DefaultFTPServer

Write-InstallerLog "INFO | Default FTP Server: $ftpServer"

# ------------------------------------------------------------
# USERNAME AND PASSWORD
# ------------------------------------------------------------

$username = Read-Host `
    "Enter FTP username"

$securePassword = Read-Host `
    "Enter FTP password" `
    -AsSecureString

# ============================================================
# PASSWORD CONVERSION
# ============================================================

$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
    $securePassword
)

try {

    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        $ptr
    )
}
finally {

    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}

# ============================================================
# FTP VALIDATION
# ============================================================

if ([string]::IsNullOrWhiteSpace($ftpServer)) {

    Write-InstallerLog `
        "ERROR | FTP Server not specified"

    exit 1
}

if (-not $ftpServer.EndsWith("/")) {

    $ftpServer += "/"
}

if ([string]::IsNullOrWhiteSpace($username)) {

    Write-InstallerLog `
        "ERROR | FTP username not specified"

    exit 1
}

if ([string]::IsNullOrWhiteSpace($password)) {

    Write-InstallerLog `
        "ERROR | FTP password not specified"

    exit 1
}

Write-InstallerLog `
    "INFO | FTP Server: $ftpServer"

# ============================================================
# FOLDERS
# ============================================================

Write-InstallerLog `
    "INFO | Creating C:\ITScripts folder structure"

foreach ($folder in @(
    $InstallPath,
    $ScriptsPath,
    $LogsPath
)) {

    if (-not (Test-Path $folder)) {

        New-Item `
            -ItemType Directory `
            -Path $folder `
            -Force |
            Out-Null

        Write-InstallerLog `
            "CREATE | $folder"
    }
    else {

        Write-InstallerLog `
            "EXISTS | $folder"
    }
}

# ============================================================
# LOCATE AGENT.PS1
# ============================================================

$installerDirectory = Split-Path `
    -Parent `
    $MyInvocation.MyCommand.Path

$sourceAgentPath = Join-Path `
    $installerDirectory `
    "Agent.ps1"

if (-not (Test-Path $sourceAgentPath)) {

    Write-InstallerLog `
        "ERROR | Agent.ps1 not found"

    Write-InstallerLog `
        "INFO | Agent.ps1 must be in the same folder as Install.ps1"

    exit 1
}

# ============================================================
# COPY AGENT
# ============================================================

Copy-Item `
    -Path $sourceAgentPath `
    -Destination $AgentPath `
    -Force

Write-InstallerLog `
    "SUCCESS | Agent.ps1 installed"

# ============================================================
# CREATE AGENT-CONFIG.JSON
# ============================================================

$agentConfig = [ordered]@{

    ftpServer = $ftpServer
    username  = $username
    password  = $password
    group     = $AgentGroup
}

$agentConfig |
    ConvertTo-Json -Depth 5 |
    Set-Content `
        -Path $AgentConfigPath `
        -Encoding UTF8

Write-InstallerLog `
    "SUCCESS | agent-config.json created"

# ============================================================
# VERIFY CONFIGURATION
# ============================================================

try {

    $testConfig = Get-Content `
        $AgentConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json

    if ($testConfig.group -ne $AgentGroup) {

        throw `
            "Group configured incorrectly"
    }

    if ($testConfig.ftpServer -ne $ftpServer) {

        throw `
            "FTP server configured incorrectly"
    }

    Write-InstallerLog `
        "SUCCESS | Configuration verified"
}
catch {

    Write-InstallerLog `
        "ERROR | agent-config.json verification failed"

    Write-InstallerLog `
        "ERROR | $($_.Exception.Message)"

    exit 1
}

# ============================================================
# FTP TEST
# ============================================================

Write-InstallerLog `
    "INFO | Testing FTP connection"

try {

    $testUrl = $ftpServer + "config.json"

    $request = [System.Net.FtpWebRequest]::Create($testUrl)

    $request.Method = `
        [System.Net.WebRequestMethods+Ftp]::DownloadFile

    $request.Credentials = `
        New-Object System.Net.NetworkCredential(
            $username,
            $password
        )

    $request.UsePassive = $true
    $request.UseBinary = $true

    $request.Timeout = 10000
    $request.ReadWriteTimeout = 10000

    $response = $request.GetResponse()

    $response.Close()

    Write-InstallerLog `
        "SUCCESS | FTP connection verified"
}
catch {

    Write-InstallerLog `
        "WARN | FTP connection failed"

    Write-InstallerLog `
        "WARN | $($_.Exception.Message)"

    Write-Host ""
    Write-Host "WARNING: the FTP test did not succeed." `
        -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================
# SCHEDULED TASK
# ============================================================

Write-InstallerLog `
    "INFO | Configuring Task Scheduler"

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$AgentPath`""

# Run at startup
$triggerStartup = New-ScheduledTaskTrigger `
    -AtStartup

# --------------------------------------------------
# PERIODIC CHECK EVERY 5 MINUTES
# --------------------------------------------------
# The Agent autonomously decides which scripts are actually due.
#
# NOTE: DO NOT specify -RepetitionDuration. Two options were
# tested and both failed:
#   - (New-TimeSpan -Days 3650) -> the repetition trigger is
#     saved but then silently disappears from
#     Register-ScheduledTask (the task ended up with only the
#     startup trigger, no error raised)
#   - [TimeSpan]::MaxValue -> explicit "value out of range" error
#     (P99999999DT23H59M59S) from Set-ScheduledTask
#
# Omitting the parameter entirely makes Windows register the
# repetition as indefinite (equivalent to "Indefinitely" in the
# Task Scheduler UI), and is the only verified working form for
# an infinite repetition.

$triggerRepeat = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew

try {

    # Remove any previous task

    Unregister-ScheduledTask `
        -TaskName $TaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($triggerStartup, $triggerRepeat) `
        -Principal $principal `
        -Settings $settings `
        -Description "ITScripts Agent - Group $AgentGroup" |
        Out-Null

    Write-InstallerLog `
        "SUCCESS | Task '$TaskName' created"

    Write-InstallerLog `
        "INFO | Agent runs at startup and then every 5 minutes"

    # --------------------------------------------------
    # POST-REGISTRATION VERIFICATION
    # --------------------------------------------------
    # Checks that BOTH triggers were actually saved by Windows.
    # If the repeat trigger is missing, the task would look
    # correctly installed but the agent would actually only run
    # at PC startup, with no error reported.

    $registeredTask = Get-ScheduledTask -TaskName $TaskName

    $triggerTypes = $registeredTask.Triggers |
        ForEach-Object { $_.CimClass.CimClassName }

    $hasBootTrigger = $triggerTypes -contains "MSFT_TaskBootTrigger"
    $hasRepeatTrigger = $triggerTypes -contains "MSFT_TaskTimeTrigger"

    if (-not $hasBootTrigger -or -not $hasRepeatTrigger) {

        Write-InstallerLog `
            "ERROR | Trigger verification failed | Found: $($triggerTypes -join ', ')"

        Write-Host ""
        Write-Host "WARNING: the task was created but a trigger is missing." `
            -ForegroundColor Red
        Write-Host "The Agent might NOT repeat every 5 minutes as intended." `
            -ForegroundColor Red
        Write-Host "Check manually in Task Scheduler." `
            -ForegroundColor Red
        Write-Host ""
    }
    else {

        Write-InstallerLog `
            "SUCCESS | Both triggers verified (startup + repeat every 5 min)"
    }
}
catch {

    Write-InstallerLog `
        "ERROR | Unable to create the task"

    Write-InstallerLog `
        "ERROR | $($_.Exception.Message)"

    exit 1
}

# ============================================================
# INITIAL RUN
# ============================================================

Write-InstallerLog `
    "INFO | Running the Agent for the first time"

try {

    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "`"$AgentPath`""
        ) `
        -Wait `
        -NoNewWindow

    Write-InstallerLog `
        "SUCCESS | Agent executed"
}
catch {

    Write-InstallerLog `
        "WARN | Initial Agent run failed"

    Write-InstallerLog `
        "WARN | $($_.Exception.Message)"
}

# ============================================================
# END
# ============================================================

Write-Host ""

Write-InstallerLog "========================================"
Write-InstallerLog "===== ITSCRIPTS INSTALLER END ====="
Write-InstallerLog "========================================"

Write-Host ""
Write-Host "Installation completed." -ForegroundColor Green
Write-Host ""
Write-Host "Group        : $AgentGroup"
Write-Host "Install path : $InstallPath"
Write-Host "Agent        : $AgentPath"
Write-Host "Config       : $AgentConfigPath"
Write-Host "FTP Server   : $ftpServer"
Write-Host "Task         : $TaskName"
Write-Host ""
