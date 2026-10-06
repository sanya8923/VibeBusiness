#!/bin/bash
# Проверка хука guard-readonly.sh: приёмщик и разведчик плагина не меняют проект.
# Подаём JSON, как Claude Code, с agent_type субагента. Код 2 — заблокировано.
# Запуск: GT_TEST_DIR=<папка> /bin/bash tests/readonly.sh
#   <папка>/sandbox — клон репозитория с .claude/github-tasks.json.
set -u
S=${GT_TEST_DIR:?укажи GT_TEST_DIR}
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
SB=$S/sandbox
TMPW=$(mktemp -d)
pass=0; fail=0

run() {  # ожидание агент инструмент команда-или-путь
  local want=$1 agent=$2 tool=$3 arg=$4 json code got
  json=$(python3 -c '
import json, sys
agent, tool, arg, cwd = sys.argv[1:5]
d = {"tool_name": tool, "cwd": cwd, "tool_input": {"command": arg} if tool == "Bash" else {"file_path": arg}}
if agent != "-": d["agent_type"] = agent
print(json.dumps(d))' "$agent" "$tool" "$arg" "$SB")
  printf '%s' "$json" | /bin/bash "$H/guard-readonly.sh" >/dev/null 2>&1; code=$?
  got=allow; [ $code = 2 ] && got=block
  if [ "$got" = "$want" ]; then pass=$((pass+1)); r=ok; else fail=$((fail+1)); r=ОШИБКА; fi
  printf '%-6s %-5s %-22s %-12s %s\n' "$r" "$want" "$agent" "$tool" "$arg"
}
RV=github-tasks:reviewer
SC=github-tasks:scout

echo "== приёмщик и разведчик: запрет правок"
run block $RV Edit "$SB/README.md"
run block $RV Write "$SB/new.txt"
run block $SC NotebookEdit "$SB/x.ipynb"
run block $RV Bash "sed -i '' 's/a/b/' README.md"
run block $RV Bash "perl -pi -e 's/a/b/' README.md"
run block $RV Bash 'echo fix > README.md'
run block $RV Bash 'echo fix >> README.md'
run block $RV Bash 'cat x >README.md'
run block $RV Bash 'echo x | tee README.md'
run block $RV Bash 'rm README.md'
run block $RV Bash 'mv README.md b.md'
run block $RV Bash 'cp /etc/hosts README.md'
run block $RV Bash 'touch new.txt'
run block $RV Bash 'git add README.md'
run block $RV Bash 'git commit -m fix'
run block $RV Bash 'git push origin issue-1'
run block $RV Bash 'git checkout -- README.md'
run block $RV Bash 'git restore README.md'
run block $RV Bash 'git reset --hard'
run block $RV Bash 'git stash'
run block $RV Bash 'git branch -D issue-1'
run block $RV Bash 'gh pr merge 5'
run block $RV Bash 'gh pr close 5'
run block $RV Bash 'gh issue close 5'
run block $RV Bash 'gh issue edit 5 --add-label ready'
run block $RV Bash 'gh label create x'
run block $RV Bash 'gh api -X DELETE repos/o/r/git/refs/heads/x'
run block $RV Bash 'gh api repos/o/r/issues/5/labels -f labels[]=ready'
run block $SC Bash 'gh issue create -t x -b y'
run block $RV Bash 'sudo sed -i x README.md'
run block $RV Bash 'timeout 30 tee README.md'
run block $RV Bash 'printf "%s" "$(echo x > README.md)"'

run block $RV Bash 'echo x 2>/dev/null >README.md'
run block $RV Bash 'cat a &>README.md'
run block $RV Bash 'sudo --user nobody tee README.md'
run block $RV Bash 'cat <<EOF > README.md
x
EOF'

echo "== приёмщик и разведчик: разрешено"
run allow $RV Bash 'npm test >/dev/null 2>&1'
run allow $RV Bash 'git log -1 2>&1 | head'
run allow $RV Bash 'grep -c x < README.md'
run allow $RV Bash 'echo "> README.md"'
run allow $RV Bash 'jq . <<< "{}"'
run allow $RV Read "$SB/README.md"
run allow $RV Bash 'gh pr diff 5'
run allow $RV Bash 'gh pr view 5 --comments'
run allow $RV Bash "gh pr comment 5 -F $TMPW/verdict.md"
run allow $RV Bash "echo verdict > $TMPW/verdict.md"
run allow $RV Bash "git clone -b issue-1 git@github.com:o/r.git $TMPW/clone"
run allow $RV Bash "cd $TMPW && git -C $TMPW/clone checkout issue-1 && git -C $TMPW/clone log -3"
run allow $RV Bash "git -C $TMPW/clone worktree add $TMPW/clone/wt -b x"
run allow $RV Bash 'npm test 2>&1 | tail -20'
run allow $RV Bash 'bash tests/hooks.sh > /dev/null'
run allow $RV Bash 'git log --oneline -5 && git diff HEAD~1'
run allow $RV Bash 'gh api repos/o/r/pulls/5/comments'
run allow $RV Bash 'grep -rn "echo x > README.md" .'
run allow $SC Bash 'gh issue list --state all --limit 500 --json number,title'
run allow $RV Bash 'git fetch origin && git branch -a'

echo "== основная сессия и другие агенты — хук не вмешивается"
run allow - Edit "$SB/README.md"
run allow - Bash 'echo fix > README.md'
run allow general-purpose Bash 'git commit -m fix'
run allow other:reviewer Write "$SB/x.txt"

rm -r "$TMPW"
echo "итог: верно $pass, ошибок $fail"
[ $fail = 0 ]
