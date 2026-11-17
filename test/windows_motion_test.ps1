# Unit tests for the pure pointer-path and typing-pace functions in windows/agent.ps1.
# Loads only those functions from the script (via the AST), so the agent itself does not start.
param([string]$AgentPath)
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($AgentPath, [ref]$t, [ref]$e)
$want = @('Get-GlidePath', 'Get-LinePath', 'Get-TypeDelayMs', 'Type-Text')
$ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($want -contains $args[0].Name) }, $false) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:fail = 0
function Ok([bool]$cond, [string]$name) {
    if ($cond) { Write-Host ('ok   ' + $name) } else { Write-Host ('BAD  ' + $name); $script:fail = 1 }
}
function Near([double]$a, [double]$b, [double]$tol) { return ([Math]::Abs($a - $b) -le $tol) }

# Checks every property the spec asks of a glide from A to B.
function Check-Glide([string]$name, [double]$ax, [double]$ay, [double]$bx, [double]$by, [bool]$drag, [double]$wantT, [int]$wantN) {
    $w = 1920; $h = 1080
    $g = Get-GlidePath $ax $ay $bx $by $w $h $drag
    $p = $g.Points
    $dx = $bx - $ax; $dy = $by - $ay; $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
    Ok (Near $g.Seconds $wantT 0.0005) ($name + ': duration ' + $g.Seconds + ' s (want ' + $wantT + ')')
    Ok ($p.Count -eq $wantN) ($name + ': ' + $p.Count + ' steps (want ' + $wantN + ')')
    $first = $p[0]; $last = $p[$p.Count - 1]
    $firstDist = [Math]::Sqrt(($first[0] - $ax) * ($first[0] - $ax) + ($first[1] - $ay) * ($first[1] - $ay))
    Ok ($firstDist -le [Math]::Max(12, 0.12 * $d)) ($name + ': first point is near A (' + [Math]::Round($firstDist, 1) + ' px away)')
    Ok ($last[0] -eq [int]$bx -and $last[1] -eq [int]$by) ($name + ': last point is exactly B')
    $prev = -1e9; $mono = $true; $maxPerp = 0.0; $inside = $true; $side = 0.0
    foreach ($q in $p) {
        $along = (($q[0] - $ax) * $dx + ($q[1] - $ay) * $dy) / $d
        $perp = (($q[0] - $ax) * (-$dy) + ($q[1] - $ay) * $dx) / $d
        if ($along -lt $prev - 1.5) { $mono = $false }
        if ($along -gt $prev) { $prev = $along }
        if ([Math]::Abs($perp) -gt $maxPerp) { $maxPerp = [Math]::Abs($perp); $side = $perp }
        if ($q[0] -lt 0 -or $q[1] -lt 0 -or $q[0] -gt $w - 1 -or $q[1] -gt $h - 1) { $inside = $false }
    }
    Ok $mono ($name + ': progress along A->B never goes backwards')
    Ok ($maxPerp -le 40.8) ($name + ': arc stays within 40 px of the straight line (max ' + [Math]::Round($maxPerp, 1) + ')')
    Ok $inside ($name + ': every point is on the screen')
    return @{ MaxPerp = $maxPerp; Side = $side; Points = $p }
}

$r = Check-Glide '600 px move' 100 100 700 100 $false 0.36 30
Ok ($r.MaxPerp -ge 30 -and $r.Side -gt 0) '600 px move: arcs to the (-dy, dx) side by about 40 px'
$distinct = @{}; foreach ($q in $r.Points) { $distinct[('' + $q[0] + ',' + $q[1])] = 1 }
Ok ($distinct.Count -ge 20) ('600 px move: ' + $distinct.Count + ' distinct positions')
$null = Check-Glide '600 px drag' 100 100 700 100 $true 0.54 45
$null = Check-Glide 'short 10 px move' 500 500 510 500 $false 0.15 12
$null = Check-Glide 'short 10 px drag' 500 500 510 500 $true 0.3 25
$null = Check-Glide 'corner to corner' 0 0 1919 1079 $false 0.6 50
$null = Check-Glide 'corner to corner drag' 0 0 1919 1079 $true 0.9 75
$null = Check-Glide 'diagonal up-left' 1500 900 300 200 $false 0.6 50
$r = Check-Glide 'along the top edge (arc would leave the screen)' 1900 0 5 0 $false 0.6 50
$g = Get-GlidePath 400 400 401 402 1920 1080 $false
Ok ($g.Points.Count -eq 1 -and $g.Points[0][0] -eq 401 -and $g.Points[0][1] -eq 402 -and $g.Seconds -eq 0) 'under 3 px: one direct move'
$g = Get-GlidePath 100 100 5000 100 1920 1080 $false
Ok ($g.Points[$g.Points.Count - 1][0] -eq 1919) 'target beyond the screen is clamped'
$l = Get-LinePath 100 100 220 340 12
Ok ($l.Count -eq 12 -and $l[11][0] -eq 220 -and $l[11][1] -eq 340 -and $l[0][0] -eq 110 -and $l[0][1] -eq 120 -and $l[5][0] -eq 160) 'line path: 12 evenly spaced points ending at B'

# typing pace
Ok (Near (Get-TypeDelayMs '110') 109.0909 0.001) 'WPM 110 -> 109.09 ms per character'
Ok (Near (Get-TypeDelayMs '') 109.0909 0.001) 'WPM unset -> 110'
Ok ((Get-TypeDelayMs '0') -eq 0) 'WPM 0 -> no pause'
Ok (Near (Get-TypeDelayMs '60') 200 0.001) 'WPM 60 -> 200 ms'
Ok (Near (Get-TypeDelayMs ' 220 ') 54.5454 0.001) 'WPM 220 -> 54.5 ms'
Ok (Near (Get-TypeDelayMs 'fast') 109.0909 0.001) 'WPM not a number -> 110'
Ok (Near (Get-TypeDelayMs '-5') 109.0909 0.001) 'WPM negative -> 110'

$script:typed = New-Object System.Collections.Generic.List[string]
$script:corner = $false
$script:cornerAfter = -1
function Plat-TypeChar([string]$ch) { $script:typed.Add($ch); if ($script:typed.Count -eq $script:cornerAfter) { $script:corner = $true } }
function In-StopCorner { return $script:corner }
$STOPPED_ERROR = 'Stopped: the user moved the mouse to the top-left corner to stop.'
$text = 'h' + [char]0xE9 + 'llo w' + [char]0xF6 + 'rld 123'
$S = @{ TypeDelayMs = (Get-TypeDelayMs '110') }
$sw = [Diagnostics.Stopwatch]::StartNew(); Type-Text $text; $sw.Stop()
Ok (($script:typed -join '') -ceq $text -and $script:typed.Count -eq 15) 'Type-Text sends the 15 characters one at a time, in order'
Ok ($sw.Elapsed.TotalSeconds -ge 1.5 -and $sw.Elapsed.TotalSeconds -le 2.2) ('15 characters at 110 WPM took ' + [Math]::Round($sw.Elapsed.TotalSeconds, 2) + ' s (want about 1.64)')
$script:typed.Clear(); $S.TypeDelayMs = 0.0
$sw = [Diagnostics.Stopwatch]::StartNew(); Type-Text ("a`r`nb`tc" + [char]0xD83D + [char]0xDE00); $sw.Stop()
Ok ($script:typed.Count -eq 6 -and $script:typed[1] -eq "`n" -and $script:typed[5].Length -eq 2) 'CR dropped, newline and tab kept, a surrogate pair is sent as one character'
Ok ($sw.Elapsed.TotalSeconds -lt 0.5) 'WPM 0: no pause'
$script:typed.Clear(); $script:cornerAfter = 30; $stopMsg = ''
try { Type-Text ('x' * 80) } catch { $stopMsg = $_.Exception.Message }
Ok ($stopMsg -eq $STOPPED_ERROR -and $script:typed.Count -eq 50) ('pointer in the stop corner after character 30 -> typing stops at the next 25-character check (' + $script:typed.Count + ' sent)')
exit $script:fail
