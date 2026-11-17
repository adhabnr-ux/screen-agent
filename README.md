# Screen Agent

Claude sees your screen and uses the mouse and keyboard to do what you ask, like the Claude
browser extension but for the whole computer. You run one command in a terminal. Nothing is
installed: it downloads small text files into `~/.screen-agent` and runs them with tools the
OS already includes (PowerShell on Windows, the built-in JavaScript automation on macOS,
Python 3 on Linux).

## Start it

**Windows** (open PowerShell):

```powershell
irm https://raw.githubusercontent.com/adhabnr-ux/screen-agent/main/windows/run.ps1 | iex
```

**macOS or Linux** (open Terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/adhabnr-ux/screen-agent/main/run.sh | bash
```

A new terminal window opens. That window is the agent. The first time, it asks for an
Anthropic API key, which you create at [console.anthropic.com](https://console.anthropic.com) →
API Keys. The key is saved only on that computer: in `~/.screen-agent/key` (readable only by you)
on macOS and Linux, and encrypted with your Windows login in `%APPDATA%\screen-agent\key.dat`
on Windows. Usage is billed to whoever's key it is.

If your key belongs to an organization and isn't tied to one workspace, the agent lists the
workspaces it can use and asks which one to bill. If it can't list them, it asks you to paste the
workspace ID (starts with `wrkspc_`) from
[platform.claude.com/settings/workspaces](https://platform.claude.com/settings/workspaces). The
choice is saved next to the key. `/key` forgets both. You can also set `ANTHROPIC_WORKSPACE_ID`.

Then type what you want, for example:

> Open a browser, go to wikipedia.org and find the population of Tucson.

## Stop it

- Move the mouse into the **top-left corner** of the screen. Claude stops before its next action.
- Or press **Ctrl+C** in the agent window.

Commands in the agent window: `/new` (fresh conversation), `/key` (enter a different key),
`/quit`, `/help`.

## What Claude will and won't do

Claude asks you before anything hard to undo or that other people will see: sending
messages, posting, buying, submitting forms, deleting files, or changing settings. It won't type
passwords or card numbers (you type those yourself), and it ignores instructions written on web
pages or in documents. It doesn't try to get around security software, admin restrictions,
filters or CAPTCHAs.

## Per-computer requirements

| | What's needed | When it won't work |
|---|---|---|
| **Windows** 10/11 | PowerShell (built in) | A device policy that puts PowerShell in Constrained Language Mode (common on locked-down school or work PCs). The agent detects this and says so. |
| **macOS** 10.15+ | One-time permission: System Settings → Privacy & Security → **Accessibility** and **Screen & System Audio Recording** → turn on Terminal. The agent opens these pages for you. | On a managed Mac where only an administrator can change those settings. |
| **Linux** | Python 3 and an X11 desktop session (most distros ship both) | Wayland sessions block synthetic input: choose "Xorg"/"X11" at the login screen. |
| **Chromebook** | – | No terminal, so it can't run. |

Only the main display is used. The screenshots sent to Claude are scaled to fit 1280×800.

## Options

Environment variables. Set them first (`export NAME=value` on macOS/Linux, `$env:NAME='value'` in
PowerShell), then run the command:

| Variable | Default | |
|---|---|---|
| `ANTHROPIC_API_KEY` | – | Use this key instead of asking; it isn't saved. On macOS/Linux this needs `--here` (below), because a new window doesn't receive it. |
| `SCREEN_AGENT_MODEL` | `claude-opus-5-5` | Any Claude model with computer use. |
| `SCREEN_AGENT_EFFORT` | `medium` | `low`, `medium`, `high`, `xhigh`, `max`: higher is more careful and costs more. |
| `SCREEN_AGENT_DRY_RUN` | – | `1` = take screenshots but don't click or type (for testing). |

To run in the current window instead of a new one: `curl -fsSL …/run.sh | bash -s -- --here`.

## How it works

Each turn, the agent sends the conversation and screenshots to the
[Claude Messages API](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)
with the computer-use toolset. Claude replies with actions (`left_click`, `type`, `key`,
`scroll`, `zoom`, …). The agent performs them with the OS's own input APIs (`SendInput` on
Windows, `CGEvent` on macOS, XTest on Linux), takes a new screenshot when asked, and sends the
results back. That repeats until the task is done.

| File | What it is |
|---|---|
| `windows/run.ps1`, `windows/agent.ps1` | Windows launcher and agent (PowerShell 5.1+) |
| `run.sh` | macOS/Linux launcher |
| `mac/start.sh`, `mac/agent.js` | macOS key setup and agent (JavaScript for Automation) |
| `linux/agent.py` | Linux agent (Python 3 standard library) |
| `SPEC.md` | The behavior all three agents implement |
| `test/mock_api.py` | Offline mock of the API that checks every request |

## Testing without a key

```bash
python3 test/mock_api.py --port 8765 &
export SCREEN_AGENT_BASE_URL=http://127.0.0.1:8765 ANTHROPIC_API_KEY=sk-test-good
export SCREEN_AGENT_DRY_RUN=1 SCREEN_AGENT_TASK=test
curl -fsSL https://raw.githubusercontent.com/adhabnr-ux/screen-agent/main/run.sh | bash -s -- --here
cat mock_report.json   # "errors": [] means every request matched the API's rules
```
