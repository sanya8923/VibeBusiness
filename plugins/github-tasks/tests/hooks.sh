#!/bin/bash
# Проверка хука запретов guard-git.sh без Claude Code: подаём ему JSON, как это делает
# Claude Code, и смотрим код выхода (2 — заблокировано, 0 — пропущено).
# Запуск: GT_TEST_DIR=<папка> /bin/bash tests/hooks.sh
#   <папка>/sandbox — клон репозитория с .claude/github-tasks.json, на основной ветке,
#   с рабочей копией .claude/worktrees/hooktest на ветке hooktest;
#   <папка>/noconf — любой git-репозиторий без файла настроек.
set -u
S=${GT_TEST_DIR:?укажи GT_TEST_DIR}
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
SB=$S/sandbox
WT=$SB/.claude/worktrees/hooktest
NC=$S/noconf
pass=0; fail=0

run() {  # ожидание(block|allow) каталог команда
  local want=$1 dir=$2 cmd=$3 json code got
  json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$dir" "$cmd")
  printf '%s' "$json" | /bin/bash "$H/guard-git.sh" >/dev/null 2>&1; code=$?
  got=allow; [ $code = 2 ] && got=block
  if [ "$got" = "$want" ]; then pass=$((pass+1)); r=ok; else fail=$((fail+1)); r=ОШИБКА; fi
  printf '%-6s %-5s %s\n' "$r" "$want" "$cmd"
}

echo "== должны блокироваться (репозиторий с файлом настроек)"
run block "$WT" 'git add -A'
run block "$WT" 'git add .'
run block "$WT" 'git add --all'
run block "$WT" 'git add -u'
run block "$WT" 'git commit -am "правка"'
run block "$WT" 'git commit -a -m "правка"'
run block "$SB" 'git commit -m "прямо в основную ветку"'
run block "$WT" 'git push --force'
run block "$WT" 'git push -f origin hooktest'
run block "$WT" 'git push --force-with-lease origin hooktest'
run block "$WT" 'git push origin +hooktest'
run block "$NC" "cd $WT && git add -A"
run block "$NC" "git -C $WT push --force"
run block "$NC" "git -C $SB commit -m x"
run block "$WT" 'echo готово; git add -A'
run block "$WT" 'git status && git push -f'

echo "== должны проходить"
run allow "$WT" 'git add plugins/a.txt docs/b.md'
run allow "$WT" 'git commit -m "запрет git add -A и git push --force в тексте"'
run allow "$WT" "git commit -F - <<'EOF'
git add -A и git push --force упомянуты в теле
EOF"
run allow "$WT" 'git push -u origin hooktest'
run allow "$WT" 'git status --short'
run allow "$WT" 'echo "git add -A"'
run allow "$SB" 'git pull --ff-only'
run allow "$NC" 'git add -A'
run allow "$NC" 'git push --force'
run allow "$NC" 'ls -la'

echo "итог: верно $pass, ошибок $fail"
[ $fail = 0 ]
