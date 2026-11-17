# Test stub for windows/agent.ps1: replaces the Win32 screen/input layer with fakes.
# Dot-sourced by the agent when SCREEN_AGENT_TEST_STUB points here.
#   SCREEN_AGENT_STUB_JPEG   path of the JPEG returned for every capture
#   SCREEN_AGENT_STUB_LOG    file that gets one line per platform call
#   SCREEN_AGENT_STUB_CURSOR "x,y" cursor position (default 500,500)

function Stub-Log([string]$line) {
    if ($env:SCREEN_AGENT_STUB_LOG) { Add-Content -LiteralPath $env:SCREEN_AGENT_STUB_LOG -Value $line }
}
function Plat-Init { Stub-Log 'init 1920x1080'; return @(1920, 1080) }
function Plat-Capture([int]$x, [int]$y, [int]$w, [int]$h, [int]$ow, [int]$oh) {
    Stub-Log ("capture $x,$y ${w}x$h -> ${ow}x$oh")
    return [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:SCREEN_AGENT_STUB_JPEG))
}
function Plat-GetCursor {
    $c = $env:SCREEN_AGENT_STUB_CURSOR
    if (-not $c) { $c = '500,500' }
    $p = $c.Split(',')
    return @([int]$p[0], [int]$p[1])
}
function Plat-SetCursor([int]$x, [int]$y) { Stub-Log "move $x,$y" }
function Plat-Mouse([uint32]$flags, [int]$data) { Stub-Log ('mouse 0x{0:x} {1}' -f $flags, $data) }
function Plat-Key([int]$vk, [bool]$up) { Stub-Log ('key 0x{0:x2} {1}' -f $vk, $(if ($up) { 'up' } else { 'down' })) }
function Plat-TypeText([string]$text) { Stub-Log ('type ' + $text.Replace("`n", '\n')) }
function Plat-VkForChar([char]$c) {
    $us = @{ '-' = 0xBD; '=' = 0xBB; ',' = 0xBC; '.' = 0xBE; '/' = 0xBF; ';' = 0xBA; "'" = 0xDE; '[' = 0xDB; ']' = 0xDD; '\' = 0xDC; '`' = 0xC0; ' ' = 0x20
             '+' = 0x1BB; '?' = 0x1BF; '!' = 0x131; '@' = 0x132; '#' = 0x133; '$' = 0x134; '%' = 0x135 }
    $k = [string]$c
    if ($us.ContainsKey($k)) { return $us[$k] }
    return -1
}
