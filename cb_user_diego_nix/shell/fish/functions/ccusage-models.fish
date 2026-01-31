# Claude Code Usage Stats
function ccusage-models --description 'Display Claude Code token usage per model in current session'
    ccusage session --json -b | jq -r '.sessions[0].modelBreakdowns[] | [.modelName, (.inputTokens | tostring), (.outputTokens | tostring), ((.inputTokens + .outputTokens) | tostring), ("$" + (.cost | round | tostring))] | @csv' | sed 's/"//g' | awk -F',' 'BEGIN {printf "%-30s %15s %15s %15s %15s\n", "MODEL", "INPUT", "OUTPUT", "TOTAL", "COST"; print "---------------------------------------------------------------"} {printf "%-30s %15s %15s %15s %15s\n", $1, sprintf("%\047d", $2), sprintf("%\047d", $3), sprintf("%\047d", $4), $5}'
end
