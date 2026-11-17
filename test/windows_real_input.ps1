# Real-input test for windows/agent.ps1. Run on a real Windows desktop session (CI runner), once
# per shell:
#   powershell.exe -NoProfile -File test\windows_real_input.ps1 -Shell powershell.exe
#   pwsh.exe       -NoProfile -File test\windows_real_input.ps1 -Shell pwsh.exe
# It opens a small window, lets the agent (driven by test/mock_api.py) click into its text box,
# type, and drag the window by its title bar, then checks what really happened on screen:
# the typed text, the typing pace, where the window ended up, and that the pointer glided.
# Exits non-zero with a message on any failure. Nothing here is stubbed and it is not a dry run.
param(
    [string]$Shell = 'powershell.exe',
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$agent = Join-Path $root 'windows\agent.ps1'
$mock = Join-Path $root 'test\mock_api.py'
$helper = Join-Path $PSScriptRoot 'windows_real_input_helper.ps1'

$work = Join-Path ([IO.Path]::GetTempPath()) ('sa-real-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force
$statePath = Join-Path $work 'state.json'
$stopPath = Join-Path $work 'stop'
$scriptPath = Join-Path $work 'script.json'
$reportPath = Join-Path $work 'report.json'
$outPath = Join-Path $work 'agent.out.txt'
$errPath = Join-Path $work 'agent.err.txt'
$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false

$failures = New-Object System.Collections.Generic.List[string]
function Fail([string]$m) { $failures.Add($m); Write-Host ('FAIL  ' + $m) -ForegroundColor Red }
function Pass([string]$m) { Write-Host ('PASS  ' + $m) -ForegroundColor Green }
function Quote([string]$p) { return "'" + $p.Replace("'", "''") + "'" }
function Read-State {
    for ($i = 0; $i -lt 20; $i++) {
        try {
            if (Test-Path -LiteralPath $statePath) {
                return ([IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json)
            }
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

# Same coordinate space as the agent: physical pixels.
try {
    Add-Type -Namespace SaTest -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    $null = [SaTest.Dpi]::SetProcessDPIAware()
} catch { }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$helperProc = $null; $mockProc = $null; $agentProc = $null
$exitCode = 1
try {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $W = $bounds.Width; $H = $bounds.Height
    $s = [Math]::Min(1.0, [Math]::Min(1280.0 / $W, 800.0 / $H))
    Write-Host ('Shell ' + $Shell + ' | screen ' + $W + 'x' + $H + ' | scale ' + $s)
    function ToShot([double]$v) { return [int][Math]::Round($v * $s) }
    function ToScreen([double]$v) { return [int][Math]::Round($v / $s) }

    # --- 1. helper window --------------------------------------------------------------------
    $helperCmd = '& ([scriptblock]::Create([IO.File]::ReadAllText(' + (Quote $helper) + '))) ' + (Quote $statePath) + ' ' + (Quote $stopPath)
    $helperProc = Start-Process -FilePath $Shell -ArgumentList ('-NoProfile -Command "' + $helperCmd + '"') -WindowStyle Minimized -PassThru
    $st = $null
    for ($i = 0; $i -lt 150; $i++) {
        $st = Read-State
        if ($st -and $st.ready) { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $st -or -not $st.ready) { throw 'The helper window did not appear within 30 s (is this an interactive desktop session?).' }
    Start-Sleep -Milliseconds 600
    $st = Read-State
    for ($i = 0; $i -lt 25 -and ($st.x -lt 0 -or $st.y -lt 0); $i++) { Start-Sleep -Milliseconds 200; $st = Read-State }
    if ($st.x -lt 0 -or $st.y -lt 0) { throw ('The helper window is not on screen (at ' + $st.x + ',' + $st.y + '); it may still be minimized.') }
    Write-Host ('Helper window at ' + $st.x + ',' + $st.y + ' size ' + $st.w + 'x' + $st.h + ', text box centre ' + $st.boxCx + ',' + $st.boxCy)

    # --- 2. the script the mock will play (screenshot-space coordinates) ------------------------
    $clickX = ToShot $st.boxCx; $clickY = ToShot $st.boxCy
    $titleX = ToShot ($st.x + 150)
    $titleY = ToShot (($st.y + $st.clientTop) / 2.0)
    $endX = $titleX + 180; $endY = $titleY + 120
    if ($endX -ge (ToShot $W) -or $endY -ge (ToShot $H)) { throw ('The screen is too small for the drag test (' + $W + 'x' + $H + ').') }
    $expectDx = (ToScreen $endX) - (ToScreen $titleX)
    $expectDy = (ToScreen $endY) - (ToScreen $titleY)
    $expectText = 'h' + [char]0xE9 + 'llo w' + [char]0xF6 + 'rld 123'
    $bs = [string][char]92   # backslash: the text goes into the JSON as \\u escapes so this file stays ASCII
    $json = '[' +
        '[{"name":"left_click","input":{"coordinate":[' + $clickX + ',' + $clickY + ']}},' +
         '{"name":"type","input":{"text":"h' + $bs + 'u00e9llo w' + $bs + 'u00f6rld 123"}}],' +
        '[{"name":"left_click_drag","input":{"start_coordinate":[' + $titleX + ',' + $titleY + '],"coordinate":[' + $endX + ',' + $endY + ']}}],' +
        '[{"name":"screenshot","input":{}}]' +
        ']'
    [IO.File]::WriteAllText($scriptPath, $json, $utf8)
    Write-Host ('Script: ' + $json)

    # --- 3. mock API ---------------------------------------------------------------------------
    $port = Get-Random -Minimum 20000 -Maximum 40000
    $env:MOCK_SCRIPT = $scriptPath
    $env:MOCK_REPORT = $reportPath
    $mockProc = Start-Process -FilePath $Python -ArgumentList ('"' + $mock + '" --port ' + $port) -WindowStyle Hidden -PassThru
    $env:MOCK_SCRIPT = $null
    $up = $false
    for ($i = 0; $i -lt 100; $i++) {
        try {
            $null = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $port + '/v1/models?limit=1') -Headers @{ 'x-api-key' = 'sk-test-good' } -UseBasicParsing -TimeoutSec 2
            $up = $true; break
        } catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $up) { throw ('The mock API did not start (' + $Python + ' ' + $mock + ').') }

    # --- 4. run the agent for real -------------------------------------------------------------
    # Park the pointer far from the window (and away from the stop corner) so the first move is long.
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point -ArgumentList ($W - 60), ($H - 60)
    $env:SCREEN_AGENT_BASE_URL = 'http://127.0.0.1:' + $port
    $env:ANTHROPIC_API_KEY = 'sk-test-good'
    $env:SCREEN_AGENT_TASK = 'Run the scripted input test'
    $env:APPDATA = $work
    foreach ($n in @('SCREEN_AGENT_DRY_RUN', 'SCREEN_AGENT_MODE', 'SCREEN_AGENT_TEST_STUB', 'SCREEN_AGENT_TEST_NO_COMPILE', 'SCREEN_AGENT_SMOOTH', 'SCREEN_AGENT_WPM', 'SCREEN_AGENT_FAST', 'ANTHROPIC_WORKSPACE_ID')) {
        [Environment]::SetEnvironmentVariable($n, $null)
    }
    $agentCmd = '& ([scriptblock]::Create([IO.File]::ReadAllText(' + (Quote $agent) + ')))'
    $agentProc = Start-Process -FilePath $Shell -ArgumentList ('-NoProfile -Command "' + $agentCmd + '"') -NoNewWindow -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
    $null = $agentProc.Handle

    # While it runs: sample the pointer. Positions seen before any text appears belong to the
    # first approach (parked corner -> text box), which is the glide evidence.
    $positions = @{}; $approach = @{}
    $lastLen = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $nextStateAt = 0
    while (-not $agentProc.HasExited) {
        if ($clock.Elapsed.TotalSeconds -gt 180) { throw 'The agent did not finish within 180 s.' }
        $p = [System.Windows.Forms.Cursor]::Position
        $positions[('' + $p.X + ',' + $p.Y)] = 1
        if ($lastLen -eq 0) { $approach[('' + $p.X + ',' + $p.Y)] = 1 }
        if ($clock.ElapsedMilliseconds -ge $nextStateAt) {
            $nextStateAt = $clock.ElapsedMilliseconds + 100
            try {
                $cur = [IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json
                $len = ([string]$cur.text).Length
                if ($len -gt $lastLen) { $lastLen = $len }
            } catch { }
        }
        Start-Sleep -Milliseconds 8
    }
    Start-Sleep -Milliseconds 700
    $final = Read-State

    Write-Host '---- agent output:'
    if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Encoding UTF8 | ForEach-Object { Write-Host ('  | ' + $_) } }
    if ((Test-Path -LiteralPath $errPath) -and (Get-Item -LiteralPath $errPath).Length -gt 0) {
        Write-Host '---- agent errors:'
        Get-Content -LiteralPath $errPath -Encoding UTF8 | ForEach-Object { Write-Host ('  | ' + $_) }
    }

    # --- 5. assertions --------------------------------------------------------------------------
    $report = $null
    try { $report = [IO.File]::ReadAllText($reportPath, $utf8) | ConvertFrom-Json } catch { }
    if ($null -eq $report) { Fail 'No mock report was written.' }
    else {
        Write-Host ('---- mock report: ' + ($report | ConvertTo-Json -Compress -Depth 6))
        $errs = @($report.errors).Count; $aerrs = @($report.action_errors).Count
        if ($report.done -and $errs -eq 0 -and $aerrs -eq 0 -and -not $report.guide) { Pass ('session finished: done, errors [], action_errors [], ' + $report.calls + ' API calls, control mode') }
        else { Fail ('mock report: done=' + $report.done + ' errors=' + ($report.errors -join ' | ') + ' action_errors=' + ($report.action_errors -join ' | ') + ' guide=' + $report.guide) }
    }

    if ($null -eq $final) { Fail 'Could not read the helper window state after the run.' }
    else {
        if ([string]$final.text -ceq $expectText) { Pass ('typed text arrived exactly: "' + $final.text + '"') }
        else { Fail ('text box holds "' + $final.text + '" but expected "' + $expectText + '"') }

        $dx = $final.x - $st.x; $dy = $final.y - $st.y
        if ([Math]::Abs($dx - $expectDx) -le 6 -and [Math]::Abs($dy - $expectDy) -le 6) {
            Pass ('window dragged by (' + $dx + ', ' + $dy + ') px; expected (' + $expectDx + ', ' + $expectDy + ') within 6 px')
        } else {
            Fail ('window moved by (' + $dx + ', ' + $dy + ') px from ' + $st.x + ',' + $st.y + ' to ' + $final.x + ',' + $final.y + '; expected (' + $expectDx + ', ' + $expectDy + ') within 6 px')
        }
        Write-Host ('      (the window reported ' + ($final.locChanges - $st.locChanges) + ' position changes during the drag)')
    }

    if ($null -ne $final -and $final.changes -ge 2) {
        # The helper timestamps every change of the text box. 15 characters at the default 110 WPM
        # = 14 gaps of 0.109 s = about 1.53 s from the first character to the last (15 * 0.109 = 1.64 s
        # for the whole action). Accept 1.2 s to 4 s.
        $span = ($final.lastChangeMs - $final.firstChangeMs) / 1000.0
        if ($final.changes -ge 15 -and $span -ge 1.2 -and $span -le 4.0) { Pass ('typing pace: ' + $final.changes + ' separate characters over ' + [Math]::Round($span, 2) + ' s (about 1.5 s expected at 110 WPM)') }
        else { Fail ('typing pace: ' + $final.changes + ' text changes over ' + [Math]::Round($span, 2) + ' s; expected 15 separate characters over 1.2 s to 4 s at 110 WPM') }
    } else { Fail 'typing pace: the text box never changed while the agent ran' }

    if ($approach.Count -ge 8) { Pass ('pointer glided to the text box: ' + $approach.Count + ' distinct positions sampled on the way (' + $positions.Count + ' over the whole run)') }
    else { Fail ('pointer did not glide: only ' + $approach.Count + ' distinct positions sampled on the way to the text box') }

    if ($failures.Count -eq 0) { $exitCode = 0 }
} catch {
    Fail ('test aborted: ' + $_.Exception.Message)
    if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Encoding UTF8 | ForEach-Object { Write-Host ('  | ' + $_) } }
    if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Encoding UTF8 | ForEach-Object { Write-Host ('  | ' + $_) } }
} finally {
    try { [IO.File]::WriteAllText($stopPath, 'stop') } catch { }
    Start-Sleep -Milliseconds 600
    foreach ($p in @($agentProc, $mockProc, $helperProc)) {
        if ($p) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    }
    try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ''
if ($exitCode -eq 0) { Write-Host ('REAL INPUT TEST PASSED (' + $Shell + ')') -ForegroundColor Green }
else { Write-Host ('REAL INPUT TEST FAILED (' + $Shell + '): ' + ($failures -join '; ')) -ForegroundColor Red }
exit $exitCode
