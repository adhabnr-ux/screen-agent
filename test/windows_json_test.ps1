# Unit test for the pure-PowerShell JSON span extractor in windows/agent.ps1 (Get-JsonMember).
# Loads only those functions from the script (via the AST), so the agent itself does not start.
param([string]$AgentPath)
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($AgentPath, [ref]$t, [ref]$e)
$ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -like '$JSON_*' }, $false) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
$ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -like '*Json*' }, $false) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$fail = 0
function Check([string]$name, $got, $want) {
    if ($got -ceq $want) { Write-Output ('ok   ' + $name) }
    else { Write-Output ('BAD  ' + $name + "`n  got:  " + $got + "`n  want: " + $want); $script:fail = 1 }
}
$content = '[{"type":"thinking","thinking":"a \"q\" } ] \\","signature":"s/+=="},{"type":"text","text":"brace } and [ bracket \\\" end"},{"type":"tool_use","id":"t1","name":"screenshot","toolset_name":"computer","input":{}},{"type":"tool_use","id":"t2","name":"type","input":{"text":"h\u00e9llo\n{\"k\":[1,2]}"}}]'
$doc = '{"id":"msg_1","type":"message","role":"assistant","model":"m","content":' + $content + ',"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":3}}'
Check 'content span is byte-for-byte' (Get-JsonMember $doc 'content') $content
Check 'string value' (Get-JsonMember $doc 'stop_reason') '"tool_use"'
Check 'null value' (Get-JsonMember $doc 'stop_sequence') 'null'
Check 'object value at the end' (Get-JsonMember $doc 'usage') '{"input_tokens":10,"output_tokens":3}'
Check 'missing key' ([string](Get-JsonMember $doc 'nope')) ''
Check 'nested key is not matched' ([string](Get-JsonMember $doc 'input_tokens')) ''
$pretty = "{`n  `"content`" : [ ],`n  `"stop_reason`" : `"end_turn`"`n}"
Check 'pretty-printed empty array' (Get-JsonMember $pretty 'content') '[ ]'
Check 'pretty-printed string' (Get-JsonMember $pretty 'stop_reason') '"end_turn"'
Check 'content first' (Get-JsonMember '{"content":[{"a":"]"}],"x":1}' 'content') '[{"a":"]"}]'
Check 'number last' (Get-JsonMember '{"content":[],"x":12}' 'x') '12'
# 300 KB of text must stay quick (IndexOfAny, not a per-character loop)
$big = '{"content":[{"type":"text","text":"' + ('ab\"c{}' * 40000) + '"}],"stop_reason":"end_turn"}'
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Get-JsonMember $big 'stop_reason'
$sw.Stop()
Check 'key after a 300 KB value' $r '"end_turn"'
if ($sw.ElapsedMilliseconds -gt 3000) { Write-Output ('BAD  too slow: ' + $sw.ElapsedMilliseconds + ' ms'); $fail = 1 } else { Write-Output ('ok   300 KB scanned in ' + $sw.ElapsedMilliseconds + ' ms') }
exit $fail
