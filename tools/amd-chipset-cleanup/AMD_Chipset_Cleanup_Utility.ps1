#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Continue'

# =========================================================
# App metadata
# =========================================================
$AppName = 'AMD Chipset Cleanup Utility'
$AppVersion = 'v2.3'

$ScriptRootPath = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptRootPath)) {
    $ScriptRootPath = (Get-Location).Path
}

$TimeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$LogDir = Join-Path $ScriptRootPath 'Logs'
$BackupRoot = Join-Path $ScriptRootPath "Backups\AMD_Cleanup_Backup_$TimeStamp"
$LogFile = Join-Path $LogDir "AMD_Chipset_Cleanup_$TimeStamp.log"
$ManifestFile = Join-Path $LogDir "AMD_Chipset_Cleanup_Manifest_$TimeStamp.json"
$SummaryFile = Join-Path $LogDir "AMD_Chipset_Cleanup_Summary_$TimeStamp.txt"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# =========================================================
# State
# =========================================================
$script:Summary = [ordered]@{
    ModeRun         = 'None'
    DryRun          = $false
    BackupEnabled   = $true
    ServicesStopped = 0
    ServicesStarted = 0
    ProcessesKilled = 0
    FoldersCleared  = 0
    FoldersRemoved  = 0
    FoldersBackedUp = 0
    WarningsLogged  = 0
    PendingReboot   = $false
    BackupLocation  = ''
    StartTime       = ''
    EndTime         = ''
}

$script:Manifest = [ordered]@{
    AppName    = $AppName
    Version    = $AppVersion
    TimeStamp  = (Get-Date).ToString('s')
    LogFile    = $LogFile
    BackupRoot = $BackupRoot
    Actions    = New-Object System.Collections.Generic.List[object]
}

$script:IsRunning = $false
$script:LastSummaryText = ''

$AmdFolders = @(
    'C:\AMD\Chipset_Software',
    'C:\AMD',
    'C:\Program Files (x86)\AMD\Chipset_Software',
    'C:\ProgramData\AMD',
    (Join-Path $env:ProgramData 'AMD'),
    (Join-Path $env:LOCALAPPDATA 'AMD'),
    (Join-Path $env:APPDATA 'AMD')
) | Select-Object -Unique

$InstallerProcesses = @(
    'msiexec',
    'AMD_Chipset_Drivers',
    'AMDInstallManager',
    'AMDInstaller',
    'AMDCleanupUtility',
    'setup'
)

$ServicesToManage = @(
    'wuauserv',
    'cryptSvc',
    'bits',
    'msiserver'
)

# =========================================================
# Admin check
# =========================================================
function Test-Administrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Ensure-AdminOrRestart {
    if (Test-Administrator) { return }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = 'runas'

    try { [System.Diagnostics.Process]::Start($psi) | Out-Null }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Administrator rights are required.",
            "Admin Required"
        ) | Out-Null
    }
    exit
}

# =========================================================
# Logging
# =========================================================
function Write-Log {
    param([string]$Level,[string]$Message)

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message
    Add-Content -Path $LogFile -Value $line

    if ($Level -in @('WARN','ERROR')) { $script:Summary.WarningsLogged++ }

    Append-Output "$Level : $Message"
}

function Append-Output {
    param([string]$Text)

    if ($script:txtOutput.InvokeRequired) {
        $script:txtOutput.Invoke([Action[string]]{
            param($msg)
            $script:txtOutput.AppendText($msg + "`r`n")
            $script:txtOutput.ScrollToCaret()
        }, $Text)
    } else {
        $script:txtOutput.AppendText($Text + "`r`n")
        $script:txtOutput.ScrollToCaret()
    }
}

# =========================================================
# Core operations
# =========================================================

function Stop-ManagedService {
    param([string]$Name)

    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -eq 'Running') {

            if ($script:chkDryRun.Checked) {
                Write-Log 'INFO' "DRY RUN: Would stop service: $Name"
                return
            }

            Write-Log 'INFO' "Stopping service: $Name"
            Stop-Service -Name $Name -Force -ErrorAction Stop
            $script:Summary.ServicesStopped++
            Write-Log 'OK' "Service stopped: $Name"
        }
    }
    catch {
        Write-Log 'WARN' "Service issue ($Name): $($_.Exception.Message)"
    }
}

function Start-ManagedService {
    param([string]$Name)

    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -ne 'Running') {

            if ($script:chkDryRun.Checked) {
                Write-Log 'INFO' "DRY RUN: Would start service: $Name"
                return
            }

            Write-Log 'INFO' "Starting service: $Name"
            Start-Service -Name $Name -ErrorAction Stop
            $script:Summary.ServicesStarted++
            Write-Log 'OK' "Service started: $Name"
        }
    }
    catch {
        Write-Log 'WARN' "Service start issue ($Name): $($_.Exception.Message)"
    }
}

function Stop-ManagedProcess {
    param([string]$Name)

    try {
        $procs = Get-Process -Name $Name -ErrorAction SilentlyContinue
        if ($procs) {

            if ($script:chkDryRun.Checked) {
                Write-Log 'INFO' "DRY RUN: Would kill process: $Name"
                return
            }

            Write-Log 'INFO' "Killing process: $Name"
            $procs | Stop-Process -Force
            $script:Summary.ProcessesKilled++
            Write-Log 'OK' "Process killed: $Name"
        }
    }
    catch {
        Write-Log 'WARN' "Process issue ($Name): $($_.Exception.Message)"
    }
}

function Clear-TargetFolder {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Log 'WARN' "Folder not found: $Path"
        return
    }

    if ($script:chkDryRun.Checked) {
        Write-Log 'INFO' "DRY RUN: Would clear folder: $Path"
        return
    }

    try {
        Write-Log 'INFO' "Clearing folder: $Path"
        Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        $script:Summary.FoldersCleared++
        Write-Log 'OK' "Cleared: $Path"
    }
    catch {
        Write-Log 'WARN' "Clear failed ($Path): $($_.Exception.Message)"
    }
}

function Backup-Folder {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return }

    if ($script:chkDryRun.Checked) {
        Write-Log 'INFO' "DRY RUN: Would backup: $Path"
        return
    }

    try {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
        $dest = Join-Path $BackupRoot ($Path -replace '[:\\]', '_')

        robocopy $Path $dest /E /R:1 /W:1 | Out-Null

        $script:Summary.FoldersBackedUp++
        $script:Summary.BackupLocation = $BackupRoot

        Write-Log 'OK' "Backed up: $Path"
    }
    catch {
        Write-Log 'WARN' "Backup failed ($Path): $($_.Exception.Message)"
    }
}

function Remove-Folder {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return }

    if ($script:chkDryRun.Checked) {
        Write-Log 'INFO' "DRY RUN: Would remove: $Path"
        return
    }

    try {
        Remove-Item $Path -Recurse -Force
        $script:Summary.FoldersRemoved++
        Write-Log 'OK' "Removed: $Path"
    }
    catch {
        Write-Log 'WARN' "Remove failed ($Path): $($_.Exception.Message)"
    }
}

# =========================================================
# Cleanup workflows
# =========================================================

function Run-BasicCleanup {

    $script:Summary.ModeRun = 'Basic Cleanup'

    Write-Log 'INFO' 'Stopping services...'
    foreach ($svc in $ServicesToManage) {
        Stop-ManagedService $svc
    }

    Write-Log 'INFO' 'Killing installer processes...'
    foreach ($proc in $InstallerProcesses) {
        Stop-ManagedProcess $proc
    }

    Write-Log 'INFO' 'Clearing Windows Update cache...'
    Clear-TargetFolder 'C:\Windows\SoftwareDistribution'
    Clear-TargetFolder 'C:\Windows\System32\catroot2'

    Write-Log 'INFO' 'Restarting services...'
    foreach ($svc in $ServicesToManage) {
        Start-ManagedService $svc
    }

    Write-Log 'OK' 'Basic cleanup complete.'
}

function Run-DeepCleanup {

    $script:Summary.ModeRun = 'Deep Cleanup'

    Run-BasicCleanup

    $folders = $AmdFolders | Where-Object { Test-Path $_ }

    if ($script:chkBackup.Checked) {
        Write-Log 'INFO' 'Backing up AMD folders...'
        foreach ($f in $folders) {
            Backup-Folder $f
        }
    }

    Write-Log 'INFO' 'Removing AMD folders...'
    foreach ($f in $folders) {
        Remove-Folder $f
    }

    Write-Log 'OK' 'Deep cleanup complete.'
}

# =========================================================
# UI helpers
# =========================================================

function Set-Status {
    param([string]$Text)
    $script:lblStatus.Text = "Status: $Text"
}

function Set-Progress {
    param([int]$Value, [string]$Text)

    if ($Value -lt 0) { $Value = 0 }
    if ($Value -gt 100) { $Value = 100 }

    $script:progressBar.Value = $Value
    if ($Text) {
        $script:lblProgress.Text = "Progress: $Text"
    }
}

function Reset-RunState {
    $script:Summary.ModeRun         = 'None'
    $script:Summary.DryRun          = $script:chkDryRun.Checked
    $script:Summary.BackupEnabled   = $script:chkBackup.Checked
    $script:Summary.ServicesStopped = 0
    $script:Summary.ServicesStarted = 0
    $script:Summary.ProcessesKilled = 0
    $script:Summary.FoldersCleared  = 0
    $script:Summary.FoldersRemoved  = 0
    $script:Summary.FoldersBackedUp = 0
    $script:Summary.WarningsLogged  = 0
    $script:Summary.PendingReboot   = $false
    $script:Summary.BackupLocation  = ''
    $script:Summary.StartTime       = (Get-Date).ToString('s')
    $script:Summary.EndTime         = ''
    $script:LastSummaryText         = ''
}

function Set-UiRunningState {
    param([bool]$Running)

    $script:IsRunning = $Running

    $script:btnRefresh.Enabled = -not $Running
    $script:btnBasic.Enabled = -not $Running
    $script:btnDeep.Enabled = -not $Running
    $script:btnOpenToolFolder.Enabled = -not $Running
    $script:btnOpenLogs.Enabled = -not $Running
    $script:btnOpenBackups.Enabled = -not $Running
    $script:btnExportSummary.Enabled = (-not $Running) -and ([bool]$script:LastSummaryText)
    $script:btnRebootNow.Enabled = (-not $Running) -and (-not $script:chkDryRun.Checked) -and ([bool]$script:LastSummaryText)
    $script:chkBackup.Enabled = -not $Running
    $script:chkDryRun.Enabled = -not $Running
}

# =========================================================
# Pending reboot check
# =========================================================

function Test-PendingReboot {
    $pending = $false

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $pending = $true
    }

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $pending = $true
    }

    try {
        $value = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        if ($null -ne $value.PendingFileRenameOperations) {
            $pending = $true
        }
    }
    catch {
    }

    $script:Summary.PendingReboot = $pending
    return $pending
}

function Refresh-PrecheckStatus {
    if (Test-PendingReboot) {
        $script:lblPending.Text = 'Pending reboot detected: YES'
        $script:lblPending.ForeColor = [System.Drawing.Color]::DarkRed
    }
    else {
        $script:lblPending.Text = 'Pending reboot detected: NO'
        $script:lblPending.ForeColor = [System.Drawing.Color]::DarkGreen
    }
}

# =========================================================
# Summary / results panel
# =========================================================

function Build-SummaryText {
    $pending = if ($script:Summary.PendingReboot) { 'YES' } else { 'NO' }
    $dryRun = if ($script:Summary.DryRun) { 'YES' } else { 'NO' }
    $backup = if ($script:Summary.BackupEnabled) { 'YES' } else { 'NO' }

@"
$AppName $AppVersion

Mode Run          : $($script:Summary.ModeRun)
Dry Run           : $dryRun
Backup Enabled    : $backup
Services Stopped  : $($script:Summary.ServicesStopped)
Services Started  : $($script:Summary.ServicesStarted)
Processes Killed  : $($script:Summary.ProcessesKilled)
Folders Cleared   : $($script:Summary.FoldersCleared)
Folders Removed   : $($script:Summary.FoldersRemoved)
Folders Backed Up : $($script:Summary.FoldersBackedUp)
Warnings Logged   : $($script:Summary.WarningsLogged)
Pending Reboot    : $pending
Start Time        : $($script:Summary.StartTime)
End Time          : $($script:Summary.EndTime)
Log File          : $LogFile
Manifest File     : $ManifestFile
Summary File      : $SummaryFile
Backup Location   : $($script:Summary.BackupLocation)
"@
}

function Save-SummaryFile {
    $script:LastSummaryText = Build-SummaryText
    Set-Content -Path $SummaryFile -Value $script:LastSummaryText -Encoding UTF8
}

function Set-ResultField {
    param(
        [System.Windows.Forms.Label]$Label,
        [string]$Value
    )
    $Label.Text = $Value
}

function Update-ResultsPanel {
    $pending = if ($script:Summary.PendingReboot) { 'YES' } else { 'NO' }
    $dryRun = if ($script:Summary.DryRun) { 'YES' } else { 'NO' }
    $backupEnabled = if ($script:Summary.BackupEnabled) { 'YES' } else { 'NO' }

    if ($script:Summary.WarningsLogged -gt 0) {
        $script:lblResultOverall.Text = 'Completed with warnings'
        $script:lblResultOverall.ForeColor = [System.Drawing.Color]::DarkOrange
    }
    else {
        $script:lblResultOverall.Text = 'Completed successfully'
        $script:lblResultOverall.ForeColor = [System.Drawing.Color]::DarkGreen
    }

    if ($script:Summary.DryRun) {
        $script:lblResultOverall.Text = 'Dry run completed'
        $script:lblResultOverall.ForeColor = [System.Drawing.Color]::SteelBlue
    }

    Set-ResultField $script:lblResultModeValue $script:Summary.ModeRun
    Set-ResultField $script:lblResultDryRunValue $dryRun
    Set-ResultField $script:lblResultBackupValue $backupEnabled
    Set-ResultField $script:lblResultPendingValue $pending
    Set-ResultField $script:lblResultServicesStoppedValue ([string]$script:Summary.ServicesStopped)
    Set-ResultField $script:lblResultServicesStartedValue ([string]$script:Summary.ServicesStarted)
    Set-ResultField $script:lblResultProcessesKilledValue ([string]$script:Summary.ProcessesKilled)
    Set-ResultField $script:lblResultFoldersClearedValue ([string]$script:Summary.FoldersCleared)
    Set-ResultField $script:lblResultFoldersRemovedValue ([string]$script:Summary.FoldersRemoved)
    Set-ResultField $script:lblResultFoldersBackedUpValue ([string]$script:Summary.FoldersBackedUp)
    Set-ResultField $script:lblResultWarningsValue ([string]$script:Summary.WarningsLogged)

    $script:txtResultLogFile.Text = $LogFile
    $script:txtResultManifestFile.Text = $ManifestFile
    $script:txtResultSummaryFile.Text = $SummaryFile
    $script:txtResultBackupLocation.Text = $script:Summary.BackupLocation

    foreach ($lbl in @(
        $script:lblResultModeValue,
        $script:lblResultDryRunValue,
        $script:lblResultBackupValue,
        $script:lblResultPendingValue,
        $script:lblResultWarningsValue
    )) {
        $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    }

    if ($script:Summary.PendingReboot) {
        $script:lblResultPendingValue.ForeColor = [System.Drawing.Color]::DarkRed
    }
    else {
        $script:lblResultPendingValue.ForeColor = [System.Drawing.Color]::DarkGreen
    }

    if ($script:Summary.WarningsLogged -gt 0) {
        $script:lblResultWarningsValue.ForeColor = [System.Drawing.Color]::DarkOrange
    }
    else {
        $script:lblResultWarningsValue.ForeColor = [System.Drawing.Color]::DarkGreen
    }

    $script:btnExportSummary.Enabled = [bool]$script:LastSummaryText
    $script:btnRebootNow.Enabled = -not $script:chkDryRun.Checked

    if ([string]::IsNullOrWhiteSpace($script:Summary.BackupLocation)) {
        $script:txtResultBackupLocation.Text = ''
        $script:btnOpenBackups.Enabled = Test-Path -LiteralPath (Join-Path $ScriptRootPath 'Backups')
    }
    else {
        $script:btnOpenBackups.Enabled = $true
    }
}

function Reset-ResultsPanel {
    $script:lblResultOverall.Text = 'No results yet'
    $script:lblResultOverall.ForeColor = [System.Drawing.Color]::DimGray

    foreach ($lbl in @(
        $script:lblResultModeValue,
        $script:lblResultDryRunValue,
        $script:lblResultBackupValue,
        $script:lblResultPendingValue,
        $script:lblResultServicesStoppedValue,
        $script:lblResultServicesStartedValue,
        $script:lblResultProcessesKilledValue,
        $script:lblResultFoldersClearedValue,
        $script:lblResultFoldersRemovedValue,
        $script:lblResultFoldersBackedUpValue,
        $script:lblResultWarningsValue
    )) {
        $lbl.Text = '-'
        $lbl.ForeColor = [System.Drawing.Color]::Black
        $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    }

    $script:txtResultLogFile.Text = ''
    $script:txtResultManifestFile.Text = ''
    $script:txtResultSummaryFile.Text = ''
    $script:txtResultBackupLocation.Text = ''

    $script:btnExportSummary.Enabled = $false
    $script:btnRebootNow.Enabled = $false
}

function Open-PathIfExists {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    if (Test-Path -LiteralPath $Path) {
        Start-Process explorer.exe $Path
    }
    else {
        [System.Windows.Forms.MessageBox]::Show(
            "Path not found:`r`n$Path",
            "Not Found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Reboot-Now {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Reboot now?",
        "Confirm Reboot",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Restart-Computer -Force
    }
}

# =========================================================
# Run wrapper
# =========================================================

function Invoke-CleanupAction {
    param(
        [ValidateSet('Basic', 'Deep')]
        [string]$Mode
    )

    if ($script:IsRunning) { return }

    $script:txtOutput.Clear()
    Reset-RunState
    Reset-ResultsPanel
    Set-UiRunningState -Running $true
    Refresh-PrecheckStatus
    Set-Status "Running $Mode cleanup..."
    Set-Progress -Value 0 -Text 'Starting'

    try {
        if ($Mode -eq 'Basic') {
            Run-BasicCleanup
        }
        else {
            Run-DeepCleanup
        }

        $script:Summary.EndTime = (Get-Date).ToString('s')
        Refresh-PrecheckStatus
        Save-SummaryFile
        Set-Status "$Mode cleanup complete"
        Update-ResultsPanel
    }
    catch {
        Write-Log 'ERROR' "Unexpected failure: $($_.Exception.Message)"
        $script:Summary.EndTime = (Get-Date).ToString('s')
        Save-SummaryFile
        Set-Status 'Error'
        Update-ResultsPanel

        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred.`r`n`r`n$($_.Exception.Message)",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        Set-UiRunningState -Running $false
        Refresh-PrecheckStatus
        $script:btnExportSummary.Enabled = [bool]$script:LastSummaryText
        $form.ActiveControl = $btnRefresh
    }
}

# =========================================================
# Admin check before UI
# =========================================================
Ensure-AdminOrRestart

# =========================================================
# Form
# =========================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "$AppName $AppVersion"
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None

$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$desiredWidth = 1020
$desiredHeight = 760
$finalWidth = [Math]::Min($desiredWidth, $workingArea.Width - 40)
$finalHeight = [Math]::Min($desiredHeight, $workingArea.Height - 40)

$form.Size = New-Object System.Drawing.Size($finalWidth, $finalHeight)
$form.MinimumSize = New-Object System.Drawing.Size(980, 700)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = $AppName
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20,15)
$form.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = 'Cleans Windows Update, MSI, and AMD installer leftovers that can cause chipset installs to hang or stall.'
$lblSubtitle.AutoSize = $true
$lblSubtitle.Location = New-Object System.Drawing.Point(22,50)
$form.Controls.Add($lblSubtitle)

$lblPending = New-Object System.Windows.Forms.Label
$lblPending.Text = 'Pending reboot detected: checking...'
$lblPending.AutoSize = $true
$lblPending.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
$lblPending.Location = New-Object System.Drawing.Point(22,80)
$form.Controls.Add($lblPending)

$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.Text = 'Back up AMD folders before Deep Cleanup'
$chkBackup.AutoSize = $true
$chkBackup.Checked = $true
$chkBackup.Location = New-Object System.Drawing.Point(24,115)
$form.Controls.Add($chkBackup)

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = 'Dry Run mode'
$chkDryRun.AutoSize = $true
$chkDryRun.Checked = $false
$chkDryRun.Location = New-Object System.Drawing.Point(24,145)
$form.Controls.Add($chkDryRun)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh Status'
$btnRefresh.Size = New-Object System.Drawing.Size(130,34)
$btnRefresh.Location = New-Object System.Drawing.Point(24,185)
$form.Controls.Add($btnRefresh)

$btnBasic = New-Object System.Windows.Forms.Button
$btnBasic.Text = 'Run Basic Cleanup'
$btnBasic.Size = New-Object System.Drawing.Size(180,44)
$btnBasic.Location = New-Object System.Drawing.Point(24,235)
$form.Controls.Add($btnBasic)

$btnDeep = New-Object System.Windows.Forms.Button
$btnDeep.Text = 'Run Deep Cleanup'
$btnDeep.Size = New-Object System.Drawing.Size(180,44)
$btnDeep.Location = New-Object System.Drawing.Point(220,235)
$form.Controls.Add($btnDeep)

$btnOpenToolFolder = New-Object System.Windows.Forms.Button
$btnOpenToolFolder.Text = 'Open Tool Folder'
$btnOpenToolFolder.Size = New-Object System.Drawing.Size(130,34)
$btnOpenToolFolder.Location = New-Object System.Drawing.Point(170,185)
$form.Controls.Add($btnOpenToolFolder)

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Text = 'Open Logs'
$btnOpenLogs.Size = New-Object System.Drawing.Size(110,34)
$btnOpenLogs.Location = New-Object System.Drawing.Point(314,185)
$form.Controls.Add($btnOpenLogs)

$btnOpenBackups = New-Object System.Windows.Forms.Button
$btnOpenBackups.Text = 'Open Backups'
$btnOpenBackups.Size = New-Object System.Drawing.Size(120,34)
$btnOpenBackups.Location = New-Object System.Drawing.Point(438,185)
$form.Controls.Add($btnOpenBackups)

$btnExportSummary = New-Object System.Windows.Forms.Button
$btnExportSummary.Text = 'Export Summary'
$btnExportSummary.Size = New-Object System.Drawing.Size(130,34)
$btnExportSummary.Location = New-Object System.Drawing.Point(572,185)
$btnExportSummary.Enabled = $false
$form.Controls.Add($btnExportSummary)

$txtInfo = New-Object System.Windows.Forms.TextBox
$txtInfo.Multiline = $true
$txtInfo.ReadOnly = $true
$txtInfo.ScrollBars = 'Vertical'
$txtInfo.Size = New-Object System.Drawing.Size(955,95)
$txtInfo.Location = New-Object System.Drawing.Point(24,295)
$txtInfo.TabStop = $false
$txtInfo.ShortcutsEnabled = $false
$txtInfo.HideSelection = $true
$txtInfo.Text = @"
Basic Cleanup:
Stops update and installer services, kills stuck installer processes, clears Windows Update cache folders, then restarts services.

Deep Cleanup:
Includes Basic Cleanup plus removal of AMD temp and extracted installer folders like C:\AMD.
Installed chipset drivers are NOT removed.

Recommendation:
Use Basic Cleanup first. Use Deep Cleanup only if needed. Leave Backup enabled.
"@
$form.Controls.Add($txtInfo)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Size = New-Object System.Drawing.Size(955,22)
$progressBar.Location = New-Object System.Drawing.Point(24,405)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$form.Controls.Add($progressBar)

$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text = 'Progress: Ready'
$lblProgress.AutoSize = $true
$lblProgress.Location = New-Object System.Drawing.Point(24,432)
$form.Controls.Add($lblProgress)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Multiline = $true
$txtOutput.ReadOnly = $true
$txtOutput.ScrollBars = 'Vertical'
$txtOutput.Size = New-Object System.Drawing.Size(955,120)
$txtOutput.Location = New-Object System.Drawing.Point(24,460)
$txtOutput.Font = New-Object System.Drawing.Font('Consolas',9)
$txtOutput.TabStop = $false
$txtOutput.ShortcutsEnabled = $false
$txtOutput.HideSelection = $true
$form.Controls.Add($txtOutput)

$grpResults = New-Object System.Windows.Forms.GroupBox
$grpResults.Text = 'Results'
$grpResults.Size = New-Object System.Drawing.Size(955,205)
$grpResults.Location = New-Object System.Drawing.Point(24,590)
$form.Controls.Add($grpResults)

$lblResultOverallTitle = New-Object System.Windows.Forms.Label
$lblResultOverallTitle.Text = 'Overall Status:'
$lblResultOverallTitle.AutoSize = $true
$lblResultOverallTitle.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$lblResultOverallTitle.Location = New-Object System.Drawing.Point(15,28)
$grpResults.Controls.Add($lblResultOverallTitle)

$lblResultOverall = New-Object System.Windows.Forms.Label
$lblResultOverall.Text = 'No results yet'
$lblResultOverall.AutoSize = $true
$lblResultOverall.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$lblResultOverall.ForeColor = [System.Drawing.Color]::DimGray
$lblResultOverall.Location = New-Object System.Drawing.Point(120,28)
$grpResults.Controls.Add($lblResultOverall)

$lblResultMode = New-Object System.Windows.Forms.Label
$lblResultMode.Text = 'Mode Run:'
$lblResultMode.AutoSize = $true
$lblResultMode.Location = New-Object System.Drawing.Point(15,58)
$grpResults.Controls.Add($lblResultMode)

$lblResultModeValue = New-Object System.Windows.Forms.Label
$lblResultModeValue.Text = '-'
$lblResultModeValue.AutoSize = $true
$lblResultModeValue.Location = New-Object System.Drawing.Point(120,58)
$grpResults.Controls.Add($lblResultModeValue)

$lblResultDryRun = New-Object System.Windows.Forms.Label
$lblResultDryRun.Text = 'Dry Run:'
$lblResultDryRun.AutoSize = $true
$lblResultDryRun.Location = New-Object System.Drawing.Point(15,80)
$grpResults.Controls.Add($lblResultDryRun)

$lblResultDryRunValue = New-Object System.Windows.Forms.Label
$lblResultDryRunValue.Text = '-'
$lblResultDryRunValue.AutoSize = $true
$lblResultDryRunValue.Location = New-Object System.Drawing.Point(120,80)
$grpResults.Controls.Add($lblResultDryRunValue)

$lblResultBackup = New-Object System.Windows.Forms.Label
$lblResultBackup.Text = 'Backup Enabled:'
$lblResultBackup.AutoSize = $true
$lblResultBackup.Location = New-Object System.Drawing.Point(15,102)
$grpResults.Controls.Add($lblResultBackup)

$lblResultBackupValue = New-Object System.Windows.Forms.Label
$lblResultBackupValue.Text = '-'
$lblResultBackupValue.AutoSize = $true
$lblResultBackupValue.Location = New-Object System.Drawing.Point(120,102)
$grpResults.Controls.Add($lblResultBackupValue)

$lblResultPending = New-Object System.Windows.Forms.Label
$lblResultPending.Text = 'Pending Reboot:'
$lblResultPending.AutoSize = $true
$lblResultPending.Location = New-Object System.Drawing.Point(15,124)
$grpResults.Controls.Add($lblResultPending)

$lblResultPendingValue = New-Object System.Windows.Forms.Label
$lblResultPendingValue.Text = '-'
$lblResultPendingValue.AutoSize = $true
$lblResultPendingValue.Location = New-Object System.Drawing.Point(120,124)
$grpResults.Controls.Add($lblResultPendingValue)

$lblResultWarnings = New-Object System.Windows.Forms.Label
$lblResultWarnings.Text = 'Warnings Logged:'
$lblResultWarnings.AutoSize = $true
$lblResultWarnings.Location = New-Object System.Drawing.Point(15,146)
$grpResults.Controls.Add($lblResultWarnings)

$lblResultWarningsValue = New-Object System.Windows.Forms.Label
$lblResultWarningsValue.Text = '-'
$lblResultWarningsValue.AutoSize = $true
$lblResultWarningsValue.Location = New-Object System.Drawing.Point(120,146)
$grpResults.Controls.Add($lblResultWarningsValue)

$lblResultServicesStopped = New-Object System.Windows.Forms.Label
$lblResultServicesStopped.Text = 'Services Stopped:'
$lblResultServicesStopped.AutoSize = $true
$lblResultServicesStopped.Location = New-Object System.Drawing.Point(285,58)
$grpResults.Controls.Add($lblResultServicesStopped)

$lblResultServicesStoppedValue = New-Object System.Windows.Forms.Label
$lblResultServicesStoppedValue.Text = '-'
$lblResultServicesStoppedValue.AutoSize = $true
$lblResultServicesStoppedValue.Location = New-Object System.Drawing.Point(415,58)
$grpResults.Controls.Add($lblResultServicesStoppedValue)

$lblResultServicesStarted = New-Object System.Windows.Forms.Label
$lblResultServicesStarted.Text = 'Services Started:'
$lblResultServicesStarted.AutoSize = $true
$lblResultServicesStarted.Location = New-Object System.Drawing.Point(285,80)
$grpResults.Controls.Add($lblResultServicesStarted)

$lblResultServicesStartedValue = New-Object System.Windows.Forms.Label
$lblResultServicesStartedValue.Text = '-'
$lblResultServicesStartedValue.AutoSize = $true
$lblResultServicesStartedValue.Location = New-Object System.Drawing.Point(415,80)
$grpResults.Controls.Add($lblResultServicesStartedValue)

$lblResultProcessesKilled = New-Object System.Windows.Forms.Label
$lblResultProcessesKilled.Text = 'Processes Killed:'
$lblResultProcessesKilled.AutoSize = $true
$lblResultProcessesKilled.Location = New-Object System.Drawing.Point(285,102)
$grpResults.Controls.Add($lblResultProcessesKilled)

$lblResultProcessesKilledValue = New-Object System.Windows.Forms.Label
$lblResultProcessesKilledValue.Text = '-'
$lblResultProcessesKilledValue.AutoSize = $true
$lblResultProcessesKilledValue.Location = New-Object System.Drawing.Point(415,102)
$grpResults.Controls.Add($lblResultProcessesKilledValue)

$lblResultFoldersCleared = New-Object System.Windows.Forms.Label
$lblResultFoldersCleared.Text = 'Folders Cleared:'
$lblResultFoldersCleared.AutoSize = $true
$lblResultFoldersCleared.Location = New-Object System.Drawing.Point(285,124)
$grpResults.Controls.Add($lblResultFoldersCleared)

$lblResultFoldersClearedValue = New-Object System.Windows.Forms.Label
$lblResultFoldersClearedValue.Text = '-'
$lblResultFoldersClearedValue.AutoSize = $true
$lblResultFoldersClearedValue.Location = New-Object System.Drawing.Point(415,124)
$grpResults.Controls.Add($lblResultFoldersClearedValue)

$lblResultFoldersRemoved = New-Object System.Windows.Forms.Label
$lblResultFoldersRemoved.Text = 'Folders Removed:'
$lblResultFoldersRemoved.AutoSize = $true
$lblResultFoldersRemoved.Location = New-Object System.Drawing.Point(285,146)
$grpResults.Controls.Add($lblResultFoldersRemoved)

$lblResultFoldersRemovedValue = New-Object System.Windows.Forms.Label
$lblResultFoldersRemovedValue.Text = '-'
$lblResultFoldersRemovedValue.AutoSize = $true
$lblResultFoldersRemovedValue.Location = New-Object System.Drawing.Point(415,146)
$grpResults.Controls.Add($lblResultFoldersRemovedValue)

$lblResultFoldersBackedUp = New-Object System.Windows.Forms.Label
$lblResultFoldersBackedUp.Text = 'Folders Backed Up:'
$lblResultFoldersBackedUp.AutoSize = $true
$lblResultFoldersBackedUp.Location = New-Object System.Drawing.Point(285,168)
$grpResults.Controls.Add($lblResultFoldersBackedUp)

$lblResultFoldersBackedUpValue = New-Object System.Windows.Forms.Label
$lblResultFoldersBackedUpValue.Text = '-'
$lblResultFoldersBackedUpValue.AutoSize = $true
$lblResultFoldersBackedUpValue.Location = New-Object System.Drawing.Point(415,168)
$grpResults.Controls.Add($lblResultFoldersBackedUpValue)

$lblResultLogFile = New-Object System.Windows.Forms.Label
$lblResultLogFile.Text = 'Log File:'
$lblResultLogFile.AutoSize = $true
$lblResultLogFile.Location = New-Object System.Drawing.Point(540,58)
$grpResults.Controls.Add($lblResultLogFile)

$txtResultLogFile = New-Object System.Windows.Forms.TextBox
$txtResultLogFile.ReadOnly = $true
$txtResultLogFile.Size = New-Object System.Drawing.Size(335,20)
$txtResultLogFile.Location = New-Object System.Drawing.Point(625,55)
$txtResultLogFile.TabStop = $false
$grpResults.Controls.Add($txtResultLogFile)

$lblResultManifestFile = New-Object System.Windows.Forms.Label
$lblResultManifestFile.Text = 'Manifest:'
$lblResultManifestFile.AutoSize = $true
$lblResultManifestFile.Location = New-Object System.Drawing.Point(540,84)
$grpResults.Controls.Add($lblResultManifestFile)

$txtResultManifestFile = New-Object System.Windows.Forms.TextBox
$txtResultManifestFile.ReadOnly = $true
$txtResultManifestFile.Size = New-Object System.Drawing.Size(335,20)
$txtResultManifestFile.Location = New-Object System.Drawing.Point(625,81)
$txtResultManifestFile.TabStop = $false
$grpResults.Controls.Add($txtResultManifestFile)

$lblResultSummaryFile = New-Object System.Windows.Forms.Label
$lblResultSummaryFile.Text = 'Summary:'
$lblResultSummaryFile.AutoSize = $true
$lblResultSummaryFile.Location = New-Object System.Drawing.Point(540,110)
$grpResults.Controls.Add($lblResultSummaryFile)

$txtResultSummaryFile = New-Object System.Windows.Forms.TextBox
$txtResultSummaryFile.ReadOnly = $true
$txtResultSummaryFile.Size = New-Object System.Drawing.Size(335,20)
$txtResultSummaryFile.Location = New-Object System.Drawing.Point(625,107)
$txtResultSummaryFile.TabStop = $false
$grpResults.Controls.Add($txtResultSummaryFile)

$lblResultBackupLocation = New-Object System.Windows.Forms.Label
$lblResultBackupLocation.Text = 'Backup Folder:'
$lblResultBackupLocation.AutoSize = $true
$lblResultBackupLocation.Location = New-Object System.Drawing.Point(540,136)
$grpResults.Controls.Add($lblResultBackupLocation)

$txtResultBackupLocation = New-Object System.Windows.Forms.TextBox
$txtResultBackupLocation.ReadOnly = $true
$txtResultBackupLocation.Size = New-Object System.Drawing.Size(335,20)
$txtResultBackupLocation.Location = New-Object System.Drawing.Point(625,133)
$txtResultBackupLocation.TabStop = $false
$grpResults.Controls.Add($txtResultBackupLocation)

$btnRebootNow = New-Object System.Windows.Forms.Button
$btnRebootNow.Text = 'Reboot Now'
$btnRebootNow.Size = New-Object System.Drawing.Size(110,28)
$btnRebootNow.Location = New-Object System.Drawing.Point(850,165)
$btnRebootNow.Enabled = $false
$grpResults.Controls.Add($btnRebootNow)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Status: Ready'
$lblStatus.AutoSize = $true
$lblStatus.Location = New-Object System.Drawing.Point(24,685)
$form.Controls.Add($lblStatus)

# =========================================================
# Bind script refs
# =========================================================
$script:txtOutput = $txtOutput
$script:lblStatus = $lblStatus
$script:chkDryRun = $chkDryRun
$script:chkBackup = $chkBackup
$script:lblPending = $lblPending
$script:progressBar = $progressBar
$script:lblProgress = $lblProgress
$script:btnRefresh = $btnRefresh
$script:btnBasic = $btnBasic
$script:btnDeep = $btnDeep
$script:btnOpenToolFolder = $btnOpenToolFolder
$script:btnOpenLogs = $btnOpenLogs
$script:btnOpenBackups = $btnOpenBackups
$script:btnExportSummary = $btnExportSummary
$script:btnRebootNow = $btnRebootNow

$script:lblResultOverall = $lblResultOverall
$script:lblResultModeValue = $lblResultModeValue
$script:lblResultDryRunValue = $lblResultDryRunValue
$script:lblResultBackupValue = $lblResultBackupValue
$script:lblResultPendingValue = $lblResultPendingValue
$script:lblResultWarningsValue = $lblResultWarningsValue
$script:lblResultServicesStoppedValue = $lblResultServicesStoppedValue
$script:lblResultServicesStartedValue = $lblResultServicesStartedValue
$script:lblResultProcessesKilledValue = $lblResultProcessesKilledValue
$script:lblResultFoldersClearedValue = $lblResultFoldersClearedValue
$script:lblResultFoldersRemovedValue = $lblResultFoldersRemovedValue
$script:lblResultFoldersBackedUpValue = $lblResultFoldersBackedUpValue
$script:txtResultLogFile = $txtResultLogFile
$script:txtResultManifestFile = $txtResultManifestFile
$script:txtResultSummaryFile = $txtResultSummaryFile
$script:txtResultBackupLocation = $txtResultBackupLocation

# =========================================================
# Events
# =========================================================
$btnRefresh.Add_Click({
    Refresh-PrecheckStatus
    Set-Status 'Status refreshed'
    Set-Progress -Value 0 -Text 'Ready'
})

$btnOpenToolFolder.Add_Click({
    Open-PathIfExists -Path $ScriptRootPath
})

$btnOpenLogs.Add_Click({
    Open-PathIfExists -Path $LogDir
})

$btnOpenBackups.Add_Click({
    if ($script:Summary.BackupLocation) {
        Open-PathIfExists -Path $script:Summary.BackupLocation
    }
    else {
        $defaultBackupParent = Join-Path $ScriptRootPath 'Backups'
        Open-PathIfExists -Path $defaultBackupParent
    }
})

$btnExportSummary.Add_Click({
    if (-not $script:LastSummaryText) { return }
    try {
        Save-SummaryFile
        [System.Windows.Forms.MessageBox]::Show(
            "Summary exported to:`r`n$SummaryFile",
            "Summary Exported",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not export summary.`r`n`r`n$($_.Exception.Message)",
            "Export Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$btnRebootNow.Add_Click({
    Reboot-Now
})

$btnBasic.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Run Basic Cleanup now?",
        "Confirm Basic Cleanup",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
        Invoke-CleanupAction -Mode 'Basic'
    }
})

$btnDeep.Add_Click({
    $confirmText = "Deep Cleanup may remove downloaded AMD installer files and extracted folders like C:\AMD.`r`n`r`nInstalled chipset drivers are not removed.`r`n`r`nContinue?"
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        $confirmText,
        "Confirm Deep Cleanup",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
        Invoke-CleanupAction -Mode 'Deep'
    }
})

$form.Add_Shown({
    Refresh-PrecheckStatus
    Reset-ResultsPanel
    Set-Status 'Ready'
    Set-Progress -Value 0 -Text 'Ready'
})

[void]$form.ShowDialog()