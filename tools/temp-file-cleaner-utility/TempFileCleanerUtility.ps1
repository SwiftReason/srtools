#requires -version 5.1
<#
Temp File Cleaner Utility
Version: 3.0

Description:
A modern Windows cleanup utility with Scan, Cleanup, presets, summaries, and safer aggressive options.

What's new in 3.0:
- Light and dark themes (follows the Windows app theme by default)
- The window stays responsive during long runs, with a Cancel button (Esc also cancels)
- Optional "skip items newer than" filter so temp files still in use by installers are kept
- Reports space actually freed, cleans what it can inside partly locked folders,
  and never follows junctions or symbolic links
- Browser caches cover every Chrome, Edge, Brave and Firefox profile without touching profile data
- Remembers theme, preset and options between runs (settings.json)

Credit:
This utility was inspired by the legacy cleanup approach used in Hiren's utility collection.
This is a separate, modernized PowerShell GUI implementation.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppName      = 'Temp File Cleaner Utility'
$AppVersion   = 'v3.0'
# Compiled with ps2exe there is no script path, so fall back to the folder holding the .exe
$ScriptRoot   = if ($PSScriptRoot) { $PSScriptRoot }
                elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
                else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$LogDir       = Join-Path $ScriptRoot 'Logs'
$SummaryDir   = Join-Path $ScriptRoot 'Summaries'
$SettingsFile = Join-Path $ScriptRoot 'settings.json'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $SummaryDir -Force | Out-Null

# The launcher hides the console, so surface startup failures instead of closing silently
trap {
    [System.Windows.Forms.MessageBox]::Show(
        "$AppName hit an unexpected error and has to close.`r`n`r`n$($_.Exception.Message)",
        $AppName,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

if (-not ('TempCleaner.NativeMethods' -as [type])) {
    Add-Type -Namespace TempCleaner -Name NativeMethods -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
public static extern int SetWindowTheme(IntPtr hwnd, string subAppName, string subIdList);
'@
}

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
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
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
$script:CancelRequested = $false
$script:CloseAfterRun = $false
$script:VerboseLog = $false
$script:MinAgeCutoff = $null
$script:CurrentLogFile = $null
$script:CurrentSummaryFile = $null
$script:LastSummaryText = ''
$script:RunData = $null
$script:ProgressValue = 0
$script:LogLines = New-Object System.Collections.Generic.List[object]
$script:PumpWatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:CounterNames = @('FilesSeen','DirectoriesSeen','FilesDeleted','DirectoriesDeleted','SkippedRecent','Locked','Denied','Errors','FoundBytes','FreedBytes')
$script:AgeHours = [ordered]@{ 'Any age' = 0; '1 hour' = 1; '24 hours' = 24; '7 days' = 168 }
$script:FocusCuesProperty = [System.Windows.Forms.Control].GetProperty('ShowFocusCues', [System.Reflection.BindingFlags]'Instance, NonPublic')

#region Theme

$palettes = @{
    Light = @{
        Window         = '#F3F3F3'
        Surface        = '#FFFFFF'
        Control        = '#FBFBFB'
        ControlHover   = '#F0F0F0'
        ControlPressed = '#E6E6E6'
        Border         = '#E0E0E0'
        Text           = '#1B1B1B'
        SubText        = '#5D5D5D'
        Disabled       = '#A3A3A3'
        Accent         = '#0067C0'
        AccentHover    = '#1A75C4'
        AccentPressed  = '#3384CC'
        AccentText     = '#FFFFFF'
        Input          = '#FFFFFF'
        CheckBorder    = '#858585'
        Track          = '#E3E3E3'
        Success        = '#0F7B0F'
        Warning        = '#9D5D00'
        Danger         = '#C42B1C'
    }
    Dark = @{
        Window         = '#202020'
        Surface        = '#2B2B2B'
        Control        = '#373737'
        ControlHover   = '#3D3D3D'
        ControlPressed = '#303030'
        Border         = '#3F3F3F'
        Text           = '#F2F2F2'
        SubText        = '#ADADAD'
        Disabled       = '#6F6F6F'
        Accent         = '#4CC2FF'
        AccentHover    = '#48B4EC'
        AccentPressed  = '#42A3D6'
        AccentText     = '#000000'
        Input          = '#1F1F1F'
        CheckBorder    = '#A0A0A0'
        Track          = '#454545'
        Success        = '#6CCB5F'
        Warning        = '#FFC34D'
        Danger         = '#FF99A4'
    }
}

$script:Themes = @{}
foreach ($themeName in $palettes.Keys) {
    $colors = @{}
    foreach ($key in $palettes[$themeName].Keys) {
        $colors[$key] = [System.Drawing.ColorTranslator]::FromHtml($palettes[$themeName][$key])
    }
    $script:Themes[$themeName] = $colors
}
$script:ThemeChoice = 'System'
$script:ThemeName = 'Light'
$script:Theme = $script:Themes.Light

$script:FontBase    = New-Object System.Drawing.Font('Segoe UI', 9)
$script:FontSmall   = New-Object System.Drawing.Font('Segoe UI', 8.25)
$script:FontTitle   = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$script:FontHeading = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$script:FontValue   = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$script:FontStatus  = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$script:FontLog     = New-Object System.Drawing.Font('Consolas', 9)
$script:FontGlyph   = New-Object System.Drawing.Font('Segoe MDL2 Assets', 20)

function Get-SystemTheme {
    try {
        $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ($value -eq 0) { return 'Dark' }
    }
    catch { }
    return 'Light'
}

function Enable-DoubleBuffer {
    param([System.Windows.Forms.Control]$Control)
    $property = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
    $property.SetValue($Control, $true, $null)
}

function New-RoundedPath {
    param([System.Drawing.RectangleF]$Rect, [float]$Radius)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = $Radius * 2
    $path.AddArc($Rect.X, $Rect.Y, $diameter, $diameter, 180, 90)
    $path.AddArc(($Rect.Right - $diameter), $Rect.Y, $diameter, $diameter, 270, 90)
    $path.AddArc(($Rect.Right - $diameter), ($Rect.Bottom - $diameter), $diameter, $diameter, 0, 90)
    $path.AddArc($Rect.X, ($Rect.Bottom - $diameter), $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-ButtonColors {
    param($Button, $Back, $Fore, $Border, $Hover, $Pressed)
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.UseVisualStyleBackColor = $false
    $Button.BackColor = $Back
    $Button.ForeColor = $Fore
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.BorderColor = $Border
    $Button.FlatAppearance.MouseOverBackColor = $Hover
    $Button.FlatAppearance.MouseDownBackColor = $Pressed
}

# Every themed control carries its role in Tag; this walks the tree and recolors by role
function Set-ControlTheme {
    param([System.Windows.Forms.Control]$Control)
    $t = $script:Theme
    $parentBack = if ($Control.Parent) { $Control.Parent.BackColor } else { $t.Window }

    switch ([string]$Control.Tag) {
        'window'    { $Control.BackColor = $t.Window;  $Control.ForeColor = $t.Text }
        'dialog'    { $Control.BackColor = $t.Surface; $Control.ForeColor = $t.Text }
        'card'      { $Control.BackColor = $t.Surface; $Control.ForeColor = $t.Text }
        'infostrip' { $Control.BackColor = $t.Surface; $Control.ForeColor = $t.Text }
        'footer'    { $Control.BackColor = $t.Window }
        'plain'     { $Control.BackColor = $parentBack }
        'progress'  { $Control.BackColor = $parentBack }
        'text'      { $Control.BackColor = $parentBack; $Control.ForeColor = $t.Text }
        'subtext'   { $Control.BackColor = $parentBack; $Control.ForeColor = $t.SubText }
        'accent'    { $Control.BackColor = $parentBack; $Control.ForeColor = $t.Accent }
        'success'   { $Control.BackColor = $parentBack; $Control.ForeColor = $t.Success }
        'warning'   { $Control.BackColor = $parentBack; $Control.ForeColor = $t.Warning }
        'check'     { $Control.BackColor = $parentBack; $Control.ForeColor = $t.Text }
        'log'       { $Control.BackColor = $t.Surface; $Control.ForeColor = $t.Text }
        'button'    {
            Set-ButtonColors -Button $Control -Back $t.Control -Fore $t.Text -Border $t.Border -Hover $t.ControlHover -Pressed $t.ControlPressed
        }
        'primary'   {
            if ($Control.Enabled) {
                Set-ButtonColors -Button $Control -Back $t.Accent -Fore $t.AccentText -Border $t.Accent -Hover $t.AccentHover -Pressed $t.AccentPressed
            }
            else {
                Set-ButtonColors -Button $Control -Back $t.Control -Fore $t.Disabled -Border $t.Border -Hover $t.Control -Pressed $t.Control
            }
        }
        'segment'   {
            if ($Control.Checked -and $Control.Enabled) {
                Set-ButtonColors -Button $Control -Back $t.Control -Fore $t.AccentText -Border $t.Accent -Hover $t.AccentHover -Pressed $t.AccentPressed
                $Control.FlatAppearance.CheckedBackColor = $t.Accent
            }
            else {
                Set-ButtonColors -Button $Control -Back $t.Control -Fore $t.Text -Border $t.Border -Hover $t.ControlHover -Pressed $t.ControlPressed
                $Control.FlatAppearance.CheckedBackColor = $t.ControlPressed
            }
        }
    }

    foreach ($child in $Control.Controls) { Set-ControlTheme -Control $child }
    $Control.Invalidate()
}

function Update-WindowFrame {
    param([System.Windows.Forms.Form]$Window)
    $dark = [int]($script:ThemeName -eq 'Dark')
    try {
        # 20 is DWMWA_USE_IMMERSIVE_DARK_MODE; builds before Windows 10 20H1 used 19
        if ([TempCleaner.NativeMethods]::DwmSetWindowAttribute($Window.Handle, 20, [ref]$dark, 4) -ne 0) {
            [void][TempCleaner.NativeMethods]::DwmSetWindowAttribute($Window.Handle, 19, [ref]$dark, 4)
        }
    }
    catch { }
}

function Update-ScrollbarTheme {
    $scrollTheme = if ($script:ThemeName -eq 'Dark') { 'DarkMode_Explorer' } else { 'Explorer' }
    try {
        [void][TempCleaner.NativeMethods]::SetWindowTheme($txtLog.Handle, $scrollTheme, [System.Management.Automation.Language.NullString]::Value)
    }
    catch { }
}

function Set-AppTheme {
    param([ValidateSet('System','Light','Dark')] [string]$Choice)
    $script:ThemeChoice = $Choice
    $script:ThemeName = if ($Choice -eq 'System') { Get-SystemTheme } else { $Choice }
    $script:Theme = $script:Themes[$script:ThemeName]

    $form.SuspendLayout()
    Set-ControlTheme -Control $form
    $form.ResumeLayout()
    Render-LogView
    Update-SummaryPanel
    if ($form.IsHandleCreated) {
        Update-WindowFrame -Window $form
        Update-ScrollbarTheme
    }
}

#endregion

#region UI helpers

$script:PaintCard = {
    $t = $script:Theme
    $g = $_.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($this.Parent.BackColor)

    $bounds = New-Object System.Drawing.RectangleF(0.5, 0.5, ($this.Width - 1), ($this.Height - 1))
    $path = New-RoundedPath -Rect $bounds -Radius 8
    $fill = New-Object System.Drawing.SolidBrush($t.Surface)
    $border = New-Object System.Drawing.Pen($t.Border)
    $g.FillPath($fill, $path)
    $g.DrawPath($border, $path)

    if ([string]$this.Tag -eq 'infostrip') {
        $barPath = New-RoundedPath -Rect (New-Object System.Drawing.RectangleF(8, 11, 3, ($this.Height - 22))) -Radius 1.5
        $barBrush = New-Object System.Drawing.SolidBrush($t.Accent)
        $g.FillPath($barBrush, $barPath)
        $barBrush.Dispose()
        $barPath.Dispose()
    }

    $fill.Dispose()
    $border.Dispose()
    $path.Dispose()
}

$script:PaintCheckBox = {
    $t = $script:Theme
    $g = $_.Graphics
    $g.Clear($this.BackColor)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $top = [Math]::Floor(($this.Height - 16) / 2)
    $path = New-RoundedPath -Rect (New-Object System.Drawing.RectangleF(2.5, ($top + 0.5), 15, 15)) -Radius 3.5
    if ($this.Checked) {
        $fillColor = if ($this.Enabled) { $t.Accent } else { $t.Disabled }
        $markColor = if ($this.Enabled) { $t.AccentText } else { $t.Surface }
        $fill = New-Object System.Drawing.SolidBrush($fillColor)
        $mark = New-Object System.Drawing.Pen($markColor, 1.8)
        $points = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF(6, ($top + 8.5))),
            (New-Object System.Drawing.PointF(9, ($top + 11.5))),
            (New-Object System.Drawing.PointF(14.5, ($top + 5)))
        )
        $g.FillPath($fill, $path)
        $g.DrawLines($mark, $points)
        $fill.Dispose()
        $mark.Dispose()
    }
    else {
        $borderColor = if ($this.Enabled) { $t.CheckBorder } else { $t.Disabled }
        $fill = New-Object System.Drawing.SolidBrush($t.Input)
        $border = New-Object System.Drawing.Pen($borderColor)
        $g.FillPath($fill, $path)
        $g.DrawPath($border, $path)
        $fill.Dispose()
        $border.Dispose()
    }
    $path.Dispose()

    if ($this.Focused -and $script:FocusCuesProperty.GetValue($this, $null)) {
        $ringPath = New-RoundedPath -Rect (New-Object System.Drawing.RectangleF(0.5, ($top - 1.5), 19, 19)) -Radius 5
        $ring = New-Object System.Drawing.Pen($t.Text)
        $g.DrawPath($ring, $ringPath)
        $ring.Dispose()
        $ringPath.Dispose()
    }

    $textColor = if ($this.Enabled) { $t.Text } else { $t.Disabled }
    $textBounds = New-Object System.Drawing.Rectangle(26, 0, ($this.Width - 26), $this.Height)
    $flags = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix'
    [System.Windows.Forms.TextRenderer]::DrawText($g, $this.Text, $this.Font, $textBounds, $textColor, $flags)
}

function New-Label {
    param(
        $Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [string]$Role = 'text',
        $Font = $null,
        [int]$Width = 0,
        [int]$Height = 0
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Tag = $Role
    $label.UseMnemonic = $false
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    if ($Font) { $label.Font = $Font }
    if ($Width -gt 0) {
        $label.AutoSize = $false
        $label.Size = New-Object System.Drawing.Size($Width, $Height)
    }
    else {
        $label.AutoSize = $true
    }
    $Parent.Controls.Add($label)
    return $label
}

function New-Card {
    param(
        $Parent,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$Title = '',
        [string]$TitleRole = 'text',
        [string]$Role = 'card'
    )
    $card = New-Object System.Windows.Forms.Panel
    $card.Tag = $Role
    $card.Location = New-Object System.Drawing.Point($X, $Y)
    $card.Size = New-Object System.Drawing.Size($Width, $Height)
    Enable-DoubleBuffer $card
    $card.Add_Paint($script:PaintCard)
    $card.Add_Resize({ $this.Invalidate() })
    $Parent.Controls.Add($card)
    if ($Title) {
        [void](New-Label -Parent $card -Text $Title -X 16 -Y 12 -Role $TitleRole -Font $script:FontHeading)
    }
    return $card
}

function New-AppButton {
    param(
        $Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [string]$Role = 'button',
        [int]$Height = 34
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Tag = $Role
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.UseVisualStyleBackColor = $false
    $button.Add_EnabledChanged({ Set-ControlTheme -Control $this })
    $Parent.Controls.Add($button)
    return $button
}

function New-CheckOption {
    param(
        $Parent,
        [string]$Name,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [string]$Tip = ''
    )
    $check = New-Object System.Windows.Forms.CheckBox
    $check.Name = $Name
    $check.Text = $Text
    $check.Tag = 'check'
    $check.AutoSize = $false
    $check.UseVisualStyleBackColor = $false
    $check.Location = New-Object System.Drawing.Point($X, $Y)
    $textWidth = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $script:FontBase).Width
    $check.Size = New-Object System.Drawing.Size(($textWidth + 32), 24)
    Enable-DoubleBuffer $check
    $check.Add_Paint($script:PaintCheckBox)
    if ($Tip) { $toolTip.SetToolTip($check, $Tip) }
    $Parent.Controls.Add($check)
    return $check
}

# Radio buttons drawn as buttons give a segmented control that themes cleanly
function New-SegmentedControl {
    param(
        $Parent,
        [string[]]$Items,
        [int]$X,
        [int]$Y,
        [int]$ItemWidth,
        [int]$Height = 30
    )
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Tag = 'plain'
    $panel.WrapContents = $false
    $panel.Margin = New-Object System.Windows.Forms.Padding(0)
    $panel.Padding = New-Object System.Windows.Forms.Padding(0)
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size(($Items.Count * $ItemWidth), $Height)

    $buttons = [ordered]@{}
    foreach ($item in $Items) {
        $radio = New-Object System.Windows.Forms.RadioButton
        $radio.Text = $item
        $radio.Tag = 'segment'
        $radio.Appearance = [System.Windows.Forms.Appearance]::Button
        $radio.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $radio.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $radio.Margin = New-Object System.Windows.Forms.Padding(0)
        $radio.Size = New-Object System.Drawing.Size($ItemWidth, $Height)
        $radio.Add_CheckedChanged({ Set-ControlTheme -Control $this })
        $radio.Add_EnabledChanged({ Set-ControlTheme -Control $this })
        $panel.Controls.Add($radio)
        $buttons[$item] = $radio
    }
    $Parent.Controls.Add($panel)
    return $buttons
}

function New-StatTile {
    param($Parent, [string]$Caption, [int]$X, [int]$Y, [string]$Role = 'text')
    [void](New-Label -Parent $Parent -Text $Caption -X $X -Y $Y -Role 'subtext' -Font $script:FontSmall)
    $value = New-Label -Parent $Parent -Text '-' -X $X -Y ($Y + 16) -Role $Role -Font $script:FontValue -Width 250 -Height 22
    $value.AutoEllipsis = $true
    return $value
}

function Show-AppDialog {
    param(
        [Parameter(Mandatory = $true)] [string]$Message,
        [string]$Title = $AppName,
        [ValidateSet('Info','Success','Warning','Question')] [string]$Kind = 'Info',
        [ValidateSet('OK','YesNo')] [string]$Buttons = 'OK',
        [switch]$DefaultNo
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.Tag = 'dialog'
    $dialog.Font = $script:FontBase
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ShowIcon = $false

    $glyphCodes = @{ Info = 0xE946; Success = 0xE73E; Warning = 0xE7BA; Question = 0xE9CE }
    $glyphRoles = @{ Info = 'accent'; Success = 'success'; Warning = 'warning'; Question = 'accent' }
    [void](New-Label -Parent $dialog -Text ([string][char]$glyphCodes[$Kind]) -X 22 -Y 22 -Role $glyphRoles[$Kind] -Font $script:FontGlyph)

    # Let the label measure itself so the wrapping matches how it draws
    $lblMessage = New-Label -Parent $dialog -Text $Message -X 66 -Y 26
    $lblMessage.MaximumSize = New-Object System.Drawing.Size(440, 0)
    $textSize = $lblMessage.PreferredSize

    $footerHeight = 60
    $contentHeight = [Math]::Max(76, $textSize.Height + 52)
    $width = [Math]::Max(400, $textSize.Width + 104)
    $dialog.ClientSize = New-Object System.Drawing.Size($width, ($contentHeight + $footerHeight))

    $footer = New-Object System.Windows.Forms.Panel
    $footer.Tag = 'footer'
    $footer.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $footer.Height = $footerHeight
    $dialog.Controls.Add($footer)

    $labels = if ($Buttons -eq 'YesNo') { @('Yes','No') } else { @('OK') }
    $x = $width - 16 - ($labels.Count * 104) + 8
    $made = @{}
    foreach ($label in $labels) {
        $isDefault = ($label -eq 'OK') -or ($label -eq 'Yes' -and -not $DefaultNo) -or ($label -eq 'No' -and $DefaultNo)
        $role = if ($isDefault) { 'primary' } else { 'button' }
        $button = New-AppButton -Parent $footer -Text $label -X $x -Y 14 -Width 96 -Height 32 -Role $role
        $button.DialogResult = [System.Windows.Forms.DialogResult]$label
        $made[$label] = $button
        $x += 104
    }

    if ($Buttons -eq 'OK') {
        $dialog.AcceptButton = $made['OK']
        $dialog.CancelButton = $made['OK']
    }
    else {
        $dialog.AcceptButton = if ($DefaultNo) { $made['No'] } else { $made['Yes'] }
        $dialog.CancelButton = $made['No']
    }

    Set-ControlTheme -Control $dialog
    $dialog.Add_Load({ Update-WindowFrame -Window $this })
    $dialog.Add_Shown({ [void]$this.AcceptButton.Focus() })

    $result = if ($form -and $form.Visible) { $dialog.ShowDialog($form) } else { $dialog.ShowDialog() }
    $dialog.Dispose()

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { return 'Yes' }
    if ($Buttons -eq 'YesNo') { return 'No' }
    return 'OK'
}

#endregion

#region Run state, logging and summary

function New-RunData {
    [ordered]@{
        Mode               = ''
        Preset             = ''
        MinAge             = ''
        StartTime          = (Get-Date).ToString('s')
        EndTime            = ''
        Cancelled          = $false
        PathsChecked       = 0
        PathsMissing       = 0
        FilesSeen          = 0
        DirectoriesSeen    = 0
        FilesDeleted       = 0
        DirectoriesDeleted = 0
        SkippedRecent      = 0
        Locked             = 0
        Denied             = 0
        Errors             = 0
        FoundBytes         = [int64]0
        FreedBytes         = [int64]0
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

# Keeps the window painting and clickable during long runs without a background thread
function Invoke-UiPump {
    if ($script:PumpWatch.ElapsedMilliseconds -lt 50) { return }
    $script:PumpWatch.Restart()
    Update-SummaryPanel
    [System.Windows.Forms.Application]::DoEvents()
}

function Start-NewLog {
    $script:CurrentLogFile = Join-Path $LogDir ("TempCleaner_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType File -Path $script:CurrentLogFile -Force | Out-Null
}

function Get-LevelColor {
    param([string]$Level)
    switch ($Level) {
        'SUCCESS' { return $script:Theme.Success }
        'WARN'    { return $script:Theme.Warning }
        'ERROR'   { return $script:Theme.Danger }
        default   { return $script:Theme.Text }
    }
}

function Add-LogViewLine {
    param([string]$Level, [string]$Line)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.SelectionLength = 0
    $txtLog.SelectionColor = Get-LevelColor $Level
    $txtLog.AppendText($Line + "`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

function Render-LogView {
    $txtLog.Clear()
    foreach ($entry in $script:LogLines) { Add-LogViewLine -Level $entry.Level -Line $entry.Line }
}

function Write-LogLine {
    param(
        [string]$Level,
        [string]$Text
    )
    $Level = $Level.ToUpper()
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Text
    try { Add-Content -Path $script:CurrentLogFile -Value $line -Encoding UTF8 } catch { }
    $script:LogLines.Add([pscustomobject]@{ Level = $Level; Line = $line })
    Add-LogViewLine -Level $Level -Line $line
    Invoke-UiPump
}

function Set-Status {
    param([string]$Text)
    $lblStatus.Text = $Text
    Invoke-UiPump
}

function Set-CurrentAction {
    param([string]$Text)
    $lblCurrentAction.Text = $Text
    Invoke-UiPump
}

function Set-ProgressSafe {
    param([int]$Value)
    $script:ProgressValue = [Math]::Max(0, [Math]::Min(100, $Value))
    $lblProgressPercent.Text = '{0}%' -f $script:ProgressValue
    $progressBar.Invalidate()
    Invoke-UiPump
}

function Set-RunState {
    param([bool]$Running)
    $script:IsRunning = $Running
    foreach ($control in $script:RunLockedControls) { $control.Enabled = -not $Running }
    $btnCancel.Enabled = $Running
    $btnExport.Enabled = (-not $Running) -and [bool]$script:LastSummaryText
}

function Request-Cancel {
    if (-not $script:IsRunning -or $script:CancelRequested) { return }
    $script:CancelRequested = $true
    $btnCancel.Enabled = $false
    Set-Status 'Cancelling...'
}

function Get-SkippedText {
    $d = $script:RunData
    $parts = @()
    if ($d.SkippedRecent) { $parts += ('{0:N0} recent' -f $d.SkippedRecent) }
    if ($d.Locked) { $parts += ('{0:N0} in use' -f $d.Locked) }
    if ($d.Denied) { $parts += ('{0:N0} access denied' -f $d.Denied) }
    if (-not $parts) { return 'None' }
    return ($parts -join ', ')
}

function Update-SummaryPanel {
    if (-not $script:RunData) { return }
    $d = $script:RunData
    $isCleanup = $d.Mode -eq 'Cleanup'

    $lblModeValue.Text = if ($d.Cancelled) { "$($d.Mode) (cancelled)" } else { $d.Mode }
    $lblPresetValue.Text = $d.Preset
    $lblPathsValue.Text = ("{0} checked, {1} not present" -f $d.PathsChecked, $d.PathsMissing)
    if ($isCleanup) {
        $lblFilesValue.Text = ("{0:N0} deleted of {1:N0}" -f $d.FilesDeleted, $d.FilesSeen)
        $lblDirsValue.Text = ("{0:N0} deleted of {1:N0}" -f $d.DirectoriesDeleted, $d.DirectoriesSeen)
        $lblSpaceValue.Text = ("{0} freed of {1}" -f (Format-Bytes $d.FreedBytes), (Format-Bytes $d.FoundBytes))
    }
    else {
        $lblFilesValue.Text = ("{0:N0} found" -f $d.FilesSeen)
        $lblDirsValue.Text = ("{0:N0} found" -f $d.DirectoriesSeen)
        $lblSpaceValue.Text = ("{0} reclaimable" -f (Format-Bytes $d.FoundBytes))
    }
    $lblSkippedValue.Text = Get-SkippedText
    $lblErrorsValue.Text = ('{0:N0}' -f $d.Errors)
    $lblErrorsValue.ForeColor = if ($d.Errors -gt 0) { $script:Theme.Danger } else { $script:Theme.Text }
}

function Get-SummaryText {
    $d = $script:RunData
    $modeText = if ($d.Cancelled) { "$($d.Mode) (cancelled)" } else { $d.Mode }
    $freedText = if ($d.Mode -eq 'Cleanup') { Format-Bytes $d.FreedBytes } else { 'n/a (scan only)' }
@"
$AppName $AppVersion
Mode:                  $modeText
Preset:                $($d.Preset)
Skip newer than:       $($d.MinAge)
Start Time:            $($d.StartTime)
End Time:              $($d.EndTime)

Locations Checked:     $($d.PathsChecked)
Locations Not Present: $($d.PathsMissing)
Files Found:           $($d.FilesSeen)
Files Deleted:         $($d.FilesDeleted)
Folders Found:         $($d.DirectoriesSeen)
Folders Deleted:       $($d.DirectoriesDeleted)
Skipped (recent):      $($d.SkippedRecent)
Skipped (in use):      $($d.Locked)
Skipped (denied):      $($d.Denied)
Errors:                $($d.Errors)
Space Found:           $(Format-Bytes $d.FoundBytes)
Space Freed:           $freedText

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

function Get-CompletionMessage {
    $d = $script:RunData
    $lines = New-Object System.Collections.Generic.List[string]
    if ($d.Mode -eq 'Scan') {
        $lines.Add($(if ($d.Cancelled) { 'Scan cancelled. The numbers below are partial.' } else { 'Scan complete. Nothing has been deleted.' }))
        $lines.Add('')
        $lines.Add("Reclaimable space: $(Format-Bytes $d.FoundBytes)")
        $lines.Add(('Files: {0:N0}    Folders: {1:N0}' -f $d.FilesSeen, $d.DirectoriesSeen))
    }
    else {
        $lines.Add($(if ($d.Cancelled) { 'Cleanup cancelled. Items processed before cancelling were deleted.' } else { 'Cleanup complete.' }))
        $lines.Add('')
        $lines.Add("Space freed: $(Format-Bytes $d.FreedBytes)")
        $lines.Add(('Files deleted: {0:N0}    Folders deleted: {1:N0}' -f $d.FilesDeleted, $d.DirectoriesDeleted))
    }
    $lines.Add("Skipped: $(Get-SkippedText)")
    if ($d.Errors) { $lines.Add("Errors: $($d.Errors) (see the log for details)") }
    return ($lines -join "`r`n")
}

#endregion

#region Settings

function Read-Settings {
    $settings = [ordered]@{
        Theme           = 'System'
        Preset          = 'Standard'
        MinAgeHours     = 24
        Verbose         = $false
        CustomSelection = @()
    }
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $saved = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            foreach ($key in @($settings.Keys)) {
                if ($saved.PSObject.Properties.Name -contains $key -and $null -ne $saved.$key) { $settings[$key] = $saved.$key }
            }
        }
        catch { }
    }
    if ($settings.Theme -notin @('System','Light','Dark')) { $settings.Theme = 'System' }
    if ($settings.Preset -notin @('Safe','Standard','Aggressive','Custom')) { $settings.Preset = 'Standard' }
    if ($settings.MinAgeHours -notin @($script:AgeHours.Values)) { $settings.MinAgeHours = 24 }
    return $settings
}

function Save-Settings {
    $data = [ordered]@{
        Theme           = $script:ThemeChoice
        Preset          = Get-SelectedPreset
        MinAgeHours     = Get-SelectedMinAgeHours
        Verbose         = $chkVerbose.Checked
        CustomSelection = @($script:OptionChecks | Where-Object { $_.Checked } | ForEach-Object { $_.Name })
    }
    try { $data | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8 } catch { }
}

function Get-SelectedPreset {
    foreach ($name in $presetButtons.Keys) {
        if ($presetButtons[$name].Checked) { return $name }
    }
    return 'Custom'
}

function Get-SelectedMinAgeHours {
    foreach ($name in $ageButtons.Keys) {
        if ($ageButtons[$name].Checked) { return $script:AgeHours[$name] }
    }
    return 0
}

function Get-MinAgeText {
    foreach ($name in $ageButtons.Keys) {
        if ($ageButtons[$name].Checked -and $script:AgeHours[$name] -gt 0) { return $name }
    }
    return 'off'
}

#endregion

#region Cleanup engine

function Get-UserProfiles {
    $usersRoot = if ($env:PUBLIC) { Split-Path -Parent $env:PUBLIC } else { 'C:\Users' }
    Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -notin @('Public','Default','Default User','All Users','defaultuser0') -and
            -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        }
}

function Get-BrowserCachePaths {
    param([string]$ProfilePath)
    $paths = @()

    $chromiumRoots = @(
        'AppData\Local\Google\Chrome\User Data',
        'AppData\Local\Microsoft\Edge\User Data',
        'AppData\Local\BraveSoftware\Brave-Browser\User Data'
    )
    foreach ($relative in $chromiumRoots) {
        $userData = Join-Path $ProfilePath $relative
        if (-not (Test-Path -LiteralPath $userData)) { continue }
        $browserProfiles = Get-ChildItem -LiteralPath $userData -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -eq 'Guest Profile' -or $_.Name -match '^Profile \d+$' }
        foreach ($browserProfile in $browserProfiles) {
            foreach ($cacheName in @('Cache','Code Cache','GPUCache')) {
                $paths += Join-Path $browserProfile.FullName $cacheName
            }
        }
    }

    # The Local copy of a Firefox profile only holds caches; bookmarks and logins live under Roaming
    $firefoxProfiles = Join-Path $ProfilePath 'AppData\Local\Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $firefoxProfiles) {
        foreach ($browserProfile in (Get-ChildItem -LiteralPath $firefoxProfiles -Directory -Force -ErrorAction SilentlyContinue)) {
            foreach ($cacheName in @('cache2','startupCache','thumbnails')) {
                $paths += Join-Path $browserProfile.FullName $cacheName
            }
        }
    }

    return $paths
}

function Get-EnabledCategories {
    $categories = @()
    $userProfiles = @(Get-UserProfiles)

    if ($chkSystemTemp.Checked) {
        $categories += [pscustomobject]@{
            Name = 'System Temp'
            Paths = @(
                "$env:windir\Temp",
                "$env:windir\Logs",
                "$env:windir\Minidump",
                "$env:windir\SoftwareDistribution\Download",
                "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
                "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
            )
        }
    }

    if ($chkAllUserTemp.Checked) {
        $paths = @()
        foreach ($userProfile in $userProfiles) {
            $paths += Join-Path $userProfile.FullName 'AppData\Local\Temp'
            $paths += Join-Path $userProfile.FullName 'AppData\Local\CrashDumps'
            $paths += Join-Path $userProfile.FullName 'AppData\Local\Microsoft\Windows\INetCache'
            $paths += Join-Path $userProfile.FullName 'AppData\Local\Microsoft\Windows\Explorer'
            $paths += Join-Path $userProfile.FullName 'AppData\Local\Microsoft\Windows\WER'
        }
        $categories += [pscustomobject]@{
            Name = 'All User Temp'
            Paths = $paths
        }
    }

    if ($chkBrowserCaches.Checked) {
        $paths = @()
        foreach ($userProfile in $userProfiles) {
            $paths += @(Get-BrowserCachePaths -ProfilePath $userProfile.FullName)
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

function Get-RunningBrowsers {
    $names = @{ chrome = 'Chrome'; msedge = 'Edge'; firefox = 'Firefox'; brave = 'Brave' }
    $running = Get-Process -Name @($names.Keys) -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique
    return @($running | ForEach-Object { $names[$_] })
}

function Get-FailureKind {
    param([System.Exception]$Exception)
    $base = $Exception.GetBaseException()
    if ($base -is [System.UnauthorizedAccessException]) { return 'Denied' }
    # 32 sharing violation, 33 lock violation, 145 folder not empty (something wrote into it)
    if ($base -is [System.IO.IOException] -and (($base.HResult -band 0xFFFF) -in @(32, 33, 145))) { return 'Locked' }
    return 'Error'
}

function Register-Failure {
    param(
        [string]$Path,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [switch]$AlwaysLog
    )
    $kind = Get-FailureKind -Exception $ErrorRecord.Exception
    switch ($kind) {
        'Locked' { $script:RunData.Locked++ }
        'Denied' { $script:RunData.Denied++ }
        default  { $script:RunData.Errors++ }
    }
    if ($kind -eq 'Error' -or $AlwaysLog -or $script:VerboseLog) {
        switch ($kind) {
            'Locked' { Write-LogLine WARN "In use, skipped: $Path" }
            'Denied' { Write-LogLine WARN "Access denied, skipped: $Path" }
            default  { Write-LogLine ERROR ("Could not process {0}. {1}" -f $Path, $ErrorRecord.Exception.GetBaseException().Message) }
        }
    }
}

function Test-IsRecent {
    param([System.IO.FileSystemInfo]$Item)
    if (-not $script:MinAgeCutoff) { return $false }
    # Installers often extract files with old modified dates, so creation time counts too
    $newest = if ($Item.LastWriteTime -gt $Item.CreationTime) { $Item.LastWriteTime } else { $Item.CreationTime }
    return ($newest -gt $script:MinAgeCutoff)
}

# Returns $true when the file is gone (Cleanup) or would be removed (Scan)
function Process-File {
    param(
        [System.IO.FileInfo]$File,
        [ValidateSet('Scan','Cleanup')] [string]$Mode
    )
    $d = $script:RunData
    $d.FilesSeen++
    if (Test-IsRecent $File) {
        $d.SkippedRecent++
        return $false
    }

    $length = [int64]0
    try { $length = $File.Length } catch { }
    $d.FoundBytes += $length
    if ($Mode -ne 'Cleanup') { return $true }

    try {
        if ($File.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $File.Attributes = [System.IO.FileAttributes]::Normal
        }
        $File.Delete()
        $d.FilesDeleted++
        $d.FreedBytes += $length
        return $true
    }
    catch {
        Register-Failure -Path $File.FullName -ErrorRecord $_
        return $false
    }
}

# Walks a folder bottom-up, removing what it can and keeping the folder if anything inside stays
function Process-Folder {
    param(
        [System.IO.DirectoryInfo]$Directory,
        [ValidateSet('Scan','Cleanup')] [string]$Mode
    )
    $d = $script:RunData
    $d.DirectoriesSeen++
    Invoke-UiPump

    # Never descend into junctions or symbolic links; only the link itself is removed
    if ($Directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        if (Test-IsRecent $Directory) {
            $d.SkippedRecent++
            return $false
        }
        if ($Mode -ne 'Cleanup') { return $true }
        try {
            [System.IO.Directory]::Delete($Directory.FullName, $false)
            $d.DirectoriesDeleted++
            return $true
        }
        catch {
            Register-Failure -Path $Directory.FullName -ErrorRecord $_
            return $false
        }
    }

    try { $children = $Directory.GetFileSystemInfos() }
    catch {
        Register-Failure -Path $Directory.FullName -ErrorRecord $_
        return $false
    }

    if ($children.Count -eq 0 -and (Test-IsRecent $Directory)) {
        $d.SkippedRecent++
        return $false
    }

    $allRemoved = $true
    foreach ($child in $children) {
        if ($script:CancelRequested) { return $false }
        if ($script:PumpWatch.ElapsedMilliseconds -ge 50) { Invoke-UiPump }
        if ($child -is [System.IO.DirectoryInfo]) {
            $removed = Process-Folder -Directory $child -Mode $Mode
        }
        else {
            $removed = Process-File -File $child -Mode $Mode
        }
        if (-not $removed) { $allRemoved = $false }
    }

    if (-not $allRemoved) { return $false }
    if ($Mode -ne 'Cleanup') { return $true }

    try {
        if ($Directory.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $Directory.Attributes = $Directory.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
        }
        $Directory.Delete($false)
        $d.DirectoriesDeleted++
        return $true
    }
    catch {
        Register-Failure -Path $Directory.FullName -ErrorRecord $_
        return $false
    }
}

function Get-CounterSnapshot {
    $snapshot = @{}
    foreach ($name in $script:CounterNames) { $snapshot[$name] = $script:RunData[$name] }
    return $snapshot
}

function Process-Path {
    param(
        [string]$Path,
        [ValidateSet('Scan','Cleanup')] [string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        $script:RunData.PathsMissing++
        if ($script:VerboseLog) { Write-LogLine INFO "Not present: $Path" }
        return
    }

    $script:RunData.PathsChecked++
    Set-CurrentAction $Path

    try {
        $children = (New-Object System.IO.DirectoryInfo($Path)).GetFileSystemInfos()
    }
    catch {
        Register-Failure -Path $Path -ErrorRecord $_ -AlwaysLog
        return
    }

    $before = Get-CounterSnapshot
    foreach ($child in $children) {
        if ($script:CancelRequested) { break }
        if ($child -is [System.IO.DirectoryInfo]) {
            $removed = Process-Folder -Directory $child -Mode $Mode
            if ($removed -and $Mode -eq 'Cleanup' -and $script:VerboseLog) { Write-LogLine SUCCESS "Removed folder: $($child.FullName)" }
        }
        else {
            $removed = Process-File -File $child -Mode $Mode
            if ($removed -and $Mode -eq 'Cleanup' -and $script:VerboseLog) { Write-LogLine SUCCESS "Deleted file: $($child.FullName)" }
        }
    }

    $delta = @{}
    foreach ($name in $script:CounterNames) { $delta[$name] = $script:RunData[$name] - $before[$name] }

    if ($Mode -eq 'Cleanup') {
        $summaryText = "{0}: {1} freed ({2:N0} files, {3:N0} folders removed)" -f $Path, (Format-Bytes $delta.FreedBytes), $delta.FilesDeleted, $delta.DirectoriesDeleted
    }
    else {
        $summaryText = "{0}: {1} reclaimable ({2:N0} files, {3:N0} folders)" -f $Path, (Format-Bytes $delta.FoundBytes), $delta.FilesSeen, $delta.DirectoriesSeen
    }
    $skips = @()
    if ($delta.SkippedRecent) { $skips += ('{0:N0} recent' -f $delta.SkippedRecent) }
    if ($delta.Locked) { $skips += ('{0:N0} in use' -f $delta.Locked) }
    if ($delta.Denied) { $skips += ('{0:N0} access denied' -f $delta.Denied) }
    if ($delta.Errors) { $skips += ('{0:N0} errors' -f $delta.Errors) }
    if ($skips) { $summaryText += '; skipped ' + ($skips -join ', ') }
    Write-LogLine INFO $summaryText
}

function Measure-FolderBytes {
    param([string]$Path)
    $total = [int64]0
    $pending = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $pending.Push((New-Object System.IO.DirectoryInfo($Path)))
    while ($pending.Count -gt 0) {
        $folder = $pending.Pop()
        Invoke-UiPump
        try { $entries = $folder.GetFileSystemInfos() } catch { continue }
        foreach ($entry in $entries) {
            if ($entry -is [System.IO.DirectoryInfo]) {
                if (-not ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $pending.Push($entry) }
            }
            else {
                $total += $entry.Length
            }
        }
    }
    return $total
}

function Get-RecycleBinBytes {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $total = [int64]0
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -or -not $drive.IsReady) { continue }
        $bin = Join-Path $drive.RootDirectory.FullName ('$Recycle.Bin\' + $sid)
        if (Test-Path -LiteralPath $bin) { $total += Measure-FolderBytes -Path $bin }
    }
    return $total
}

function Clear-RecycleBinSafe {
    param([string]$Mode)
    if (-not $chkRecycleBin.Checked) { return }

    Set-CurrentAction 'Recycle Bin'
    $before = Get-RecycleBinBytes
    $script:RunData.FoundBytes += $before

    if ($Mode -eq 'Scan') {
        Write-LogLine INFO ("Recycle Bin: {0} reclaimable" -f (Format-Bytes $before))
        return
    }
    if ($before -eq 0) {
        Write-LogLine INFO 'Recycle Bin: already empty.'
        return
    }

    $failure = ''
    try { Clear-RecycleBin -Force -ErrorAction Stop }
    catch { $failure = $_.Exception.Message }

    $after = Get-RecycleBinBytes
    $freed = [Math]::Max([int64]0, $before - $after)
    $script:RunData.FreedBytes += $freed
    if ($after -eq 0) {
        Write-LogLine SUCCESS ("Recycle Bin emptied: {0} freed" -f (Format-Bytes $freed))
    }
    else {
        $script:RunData.Errors++
        Write-LogLine WARN ("Recycle Bin only partly emptied: {0} freed, {1} left. {2}" -f (Format-Bytes $freed), (Format-Bytes $after), $failure)
    }
}

function Clear-EventLogsSafe {
    param([string]$Mode)
    if (-not $chkEventLogs.Checked) { return }

    Set-CurrentAction 'Windows event logs'
    $session = [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession
    try { $logNames = @($session.GetLogNames()) }
    catch {
        $script:RunData.Errors++
        Write-LogLine WARN "Could not list event logs. $($_.Exception.Message)"
        return
    }

    if ($Mode -eq 'Scan') {
        Write-LogLine INFO ("Event Logs: {0} logs would be cleared (not counted as reclaimable space)." -f $logNames.Count)
        return
    }

    $cleared = 0
    $failed = 0
    foreach ($logName in $logNames) {
        if ($script:CancelRequested) { break }
        try {
            $session.ClearLog($logName)
            $cleared++
        }
        catch {
            $failed++
        }
        Invoke-UiPump
    }
    Write-LogLine SUCCESS "Event logs cleared: $cleared"
    if ($failed) {
        Write-LogLine INFO "$failed logs could not be cleared. These are usually analytic or debug channels that Windows does not let you clear."
    }
}

function Get-ShadowCopyCount {
    try { return @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop).Count }
    catch { return -1 }
}

function Clear-ShadowCopiesSafe {
    param([string]$Mode)
    if (-not $chkShadowCopies.Checked) { return }

    Set-CurrentAction 'Shadow copies / restore points'
    $count = Get-ShadowCopyCount

    if ($Mode -eq 'Scan') {
        if ($count -ge 0) { Write-LogLine INFO "Shadow Copies: $count present, all would be deleted." }
        else { Write-LogLine WARN 'Shadow Copies: could not count them.' }
        return
    }
    if ($count -eq 0) {
        Write-LogLine INFO 'Shadow Copies: none present.'
        return
    }

    $output = & vssadmin.exe delete shadows /all /quiet 2>&1
    if ($LASTEXITCODE -eq 0) {
        $remaining = Get-ShadowCopyCount
        if ($count -gt 0 -and $remaining -ge 0) { Write-LogLine SUCCESS ("Shadow copies deleted: {0}" -f ($count - $remaining)) }
        else { Write-LogLine SUCCESS 'Shadow copies deleted.' }
    }
    else {
        $script:RunData.Errors++
        Write-LogLine WARN ("vssadmin could not delete shadow copies (exit code {0}). {1}" -f $LASTEXITCODE, (($output | Out-String).Trim()))
    }
}

#endregion

#region Workflow

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

    $message = "You are about to run cleanup for:`r`n`r`n- $selected`r`n`r`nPreset: $(Get-SelectedPreset)`r`nSkip items newer than: $(Get-MinAgeText)"
    if ($chkBrowserCaches.Checked) {
        $browsers = @(Get-RunningBrowsers)
        if ($browsers.Count) {
            $message += "`r`n`r`nStill open: $($browsers -join ', '). Cache files they are using will be skipped, so close them first for a fuller cleanup."
        }
    }
    $message += "`r`n`r`nDeleted files do not go to the Recycle Bin. Continue?"

    $response = Show-AppDialog -Title 'Confirm Cleanup' -Message $message -Kind Question -Buttons YesNo
    return ($response -eq 'Yes')
}

function Execute-Workflow {
    param([ValidateSet('Scan','Cleanup')] [string]$Mode)
    if ($script:IsRunning) { return }

    $categories = @(Get-EnabledCategories)
    $specials = @()
    if ($chkRecycleBin.Checked) { $specials += 'Recycle Bin' }
    if ($chkEventLogs.Checked) { $specials += 'Event Logs' }
    if ($chkShadowCopies.Checked) { $specials += 'Shadow Copies' }

    if (-not $categories.Count -and -not $specials.Count) {
        [void](Show-AppDialog -Message 'Nothing is selected. Pick a preset or tick at least one option.')
        return
    }

    if ($Mode -eq 'Cleanup') {
        if (-not (Confirm-CleanupSelection)) { return }

        if ($chkEventLogs.Checked -or $chkShadowCopies.Checked) {
            $risky = @()
            if ($chkEventLogs.Checked) { $risky += '- Every Windows event log will be cleared' }
            if ($chkShadowCopies.Checked) { $risky += '- All shadow copies and System Restore points will be deleted' }
            $response = Show-AppDialog -Title 'Confirm Aggressive Cleanup' -Kind Warning -Buttons YesNo -DefaultNo -Message (
                "You selected aggressive cleanup options:`r`n`r`n{0}`r`n`r`nThis cannot be undone. Continue?" -f ($risky -join "`r`n")
            )
            if ($response -ne 'Yes') { return }
        }
    }

    $script:LogLines.Clear()
    $txtLog.Clear()
    Start-NewLog
    $script:RunData = New-RunData
    $script:RunData.Mode = $Mode
    $script:RunData.Preset = Get-SelectedPreset
    $script:RunData.MinAge = Get-MinAgeText
    foreach ($c in $categories) { $script:RunData.Categories.Add($c.Name) | Out-Null }
    foreach ($s in $specials) { $script:RunData.Categories.Add($s) | Out-Null }

    $script:CancelRequested = $false
    $script:VerboseLog = $chkVerbose.Checked
    $hours = Get-SelectedMinAgeHours
    $script:MinAgeCutoff = if ($hours -gt 0) { (Get-Date).AddHours(-$hours) } else { $null }
    $runWatch = [System.Diagnostics.Stopwatch]::StartNew()

    Set-RunState -Running:$true
    Set-ProgressSafe 0
    Set-Status $(if ($Mode -eq 'Scan') { 'Scanning...' } else { 'Cleaning up...' })
    Set-CurrentAction 'Preparing'
    Update-SummaryPanel

    $finished = $false
    try {
        Write-LogLine INFO "$AppName $AppVersion"
        Write-LogLine INFO ("Mode: {0} | Preset: {1} | Skip items newer than: {2}" -f $Mode, $script:RunData.Preset, $script:RunData.MinAge)
        if ($chkBrowserCaches.Checked) {
            $browsers = @(Get-RunningBrowsers)
            if ($browsers.Count) { Write-LogLine WARN ("Open browsers: {0}. Cache files they are using will be skipped." -f ($browsers -join ', ')) }
        }

        $totalUnits = $specials.Count
        foreach ($category in $categories) { $totalUnits += @($category.Paths).Count }
        $totalUnits = [Math]::Max(1, $totalUnits)
        $doneUnits = 0

        foreach ($category in $categories) {
            if ($script:CancelRequested) { break }
            Write-LogLine INFO "Category: $($category.Name)"
            if (-not @($category.Paths).Count) { Write-LogLine INFO 'Nothing to check for this category.' }

            foreach ($path in $category.Paths) {
                if ($script:CancelRequested) { break }
                Process-Path -Path $path -Mode $Mode
                $doneUnits++
                Set-ProgressSafe ([int](($doneUnits / $totalUnits) * 100))
            }
        }

        foreach ($special in $specials) {
            if ($script:CancelRequested) { break }
            switch ($special) {
                'Recycle Bin'   { Clear-RecycleBinSafe -Mode $Mode }
                'Event Logs'    { Clear-EventLogsSafe -Mode $Mode }
                'Shadow Copies' { Clear-ShadowCopiesSafe -Mode $Mode }
            }
            $doneUnits++
            Set-ProgressSafe ([int](($doneUnits / $totalUnits) * 100))
        }

        $script:RunData.Cancelled = $script:CancelRequested
        $script:RunData.EndTime = (Get-Date).ToString('s')
        Save-SummaryFile
        Update-SummaryPanel

        if ($script:CancelRequested) {
            Set-Status "$Mode cancelled"
            if ($Mode -eq 'Cleanup') { Write-LogLine WARN 'Cancelled. Items processed before cancelling were deleted.' }
            else { Write-LogLine WARN 'Cancelled. The results are partial.' }
        }
        else {
            Set-ProgressSafe 100
            Set-Status "$Mode complete"
        }
        Set-CurrentAction ("Finished in {0:N1} seconds" -f $runWatch.Elapsed.TotalSeconds)
        Write-LogLine INFO "Summary saved to $script:CurrentSummaryFile"
        $finished = $true
    }
    catch {
        $script:RunData.Errors++
        Set-Status 'Stopped by an error'
        Write-LogLine ERROR $_.Exception.Message
        Update-SummaryPanel
    }
    finally {
        Set-RunState -Running:$false
    }

    if ($script:CloseAfterRun) {
        $form.Close()
        return
    }
    if ($finished) {
        $kind = if ($script:RunData.Cancelled) { 'Info' } elseif ($script:RunData.Errors) { 'Warning' } else { 'Success' }
        [void](Show-AppDialog -Title "$AppName - $Mode" -Message (Get-CompletionMessage) -Kind $kind)
    }
}

function Apply-Preset {
    param([string]$Preset)
    $script:ApplyingPreset = $true
    try {
        $selection = switch ($Preset) {
            'Safe'       { @('SystemTemp','AllUserTemp','RecycleBin') }
            'Standard'   { @('SystemTemp','AllUserTemp','BrowserCaches','PrinterSpool','RecycleBin') }
            'Aggressive' { @('SystemTemp','AllUserTemp','BrowserCaches','PrinterSpool','RecycleBin','Prefetch','EventLogs','ShadowCopies') }
            default      { $null }
        }
        if ($null -ne $selection) {
            foreach ($check in $script:OptionChecks) { $check.Checked = $selection -contains $check.Name }
        }

        $lblPresetInfo.Text = switch ($Preset) {
            'Safe'       { 'Safe: temp folders and the Recycle Bin. Good for routine cleanup.' }
            'Standard'   { 'Standard: everything in Safe plus browser caches and printer spool files. Recommended for most runs.' }
            'Aggressive' { 'Aggressive: also clears Prefetch, event logs, and shadow copies (restore points). Use only when you understand the trade-offs.' }
            default      { 'Custom: pick exactly what you want to include.' }
        }
    }
    finally {
        $script:ApplyingPreset = $false
    }
}

#endregion

#region Window

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.OwnerDraw = $true
$toolTip.AutoPopDelay = 20000
$toolTip.InitialDelay = 400
$toolTip.Add_Popup({
    $size = [System.Windows.Forms.TextRenderer]::MeasureText($toolTip.GetToolTip($_.AssociatedControl), $script:FontBase)
    $_.ToolTipSize = New-Object System.Drawing.Size(($size.Width + 20), ($size.Height + 14))
})
$toolTip.Add_Draw({
    $t = $script:Theme
    $fill = New-Object System.Drawing.SolidBrush($t.Surface)
    $border = New-Object System.Drawing.Pen($t.Border)
    $_.Graphics.FillRectangle($fill, $_.Bounds)
    $_.Graphics.DrawRectangle($border, 0, 0, ($_.Bounds.Width - 1), ($_.Bounds.Height - 1))
    $textBounds = New-Object System.Drawing.Rectangle(10, 7, ($_.Bounds.Width - 20), ($_.Bounds.Height - 14))
    [System.Windows.Forms.TextRenderer]::DrawText($_.Graphics, $_.ToolTipText, $script:FontBase, $textBounds, $t.Text, [System.Windows.Forms.TextFormatFlags]::NoPrefix)
    $fill.Dispose()
    $border.Dispose()
})

$form = New-Object System.Windows.Forms.Form
$form.Text = $AppName
$form.Tag = 'window'
$form.Font = $script:FontBase
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(1100, 860)
$form.MinimumSize = New-Object System.Drawing.Size(1116, 820)
$form.KeyPreview = $true
Enable-DoubleBuffer $form
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:windir\System32\cleanmgr.exe") } catch { }

$anchorTopRight = [System.Windows.Forms.AnchorStyles]'Top, Right'
$anchorTopWide  = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
$anchorFill     = [System.Windows.Forms.AnchorStyles]'Top, Bottom, Left, Right'

# Header
[void](New-Label -Parent $form -Text $AppName -X 17 -Y 12 -Font $script:FontTitle)
[void](New-Label -Parent $form -Text 'Scan first to preview what can be freed. Hover over any option to see the exact folders it covers.' -X 21 -Y 52 -Role 'subtext')

$lblThemeCaption = New-Label -Parent $form -Text 'Theme' -X 822 -Y 22 -Role 'subtext'
$lblThemeCaption.Anchor = $anchorTopRight
$themeButtons = New-SegmentedControl -Parent $form -Items @('System','Light','Dark') -X 864 -Y 16 -ItemWidth 72 -Height 28
$themeButtons['System'].Parent.Anchor = $anchorTopRight

$lblAdmin = New-Label -Parent $form -Text 'Running as Administrator' -X 680 -Y 52 -Role 'success' -Font $script:FontStatus -Width 400 -Height 20
$lblAdmin.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblAdmin.Anchor = $anchorTopRight

# Preset, age filter and verbose
[void](New-Label -Parent $form -Text 'Preset' -X 20 -Y 90 -Role 'subtext')
$presetButtons = New-SegmentedControl -Parent $form -Items @('Safe','Standard','Aggressive','Custom') -X 20 -Y 110 -ItemWidth 96
[void](New-Label -Parent $form -Text 'Skip items newer than' -X 432 -Y 90 -Role 'subtext')
$ageButtons = New-SegmentedControl -Parent $form -Items @($script:AgeHours.Keys) -X 432 -Y 110 -ItemWidth 84
$ageTip = "Keeps files and folders created or changed within this window.`nRecent temp files are often still in use by installers or open apps."
foreach ($ageButton in $ageButtons.Values) { $toolTip.SetToolTip($ageButton, $ageTip) }
$chkVerbose = New-CheckOption -Parent $form -Name 'Verbose' -Text 'Verbose log' -X 798 -Y 113 -Tip 'Also log every top-level item that is deleted, plus each file that is skipped.'

$pnlPresetInfo = New-Card -Parent $form -X 20 -Y 156 -Width 1060 -Height 44 -Role 'infostrip'
$pnlPresetInfo.Anchor = $anchorTopWide
$lblPresetInfo = New-Label -Parent $pnlPresetInfo -Text '' -X 22 -Y 1 -Width 1024 -Height 42
$lblPresetInfo.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblPresetInfo.Anchor = $anchorTopWide

# Option cards
$cardCore = New-Card -Parent $form -X 20 -Y 214 -Width 520 -Height 200 -Title 'Core Cleanup'
$chkSystemTemp = New-CheckOption -Parent $cardCore -Name 'SystemTemp' -X 16 -Y 46 `
    -Text 'System temp, logs, minidumps, Windows Update downloads' `
    -Tip "Windows\Temp, Windows\Logs, Windows\Minidump`nWindows Update download cache (SoftwareDistribution\Download)`nQueued Windows Error Reporting files (ProgramData\Microsoft\Windows\WER)"
$chkAllUserTemp = New-CheckOption -Parent $cardCore -Name 'AllUserTemp' -X 16 -Y 74 `
    -Text 'Temp files, crash dumps, and caches for all users' `
    -Tip "For every user profile:`nAppData\Local\Temp, CrashDumps, INetCache`nExplorer thumbnail and icon caches, Windows Error Reporting"
$chkBrowserCaches = New-CheckOption -Parent $cardCore -Name 'BrowserCaches' -X 16 -Y 102 `
    -Text 'Browser caches (Chrome, Edge, Brave, Firefox)' `
    -Tip "Cache, Code Cache and GPUCache for every Chrome, Edge and Brave profile`nFirefox cache2, startupCache and thumbnails`nBookmarks, passwords, history and cookies are not touched."
$chkPrinterSpool = New-CheckOption -Parent $cardCore -Name 'PrinterSpool' -X 16 -Y 130 `
    -Text 'Printer spool temp files' `
    -Tip "Windows\System32\spool\PRINTERS`nClears stuck print jobs. Anything waiting to print is cancelled."
$chkRecycleBin = New-CheckOption -Parent $cardCore -Name 'RecycleBin' -X 16 -Y 158 `
    -Text 'Recycle Bin' `
    -Tip 'Empties your Recycle Bin on every fixed drive.'

$cardAgg = New-Card -Parent $form -X 560 -Y 214 -Width 520 -Height 200 -Title 'Aggressive Options' -TitleRole 'warning'
$chkPrefetch = New-CheckOption -Parent $cardAgg -Name 'Prefetch' -X 16 -Y 46 `
    -Text 'Prefetch' `
    -Tip "Windows\Prefetch`nWindows rebuilds it, but apps can start slower until it does."
$chkEventLogs = New-CheckOption -Parent $cardAgg -Name 'EventLogs' -X 16 -Y 74 `
    -Text 'Clear all Windows event logs' `
    -Tip "Clears every Windows event log.`nYou lose the history used to troubleshoot crashes and errors."
$chkShadowCopies = New-CheckOption -Parent $cardAgg -Name 'ShadowCopies' -X 16 -Y 102 `
    -Text 'Delete all shadow copies / restore points' `
    -Tip "Deletes every Volume Shadow Copy, including all System Restore points.`nThis cannot be undone."
$lblAggInfo = New-Label -Parent $cardAgg -X 18 -Y 138 -Role 'subtext' -Width 486 -Height 48 `
    -Text 'These are intentionally not default. Prefetch speeds up app launches, event logs help troubleshooting, and shadow copies are your rollback points.'

$script:OptionChecks = @($chkSystemTemp, $chkAllUserTemp, $chkBrowserCaches, $chkPrinterSpool, $chkRecycleBin, $chkPrefetch, $chkEventLogs, $chkShadowCopies)

# Actions
$btnScan = New-AppButton -Parent $form -Text 'Scan' -X 20 -Y 430 -Width 110
$btnRun = New-AppButton -Parent $form -Text 'Run Cleanup' -X 138 -Y 430 -Width 140 -Role 'primary'
$btnCancel = New-AppButton -Parent $form -Text 'Cancel' -X 286 -Y 430 -Width 100
$btnCancel.Enabled = $false
$btnExport = New-AppButton -Parent $form -Text 'Export Summary' -X 792 -Y 430 -Width 140
$btnExport.Anchor = $anchorTopRight
$btnExport.Enabled = $false
$btnOpenLog = New-AppButton -Parent $form -Text 'Open Log Folder' -X 940 -Y 430 -Width 140
$btnOpenLog.Anchor = $anchorTopRight
$toolTip.SetToolTip($btnScan, 'Counts what would be removed. Nothing is deleted.')
$toolTip.SetToolTip($btnCancel, 'Stops after the current item (Esc).')

# Progress and status
$progressBar = New-Object System.Windows.Forms.Panel
$progressBar.Tag = 'progress'
$progressBar.Location = New-Object System.Drawing.Point(20, 484)
$progressBar.Size = New-Object System.Drawing.Size(1000, 8)
$progressBar.Anchor = $anchorTopWide
Enable-DoubleBuffer $progressBar
$progressBar.Add_Resize({ $this.Invalidate() })
$progressBar.Add_Paint({
    $t = $script:Theme
    $g = $_.Graphics
    $g.Clear($this.BackColor)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $barHeight = $this.Height - 1
    $radius = $barHeight / 2
    $trackPath = New-RoundedPath -Rect (New-Object System.Drawing.RectangleF(0, 0, ($this.Width - 1), $barHeight)) -Radius $radius
    $trackBrush = New-Object System.Drawing.SolidBrush($t.Track)
    $g.FillPath($trackBrush, $trackPath)
    if ($script:ProgressValue -gt 0) {
        $fillWidth = [Math]::Max($barHeight, ($this.Width - 1) * $script:ProgressValue / 100)
        $fillPath = New-RoundedPath -Rect (New-Object System.Drawing.RectangleF(0, 0, $fillWidth, $barHeight)) -Radius $radius
        $fillBrush = New-Object System.Drawing.SolidBrush($t.Accent)
        $g.FillPath($fillBrush, $fillPath)
        $fillBrush.Dispose()
        $fillPath.Dispose()
    }
    $trackBrush.Dispose()
    $trackPath.Dispose()
})
$form.Controls.Add($progressBar)

$lblProgressPercent = New-Label -Parent $form -Text '0%' -X 1030 -Y 478 -Role 'subtext' -Width 50 -Height 20
$lblProgressPercent.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblProgressPercent.Anchor = $anchorTopRight

$lblStatus = New-Label -Parent $form -Text 'Ready' -X 20 -Y 500 -Font $script:FontStatus
$lblCurrentAction = New-Label -Parent $form -Text '' -X 340 -Y 500 -Role 'subtext' -Width 740 -Height 20
$lblCurrentAction.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblCurrentAction.AutoEllipsis = $true
$lblCurrentAction.Anchor = $anchorTopWide

# Summary
$cardSummary = New-Card -Parent $form -X 20 -Y 532 -Width 1060 -Height 128 -Title 'Summary'
$cardSummary.Anchor = $anchorTopWide
$lblModeValue    = New-StatTile -Parent $cardSummary -Caption 'Mode'      -X 16  -Y 40
$lblPresetValue  = New-StatTile -Parent $cardSummary -Caption 'Preset'    -X 278 -Y 40
$lblSpaceValue   = New-StatTile -Parent $cardSummary -Caption 'Space'     -X 540 -Y 40 -Role 'accent'
$lblErrorsValue  = New-StatTile -Parent $cardSummary -Caption 'Errors'    -X 802 -Y 40
$lblPathsValue   = New-StatTile -Parent $cardSummary -Caption 'Locations' -X 16  -Y 82
$lblFilesValue   = New-StatTile -Parent $cardSummary -Caption 'Files'     -X 278 -Y 82
$lblDirsValue    = New-StatTile -Parent $cardSummary -Caption 'Folders'   -X 540 -Y 82
$lblSkippedValue = New-StatTile -Parent $cardSummary -Caption 'Skipped'   -X 802 -Y 82

# Log
$cardLog = New-Card -Parent $form -X 20 -Y 672 -Width 1060 -Height 168 -Title 'Detailed Log'
$cardLog.Anchor = $anchorFill
$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Tag = 'log'
$txtLog.ReadOnly = $true
$txtLog.DetectUrls = $false
$txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtLog.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$txtLog.Font = $script:FontLog
$txtLog.Location = New-Object System.Drawing.Point(16, 40)
$txtLog.Size = New-Object System.Drawing.Size(1028, 116)
$txtLog.Anchor = $anchorFill
$cardLog.Controls.Add($txtLog)

$script:RunLockedControls = @($btnScan, $btnRun, $btnOpenLog, $presetButtons['Safe'].Parent, $ageButtons['Any age'].Parent, $chkVerbose) + $script:OptionChecks

#endregion

#region Events

foreach ($themeButton in $themeButtons.Values) {
    $themeButton.Add_CheckedChanged({
        if ($this.Checked) { Set-AppTheme -Choice $this.Text }
    })
}

foreach ($presetButton in $presetButtons.Values) {
    $presetButton.Add_CheckedChanged({
        if ($this.Checked) { Apply-Preset -Preset $this.Text }
    })
}

foreach ($cb in $script:OptionChecks) {
    $cb.Add_CheckedChanged({
        if (-not $script:ApplyingPreset -and -not $presetButtons['Custom'].Checked) {
            $presetButtons['Custom'].Checked = $true
        }
    })
}

$btnScan.Add_Click({ Execute-Workflow -Mode 'Scan' })
$btnRun.Add_Click({ Execute-Workflow -Mode 'Cleanup' })
$btnCancel.Add_Click({ Request-Cancel })

$btnOpenLog.Add_Click({
    if (-not (Test-Path $LogDir)) { return }
    Start-Process explorer.exe $LogDir | Out-Null
})

$btnExport.Add_Click({
    if (-not $script:LastSummaryText) { return }
    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Filter = 'Text files (*.txt)|*.txt'
    $saveDialog.FileName = "TempCleanerSummary_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    if ($saveDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-Content -Path $saveDialog.FileName -Value $script:LastSummaryText -Encoding UTF8
        [void](Show-AppDialog -Message "Summary exported to:`r`n$($saveDialog.FileName)" -Kind Success)
    }
})

$form.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and $script:IsRunning) { Request-Cancel }
})

$form.Add_Load({
    Update-WindowFrame -Window $form
    Update-ScrollbarTheme
})

# Focus a button first: a radio button that receives focus checks itself
$form.Add_Shown({ $form.ActiveControl = $btnScan })

# Pick up a Windows light/dark switch the next time the window is activated
$form.Add_Activated({
    if ($script:ThemeChoice -eq 'System' -and (Get-SystemTheme) -ne $script:ThemeName) { Set-AppTheme -Choice 'System' }
})

$form.Add_FormClosing({
    if ($script:IsRunning) {
        $_.Cancel = $true
        if (-not $script:CloseAfterRun) {
            $response = Show-AppDialog -Title 'Run in progress' -Kind Warning -Buttons YesNo -DefaultNo `
                -Message "A $($script:RunData.Mode.ToLower()) is still running.`r`n`r`nStop it and close the app?"
            if ($response -eq 'Yes') {
                $script:CloseAfterRun = $true
                Request-Cancel
            }
        }
        return
    }
    Save-Settings
})

#endregion

$settings = Read-Settings
Set-AppTheme -Choice $settings.Theme
$themeButtons[$settings.Theme].Checked = $true
foreach ($name in $script:AgeHours.Keys) {
    if ($script:AgeHours[$name] -eq [int]$settings.MinAgeHours) { $ageButtons[$name].Checked = $true }
}
$chkVerbose.Checked = [bool]$settings.Verbose
$presetButtons[$settings.Preset].Checked = $true
if ($settings.Preset -eq 'Custom') {
    $script:ApplyingPreset = $true
    foreach ($check in $script:OptionChecks) { $check.Checked = @($settings.CustomSelection) -contains $check.Name }
    $script:ApplyingPreset = $false
}
Set-CurrentAction 'Pick a preset, then Scan to preview or Run Cleanup.'
[void]$form.ShowDialog()
