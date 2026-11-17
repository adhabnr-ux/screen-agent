# Screen Agent launcher for Windows.
#   irm https://raw.githubusercontent.com/adhabnr-ux/screen-agent/main/windows/run.ps1 | iex
# Opens Screen Agent in a new PowerShell window. Installs nothing.

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$saBase = $env:SCREEN_AGENT_REPO_RAW
if ([string]::IsNullOrWhiteSpace($saBase)) { $saBase = 'https://raw.githubusercontent.com/adhabnr-ux/screen-agent/main' }
$saBase = $saBase.Trim().TrimEnd('/')
$saUrl = $saBase + '/windows/agent.ps1'

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host 'Screen Agent cannot run here: this computer''s policy puts PowerShell in restricted mode.' -ForegroundColor Red
    return
}

# The new window's command uses only single quotes, so it survives Windows command-line parsing.
$saCmd = "try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor 3072}catch{}; " +
         "`$ProgressPreference='SilentlyContinue'; " +
         "try{ & ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing -Uri '$saUrl'))) } " +
         "catch{ Write-Host ('Screen Agent could not start: ' + `$_.Exception.Message) -ForegroundColor Red }"
$saArgs = '-NoExit -NoProfile -Command "' + $saCmd + '"'
if ($env:SCREEN_AGENT_LAUNCH_PRINT -eq '1') { Write-Output $saCmd; return }   # used by the tests

$saOpened = $false
foreach ($saExe in @('powershell.exe', 'pwsh.exe')) {
    try {
        Start-Process -FilePath $saExe -ArgumentList $saArgs -ErrorAction Stop | Out-Null
        $saOpened = $true
        break
    } catch { }
}

if ($saOpened) {
    Write-Host 'Screen Agent opened in a new window.' -ForegroundColor Cyan
} else {
    Write-Host 'Could not open a new window; starting Screen Agent here.' -ForegroundColor Yellow
    & ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing -Uri $saUrl)))
}
