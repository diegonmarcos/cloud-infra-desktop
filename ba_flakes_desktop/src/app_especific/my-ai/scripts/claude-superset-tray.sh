#!/usr/bin/env bash
set -u
DASH="@dashboard@"
ROOT="${DASH%/dashboard}"
refresh() {
  while true; do
    saved=$(curl -fsS --max-time 2 "$ROOT/stats" 2>/dev/null \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(Number(j.tokens_saved||0).toLocaleString()+" tok ("+((j.lifetime_ratio||0)*100).toFixed(0)+"%)")}catch{process.stdout.write("offline")}})' 2>/dev/null || echo "offline")
    printf 'tooltip:claude-superset — %s saved\n' "$saved"
    sleep 30
  done
}
refresh | yad --notification --listen \
  --image=utilities-terminal --text="claude-superset" \
  --menu="Dashboard!xdg-open $DASH|Status!konsole -e claude-superset --help|Quit!quit"
