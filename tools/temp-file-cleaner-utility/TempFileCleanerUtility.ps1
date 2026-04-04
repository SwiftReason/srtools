#requires -version 5.1
<#
Temp File Cleaner Utility
Version: 2.0

Description:
A modern Windows cleanup utility with Scan, Cleanup, presets, summaries, and safer aggressive options.

Credit:
This utility was inspired by the legacy cleanup approach used in Hiren's utility collection.
This is a separate, modernized PowerShell GUI implementation.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppName    = 'Temp File Cleaner Utility'
$AppVersion = 'v2.0'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogDir     = Join-Path $ScriptRoot 'Logs'
$SummaryDir = Join-Path $ScriptRoot 'Summaries'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $SummaryDir -Force | Out-Null

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-AdminOrRestart {
    if (Test-IsAdmin) { return }

    [System.Windows.Forms.MessageBox]::Show(
        "This tool needs Administrator rights to clean system and all-user locations.`r`n`r`nClick OK to relaunch as Administrator.",
        $AppName,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if (-not $scriptPath) { exit }

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Elevation was cancelled. The tool cannot continue.",
            $AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    exit
}

Ensure-AdminOrRestart

$script:IsRunning = $false
$script:ApplyingPreset = $false
$script:CurrentLogFile = $null
$script:CurrentSummaryFile = $null
$script:LastSummaryText = ''
$script:RunData = $null

function New-RunData {
    [ordered]@{
        Mode               = ''
        Preset             = ''
        StartTime          = (Get-Date).ToString('s')
        EndTime            = ''
        PathsChecked       = 0
        PathsMissing       = 0
        FilesSeen          = 0
        DirectoriesSeen    = 0
        FilesDeleted       = 0
        DirectoriesDeleted = 0
        Skipped            = 0
        Locked             = 0
        Errors             = 0
        EstimatedBytes     = [int64]0
        Categories         = New-Object System.Collections.Generic.List[string]
    }
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Start-NewLog {
    $script:CurrentLogFile = Join-Path $LogDir ("TempCleaner_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType File -Path $script:CurrentLogFile -Force | Out-Null
}

function Write-LogLine {
    param(
        [string]$Level,
        [string]$Text
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Text
    try { Add-Content -Path $script:CurrentLogFile -Value $line -Encoding UTF8 } catch { }
    $txtLog.AppendText($line + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Status {
    param([string]$Text)
    $lblStatus.Text = "Status: $Text"
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-CurrentAction {
    param([string]$Text)
    $lblCurrentAction.Text = "Current action: $Text"
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-ProgressSafe {
    param([int]$Value)
    $progressBar.Value = [Math]::Max(0, [Math]::Min(100, $Value))
    $lblProgressPercent.Text = ("{0}%%" -f $progressBar.Value)
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-RunState {
    param([bool]$Running)
    $script:IsRunning = $Running
    $btnScan.Enabled = -not $Running
    $btnRun.Enabled = -not $Running
    $btnExport.Enabled = (-not $Running) -and [bool]$script:LastSummaryText
    $btnOpenLog.Enabled = -not $Running
    $cmbPreset.Enabled = -not $Running
    $chkSystemTemp.Enabled = -not $Running
    $chkAllUserTemp.Enabled = -not $Running
    $chkBrowserCaches.Enabled = -not $Running
    $chkPrinterSpool.Enabled = -not $Running
    $chkRecycleBin.Enabled = -not $Running
    $chkPrefetch.Enabled = -not $Running
    $chkEventLogs.Enabled = -not $Running
    $chkShadowCopies.Enabled = -not $Running
    $chkVerbose.Enabled = -not $Running
}

function Update-SummaryPanel {
    if (-not $script:RunData) { return }
    $d = $script:RunData
    $trueErrors = [Math]::Max(0, ($d.Errors - $d.Locked))
    $lblModeValue.Text = $d.Mode
    $lblPresetValue.Text = $d.Preset
    $lblPathsValue.Text = ("{0} checked, {1} not present" -f $d.PathsChecked, $d.PathsMissing)
    $lblFilesValue.Text = ("{0} seen, {1} deleted" -f $d.FilesSeen, $d.FilesDeleted)
    $lblDirsValue.Text = ("{0} seen, {1} deleted" -f $d.DirectoriesSeen, $d.DirectoriesDeleted)
    $lblSkippedValue.Text = ("{0} skipped, {1} locked" -f $d.Skipped, $d.Locked)
    $lblErrorsValue.Text = [string]$trueErrors
    $lblSpaceValue.Text = Format-Bytes $d.EstimatedBytes
}

function Get-UserProfiles {
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public','Default','Default User','All Users','defaultuser0') }
}

function Get-EnabledCategories {
    $categories = @()

    if ($chkSystemTemp.Checked) {
        $categories += [pscustomobject]@{
            Name = 'System Temp'
            Paths = @(
                "$env:windir\Temp",
                "$env:windir\Logs",
                "$env:windir\Minidump",
                "$env:windir\SoftwareDistribution\Download"
            )
        }
    }

    if ($chkAllUserTemp.Checked) {
        $paths = @()
        foreach ($profile in (Get-UserProfiles)) {
            $paths += Join-Path $profile.FullName 'AppData\Local\Temp'
            $paths += Join-Path $profile.FullName 'AppData\Local\CrashDumps'
            $paths += Join-Path $profile.FullName 'AppData\Local\Microsoft\Windows\INetCache'
            $paths += Join-Path $profile.FullName 'AppData\Local\Microsoft\Windows\Explorer'
            $paths += Join-Path $profile.FullName 'AppData\Local\Microsoft\Windows\WER'
        }
        $categories += [pscustomobject]@{
            Name = 'All User Temp'
            Paths = $paths
        }
    }

    if ($chkBrowserCaches.Checked) {
        $paths = @()
        foreach ($profile in (Get-UserProfiles)) {
            $paths += Join-Path $profile.FullName 'AppData\Local\Google\Chrome\User Data\Default\Cache'
            $paths += Join-Path $profile.FullName 'AppData\Local\Google\Chrome\User Data\Default\Code Cache'
            $paths += Join-Path $profile.FullName 'AppData\Local\Microsoft\Edge\User Data\Default\Cache'
            $paths += Join-Path $profile.FullName 'AppData\Local\Microsoft\Edge\User Data\Default\Code Cache'
            $paths += Join-Path $profile.FullName 'AppData\Local\Mozilla\Firefox\Profiles'
        }
        $categories += [pscustomobject]@{
            Name = 'Browser Caches'
            Paths = $paths
        }
    }

    if ($chkPrinterSpool.Checked) {
        $categories += [pscustomobject]@{
            Name = 'Printer Spool Temp'
            Paths = @("$env:windir\System32\spool\PRINTERS")
        }
    }

    if ($chkPrefetch.Checked) {
        $categories += [pscustomobject]@{
            Name = 'Prefetch'
            Paths = @("$env:windir\Prefetch")
        }
    }

    return $categories
}

function Process-Path {
    param(
        [string]$Path,
        [ValidateSet('Scan','Cleanup')] [string]$Mode,
        [bool]$Verbose
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        $script:RunData.PathsMissing++
        if ($Verbose) { Write-LogLine INFO "Missing path: $Path" }
        return
    }

    $script:RunData.PathsChecked++

    try {
        $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    }
    catch {
        $script:RunData.Errors++
        Write-LogLine ERROR "Could not enumerate $Path. $($_.Exception.Message)"
        return
    }

    $localFilesSeen = 0
    $localDirsSeen = 0
    $localFilesDeleted = 0
    $localDirsDeleted = 0
    $localSkipped = 0
    $localLocked = 0
    $localBytes = [int64]0

    foreach ($item in $items) {
        try {
            if ($item.PSIsContainer) {
                $localDirsSeen++
                $script:RunData.DirectoriesSeen++

                try {
                    $measure = Get-ChildItem -LiteralPath $item.FullName -Force -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
                    if ($measure.Sum) { $localBytes += [int64]$measure.Sum }
                } catch { }

                if ($Mode -eq 'Cleanup') {
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                    $localDirsDeleted++
                    $script:RunData.DirectoriesDeleted++
                    if ($Verbose) { Write-LogLine SUCCESS "Removed directory: $($item.FullName)" }
                }
            }
            else {
                $localFilesSeen++
                $script:RunData.FilesSeen++
                if ($item.PSObject.Properties.Name -contains 'Length' -and $item.Length) {
                    $localBytes += [int64]$item.Length
                }

                if ($Mode -eq 'Cleanup') {
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                    $localFilesDeleted++
                    $script:RunData.FilesDeleted++
                    if ($Verbose) { Write-LogLine SUCCESS "Deleted file: $($item.FullName)" }
                }
            }
        }
        catch {
            $script:RunData.Errors++
            $localSkipped++
            $script:RunData.Skipped++

            if ($_.Exception.Message -match 'being used by another process|cannot access the file|used by another process') {
                $localLocked++
                $script:RunData.Locked++
            }

            if ($Verbose) {
                Write-LogLine WARN "Skipped item: $($item.FullName)"
            }
        }
    }

    $script:RunData.EstimatedBytes += $localBytes

    $summaryText = "{0}: Files {1}, Dirs {2}, Estimated {3}" -f $Path, $localFilesSeen, $localDirsSeen, (Format-Bytes $localBytes)
    if ($Mode -eq 'Cleanup') {
        $summaryText += ", Deleted Files {0}, Deleted Dirs {1}, Skipped {2}" -f $localFilesDeleted, $localDirsDeleted, $localSkipped
    }
    Write-LogLine INFO $summaryText
}

function Clear-RecycleBinSafe {
    param([string]$Mode)
    if (-not $chkRecycleBin.Checked) { return }

    if ($Mode -eq 'Scan') {
        Write-LogLine INFO "Recycle Bin: included in scan summary, actual item count not enumerated."
        return
    }

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-LogLine SUCCESS "Recycle Bin cleared."
    }
    catch {
        $script:RunData.Errors++
        Write-LogLine WARN "Could not clear Recycle Bin. $($_.Exception.Message)"
    }
}

function Clear-EventLogsSafe {
    param([string]$Mode)
    if (-not $chkEventLogs.Checked) { return }

    if ($Mode -eq 'Scan') {
        Write-LogLine INFO "Event Logs: selected for cleanup."
        return
    }

    try {
        $logs = @(wevtutil el 2>$null)
        $count = 0
        foreach ($log in $logs) {
            if ([string]::IsNullOrWhiteSpace($log)) { continue }
            try {
                wevtutil cl "$log" 2>$null | Out-Null
                $count++
            }
            catch {
                $script:RunData.Errors++
            }
        }
        Write-LogLine SUCCESS "Event logs cleared: $count"
    }
    catch {
        $script:RunData.Errors++
        Write-LogLine WARN "Could not enumerate event logs. $($_.Exception.Message)"
    }
}

function Clear-ShadowCopiesSafe {
    param([string]$Mode)
    if (-not $chkShadowCopies.Checked) { return }

    if ($Mode -eq 'Scan') {
        Write-LogLine INFO "Shadow Copies: selected for cleanup."
        return
    }

    try {
        & vssadmin delete shadows /all /quiet | Out-Null
        Write-LogLine SUCCESS "All shadow copies were deleted."
    }
    catch {
        $script:RunData.Errors++
        Write-LogLine WARN "Could not delete shadow copies. $($_.Exception.Message)"
    }
}

function Get-SummaryText {
    $d = $script:RunData
@"
$AppName $AppVersion
Mode:               $($d.Mode)
Preset:             $($d.Preset)
Start Time:         $($d.StartTime)
End Time:           $($d.EndTime)

Paths Checked:      $($d.PathsChecked)
Paths Missing:      $($d.PathsMissing)
Files Seen:         $($d.FilesSeen)
Directories Seen:   $($d.DirectoriesSeen)
Files Deleted:      $($d.FilesDeleted)
Directories Deleted:$($d.DirectoriesDeleted)
Skipped:            $($d.Skipped)
Locked:             $($d.Locked)
Errors:             $($d.Errors)
Estimated Space:    $(Format-Bytes $d.EstimatedBytes)

Categories:
$([string]::Join("`r`n", ($d.Categories | ForEach-Object { " - $_" })))

Based on legacy cleanup ideas popularized by Hiren's utility collection.
"@
}

function Save-SummaryFile {
    $script:CurrentSummaryFile = Join-Path $SummaryDir ("Summary_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    $script:LastSummaryText = Get-SummaryText
    Set-Content -Path $script:CurrentSummaryFile -Value $script:LastSummaryText -Encoding UTF8
}


function Get-SelectionSummaryText {
    $selected = New-Object System.Collections.Generic.List[string]
    if ($chkSystemTemp.Checked) { $selected.Add('System temp') | Out-Null }
    if ($chkAllUserTemp.Checked) { $selected.Add('All user temp') | Out-Null }
    if ($chkBrowserCaches.Checked) { $selected.Add('Browser caches') | Out-Null }
    if ($chkPrinterSpool.Checked) { $selected.Add('Printer spool temp') | Out-Null }
    if ($chkRecycleBin.Checked) { $selected.Add('Recycle Bin') | Out-Null }
    if ($chkPrefetch.Checked) { $selected.Add('Prefetch') | Out-Null }
    if ($chkEventLogs.Checked) { $selected.Add('Event Logs') | Out-Null }
    if ($chkShadowCopies.Checked) { $selected.Add('Shadow Copies') | Out-Null }
    return [string]::Join("`r`n- ", $selected)
}

function Confirm-CleanupSelection {
    $selected = Get-SelectionSummaryText
    if (-not $selected) { return $false }

    $message = "You are about to run cleanup for:`r`n`r`n- $selected`r`n`r`nPreset: $($cmbPreset.SelectedItem)`r`n`r`nContinue?"
    $response = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Confirm Cleanup',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    return ($response -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Execute-Workflow {
    param([ValidateSet('Scan','Cleanup')] [string]$Mode)

    $categories = @(Get-EnabledCategories)
    if (-not $categories -and -not $chkRecycleBin.Checked -and -not $chkEventLogs.Checked -and -not $chkShadowCopies.Checked) {
        [System.Windows.Forms.MessageBox]::Show(
            'Nothing is selected.',
            $AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    if ($Mode -eq 'Cleanup') {
        if (-not (Confirm-CleanupSelection)) { return }

        if ($chkEventLogs.Checked -or $chkShadowCopies.Checked) {
            $response = [System.Windows.Forms.MessageBox]::Show(
                "You selected one or more aggressive cleanup options.`r`n`r`nContinue?",
                'Confirm Aggressive Cleanup',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($response -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
    }

    $txtLog.Clear()
    Start-NewLog
    $script:RunData = New-RunData
    $script:RunData.Mode = $Mode
    $script:RunData.Preset = [string]$cmbPreset.SelectedItem
    foreach ($c in $categories) { $script:RunData.Categories.Add($c.Name) | Out-Null }
    if ($chkRecycleBin.Checked) { $script:RunData.Categories.Add('Recycle Bin') | Out-Null }
    if ($chkEventLogs.Checked) { $script:RunData.Categories.Add('Event Logs') | Out-Null }
    if ($chkShadowCopies.Checked) { $script:RunData.Categories.Add('Shadow Copies') | Out-Null }

    Set-RunState -Running:$true
    Set-ProgressSafe 0
    Set-Status "$Mode starting"
    Set-CurrentAction "Preparing $Mode"
    Update-SummaryPanel

    try {
        Write-LogLine INFO "$AppName $AppVersion"
        Write-LogLine INFO "Mode: $Mode | Preset: $($cmbPreset.SelectedItem)"
        $countTotal = [Math]::Max(1, $categories.Count + [int]$chkRecycleBin.Checked + [int]$chkEventLogs.Checked + [int]$chkShadowCopies.Checked)
        $step = 0

        foreach ($category in $categories) {
            $step++
            Set-ProgressSafe ([int](($step / $countTotal) * 85))
            Set-Status "${Mode} in progress"
            Set-CurrentAction "$($category.Name) ($step/$countTotal)"
            Write-LogLine INFO "Category: $($category.Name)"

            foreach ($path in $category.Paths) {
                Process-Path -Path $path -Mode $Mode -Verbose:$chkVerbose.Checked
                Update-SummaryPanel
            }
        }

        if ($chkRecycleBin.Checked) {
            $step++
            Set-ProgressSafe ([int](($step / $countTotal) * 85))
            Set-Status "${Mode}: Recycle Bin"
            Clear-RecycleBinSafe -Mode $Mode
        }

        if ($chkEventLogs.Checked) {
            $step++
            Set-ProgressSafe ([int](($step / $countTotal) * 85))
            Set-Status "${Mode}: Event Logs"
            Clear-EventLogsSafe -Mode $Mode
        }

        if ($chkShadowCopies.Checked) {
            $step++
            Set-ProgressSafe ([int](($step / $countTotal) * 85))
            Set-Status "${Mode}: Shadow Copies"
            Clear-ShadowCopiesSafe -Mode $Mode
        }

        $script:RunData.EndTime = (Get-Date).ToString('s')
        Save-SummaryFile
        Update-SummaryPanel
        Set-ProgressSafe 100
        Set-Status "$Mode complete"
        Set-CurrentAction 'Complete'
        Write-LogLine INFO "Summary saved to $script:CurrentSummaryFile"
        $btnExport.Enabled = $true

        $trueErrors = [Math]::Max(0, ($script:RunData.Errors - $script:RunData.Locked))
        $doneMessage = @"
$Mode completed successfully.

Preset: $($script:RunData.Preset)
Estimated space: $(Format-Bytes $script:RunData.EstimatedBytes)
Files deleted: $($script:RunData.FilesDeleted)
Directories deleted: $($script:RunData.DirectoriesDeleted)
Locked items: $($script:RunData.Locked)
Errors: $trueErrors
Summary file: $script:CurrentSummaryFile
"@
        [System.Windows.Forms.MessageBox]::Show(
            $doneMessage,
            "$AppName Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        $script:RunData.Errors++
        Set-Status 'Error'
        Write-LogLine ERROR $_.Exception.Message
        Update-SummaryPanel
    }
    finally {
        Set-RunState -Running:$false
    }
}

function Apply-Preset {
    param([string]$Preset)
    $script:ApplyingPreset = $true
    try {
        switch ($Preset) {
            'Safe' {
                $chkSystemTemp.Checked = $true
                $chkAllUserTemp.Checked = $true
                $chkBrowserCaches.Checked = $false
                $chkPrinterSpool.Checked = $false
                $chkRecycleBin.Checked = $true
                $chkPrefetch.Checked = $false
                $chkEventLogs.Checked = $false
                $chkShadowCopies.Checked = $false
            }
            'Standard' {
                $chkSystemTemp.Checked = $true
                $chkAllUserTemp.Checked = $true
                $chkBrowserCaches.Checked = $true
                $chkPrinterSpool.Checked = $true
                $chkRecycleBin.Checked = $true
                $chkPrefetch.Checked = $false
                $chkEventLogs.Checked = $false
                $chkShadowCopies.Checked = $false
            }
            'Aggressive' {
                $chkSystemTemp.Checked = $true
                $chkAllUserTemp.Checked = $true
                $chkBrowserCaches.Checked = $true
                $chkPrinterSpool.Checked = $true
                $chkRecycleBin.Checked = $true
                $chkPrefetch.Checked = $true
                $chkEventLogs.Checked = $true
                $chkShadowCopies.Checked = $true
            }
            'Custom' { }
        }

        $txtPresetInfo.Text = switch ($Preset) {
            'Safe'       { 'Safe: temp folders and Recycle Bin. Best for routine cleanup.' }
            'Standard'   { 'Standard: safe cleanup plus browser caches and printer spool temp. Recommended default.' }
            'Aggressive' { 'Aggressive: adds Prefetch, event logs, and shadow copies. Use only when you understand the tradeoffs.' }
            default      { 'Custom: pick exactly what you want to include.' }
        }
    }
    finally {
        $script:ApplyingPreset = $false
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $AppName
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1120, 860)
$form.MinimumSize = New-Object System.Drawing.Size(1080, 820)
$form.BackColor = [System.Drawing.Color]::WhiteSmoke

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = $AppName
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI',18,[System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20,16)
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = 'A modern cleanup utility with scan mode, safer presets, and clear results.'
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(22,50)
$form.Controls.Add($lblSub)

$lblAdmin = New-Object System.Windows.Forms.Label
$lblAdmin.Text = 'Running as Administrator'
$lblAdmin.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$lblAdmin.ForeColor = [System.Drawing.Color]::DarkGreen
$lblAdmin.AutoSize = $true
$lblAdmin.Location = New-Object System.Drawing.Point(22,76)
$form.Controls.Add($lblAdmin)

$lblPreset = New-Object System.Windows.Forms.Label
$lblPreset.Text = 'Preset:'
$lblPreset.AutoSize = $true
$lblPreset.Location = New-Object System.Drawing.Point(22,108)
$form.Controls.Add($lblPreset)

$cmbPreset = New-Object System.Windows.Forms.ComboBox
$cmbPreset.DropDownStyle = 'DropDownList'
[void]$cmbPreset.Items.AddRange(@('Safe','Standard','Aggressive','Custom'))
$cmbPreset.Size = New-Object System.Drawing.Size(170,24)
$cmbPreset.Location = New-Object System.Drawing.Point(75,104)
$form.Controls.Add($cmbPreset)

$chkVerbose = New-Object System.Windows.Forms.CheckBox
$chkVerbose.Text = 'Verbose log'
$chkVerbose.AutoSize = $true
$chkVerbose.Location = New-Object System.Drawing.Point(265,106)
$form.Controls.Add($chkVerbose)

$txtPresetInfo = New-Object System.Windows.Forms.TextBox
$txtPresetInfo.Multiline = $true
$txtPresetInfo.ReadOnly = $true
$txtPresetInfo.Size = New-Object System.Drawing.Size(1050,52)
$txtPresetInfo.Location = New-Object System.Drawing.Point(22,136)
$txtPresetInfo.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($txtPresetInfo)

$grpCore = New-Object System.Windows.Forms.GroupBox
$grpCore.Text = 'Core Cleanup'
$grpCore.Size = New-Object System.Drawing.Size(510,180)
$grpCore.Location = New-Object System.Drawing.Point(22,202)
$form.Controls.Add($grpCore)

$chkSystemTemp = New-Object System.Windows.Forms.CheckBox
$chkSystemTemp.Text = 'System temp, logs, minidumps, Windows Update download'
$chkSystemTemp.AutoSize = $true
$chkSystemTemp.Location = New-Object System.Drawing.Point(16,28)
$grpCore.Controls.Add($chkSystemTemp)

$chkAllUserTemp = New-Object System.Windows.Forms.CheckBox
$chkAllUserTemp.Text = 'All user temp, crash dumps, WER, Explorer and INetCache'
$chkAllUserTemp.AutoSize = $true
$chkAllUserTemp.Location = New-Object System.Drawing.Point(16,56)
$grpCore.Controls.Add($chkAllUserTemp)

$chkBrowserCaches = New-Object System.Windows.Forms.CheckBox
$chkBrowserCaches.Text = 'Browser caches'
$chkBrowserCaches.AutoSize = $true
$chkBrowserCaches.Location = New-Object System.Drawing.Point(16,84)
$grpCore.Controls.Add($chkBrowserCaches)

$chkPrinterSpool = New-Object System.Windows.Forms.CheckBox
$chkPrinterSpool.Text = 'Printer spool temp'
$chkPrinterSpool.AutoSize = $true
$chkPrinterSpool.Location = New-Object System.Drawing.Point(16,112)
$grpCore.Controls.Add($chkPrinterSpool)

$chkRecycleBin = New-Object System.Windows.Forms.CheckBox
$chkRecycleBin.Text = 'Recycle Bin'
$chkRecycleBin.AutoSize = $true
$chkRecycleBin.Location = New-Object System.Drawing.Point(16,140)
$grpCore.Controls.Add($chkRecycleBin)

$grpAgg = New-Object System.Windows.Forms.GroupBox
$grpAgg.Text = 'Aggressive Options'
$grpAgg.Size = New-Object System.Drawing.Size(562,180)
$grpAgg.Location = New-Object System.Drawing.Point(540,202)
$form.Controls.Add($grpAgg)

$chkPrefetch = New-Object System.Windows.Forms.CheckBox
$chkPrefetch.Text = 'Prefetch'
$chkPrefetch.AutoSize = $true
$chkPrefetch.Location = New-Object System.Drawing.Point(16,28)
$grpAgg.Controls.Add($chkPrefetch)

$chkEventLogs = New-Object System.Windows.Forms.CheckBox
$chkEventLogs.Text = 'Clear all Windows Event Logs'
$chkEventLogs.AutoSize = $true
$chkEventLogs.Location = New-Object System.Drawing.Point(16,56)
$grpAgg.Controls.Add($chkEventLogs)

$chkShadowCopies = New-Object System.Windows.Forms.CheckBox
$chkShadowCopies.Text = 'Delete all shadow copies / restore points'
$chkShadowCopies.AutoSize = $true
$chkShadowCopies.Location = New-Object System.Drawing.Point(16,84)
$grpAgg.Controls.Add($chkShadowCopies)

$lblAggInfo = New-Object System.Windows.Forms.Label
$lblAggInfo.Text = 'These are intentionally not default. Event logs help troubleshooting, and shadow copies can be valuable rollback points.'
$lblAggInfo.Size = New-Object System.Drawing.Size(520,60)
$lblAggInfo.Location = New-Object System.Drawing.Point(16,114)
$grpAgg.Controls.Add($lblAggInfo)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = 'Scan'
$btnScan.Size = New-Object System.Drawing.Size(100,34)
$btnScan.Location = New-Object System.Drawing.Point(22,398)
$form.Controls.Add($btnScan)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Run Cleanup'
$btnRun.Size = New-Object System.Drawing.Size(150,40)
$btnRun.Location = New-Object System.Drawing.Point(132,395)
$form.Controls.Add($btnRun)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Export Summary'
$btnExport.Size = New-Object System.Drawing.Size(130,34)
$btnExport.Location = New-Object System.Drawing.Point(292,398)
$btnExport.Enabled = $false
$form.Controls.Add($btnExport)

$btnOpenLog = New-Object System.Windows.Forms.Button
$btnOpenLog.Text = 'Open Log Folder'
$btnOpenLog.Size = New-Object System.Drawing.Size(130,34)
$btnOpenLog.Location = New-Object System.Drawing.Point(430,398)
$form.Controls.Add($btnOpenLog)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(22,446)
$progressBar.Size = New-Object System.Drawing.Size(930,22)
$form.Controls.Add($progressBar)

$lblProgressPercent = New-Object System.Windows.Forms.Label
$lblProgressPercent.Text = '0%'
$lblProgressPercent.AutoSize = $true
$lblProgressPercent.Location = New-Object System.Drawing.Point(962,449)
$form.Controls.Add($lblProgressPercent)

$lblCurrentAction = New-Object System.Windows.Forms.Label
$lblCurrentAction.Text = 'Current action: Ready'
$lblCurrentAction.AutoSize = $true
$lblCurrentAction.Location = New-Object System.Drawing.Point(22,473)
$form.Controls.Add($lblCurrentAction)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Status: Ready'
$lblStatus.AutoSize = $true
$lblStatus.Location = New-Object System.Drawing.Point(220,473)
$form.Controls.Add($lblStatus)

$grpSummary = New-Object System.Windows.Forms.GroupBox
$grpSummary.Text = 'Summary'
$grpSummary.Size = New-Object System.Drawing.Size(1080,118)
$grpSummary.Location = New-Object System.Drawing.Point(22,500)
$form.Controls.Add($grpSummary)

function New-InfoPair {
    param($parent, $title, $x, $y)
    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = $title
    $l1.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $l1.AutoSize = $true
    $l1.Location = New-Object System.Drawing.Point($x,$y)
    $parent.Controls.Add($l1)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = '-'
    $l2.AutoSize = $true
    $l2.Location = New-Object System.Drawing.Point(($x + 95),$y)
    $parent.Controls.Add($l2)
    return $l2
}

$lblModeValue = New-InfoPair -parent $grpSummary -title 'Mode:' -x 16 -y 28
$lblPresetValue = New-InfoPair -parent $grpSummary -title 'Preset:' -x 290 -y 28
$lblPathsValue = New-InfoPair -parent $grpSummary -title 'Paths:' -x 16 -y 56
$lblFilesValue = New-InfoPair -parent $grpSummary -title 'Files:' -x 290 -y 56
$lblDirsValue = New-InfoPair -parent $grpSummary -title 'Dirs:' -x 580 -y 28
$lblSkippedValue = New-InfoPair -parent $grpSummary -title 'Skipped:' -x 580 -y 56
$lblErrorsValue = New-InfoPair -parent $grpSummary -title 'Errors:' -x 850 -y 28
$lblSpaceValue = New-InfoPair -parent $grpSummary -title 'Est. Space:' -x 850 -y 56

$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = 'Detailed Log'
$grpLog.Size = New-Object System.Drawing.Size(1080,190)
$grpLog.Location = New-Object System.Drawing.Point(22,626)
$form.Controls.Add($grpLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Font = New-Object System.Drawing.Font('Consolas',9)
$txtLog.Size = New-Object System.Drawing.Size(1048,156)
$txtLog.Location = New-Object System.Drawing.Point(16,22)
$grpLog.Controls.Add($txtLog)

$cmbPreset.Add_SelectedIndexChanged({
    if ($cmbPreset.SelectedItem) {
        Apply-Preset -Preset ([string]$cmbPreset.SelectedItem)
    }
})

foreach ($cb in @($chkSystemTemp,$chkAllUserTemp,$chkBrowserCaches,$chkPrinterSpool,$chkRecycleBin,$chkPrefetch,$chkEventLogs,$chkShadowCopies)) {
    $cb.Add_CheckedChanged({
        if (-not $script:ApplyingPreset -and $cmbPreset.SelectedItem -ne 'Custom') {
            $cmbPreset.SelectedItem = 'Custom'
        }
    })
}

$btnScan.Add_Click({ Execute-Workflow -Mode 'Scan' })
$btnRun.Add_Click({ Execute-Workflow -Mode 'Cleanup' })

$btnOpenLog.Add_Click({
    if (-not (Test-Path $LogDir)) { return }
    Start-Process explorer.exe $LogDir | Out-Null
})

$btnExport.Add_Click({
    if (-not $script:LastSummaryText) { return }
    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Filter = 'Text files (*.txt)|*.txt'
    $saveDialog.FileName = "TempCleanerSummary_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-Content -Path $saveDialog.FileName -Value $script:LastSummaryText -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show(
            "Summary exported to:`r`n$($saveDialog.FileName)",
            $AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
})

$cmbPreset.SelectedItem = 'Standard'
Set-CurrentAction 'Ready'
[void]$form.ShowDialog()
