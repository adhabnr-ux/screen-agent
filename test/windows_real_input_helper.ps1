# Helper window for test/windows_real_input.ps1 (real Windows only).
# Shows a top-most form with a multiline TextBox and writes its state to a JSON file every 200 ms.
# Exits when the stop file appears.
param([string]$StatePath, [string]$StopPath)
$ErrorActionPreference = 'Stop'
try {
    Add-Type -Namespace SaTest -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    $null = [SaTest.Dpi]::SetProcessDPIAware()
} catch { }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Screen Agent input test'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point -ArgumentList 200, 200
$form.Size = New-Object System.Drawing.Size -ArgumentList 500, 300
$form.TopMost = $true

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.Dock = [System.Windows.Forms.DockStyle]::Fill
$box.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 12
$form.Controls.Add($box)

$script:locChanges = 0
$script:shown = $false
$script:changes = 0; $script:firstChangeMs = 0; $script:lastChangeMs = 0
$clock = [Diagnostics.Stopwatch]::StartNew()
$form.add_LocationChanged({ $script:locChanges++ })
$box.add_TextChanged({
    $script:changes++
    $script:lastChangeMs = $clock.ElapsedMilliseconds
    if ($script:changes -eq 1) { $script:firstChangeMs = $script:lastChangeMs }
})
# The launcher starts this process minimized (to hide the console), which would also minimize
# the form's first show. Put the form back on screen before reporting it as shown.
$form.add_Shown({
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $script:shown = $true
})

$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.add_Tick({
    try {
        if (Test-Path -LiteralPath $StopPath) { $timer.Stop(); $form.Close(); return }
        $client = $form.PointToScreen((New-Object System.Drawing.Point -ArgumentList 0, 0))
        $tb = $box.PointToScreen((New-Object System.Drawing.Point -ArgumentList 0, 0))
        $state = @{
            ready      = $script:shown
            x          = $form.Location.X
            y          = $form.Location.Y
            w          = $form.Width
            h          = $form.Height
            clientTop  = $client.Y
            boxCx      = $tb.X + [int]($box.Width / 2)
            boxCy      = $tb.Y + [int]($box.Height / 2)
            text       = $box.Text
            locChanges = $script:locChanges
            changes       = $script:changes
            firstChangeMs = $script:firstChangeMs
            lastChangeMs  = $script:lastChangeMs
        }
        $tmp = $StatePath + '.tmp'
        [IO.File]::WriteAllText($tmp, ($state | ConvertTo-Json -Compress), $utf8)
        Move-Item -LiteralPath $tmp -Destination $StatePath -Force
    } catch { }
})
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
