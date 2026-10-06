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
SP="$S/with space"   # ссылка на sandbox с пробелом в пути
[ -e "$SP" ] || ln -s "$SB" "$SP"
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

echo "== обходы, найденные приёмкой (должны блокироваться)"
run block "$NC" "(cd $WT && git add -A)"
run block "$WT" '(git add -A)'
run block "$WT" '{ git add -A; }'
run block "$WT" 'if git add -A; then echo ok; fi'
run block "$WT" 'echo $(git add -A)'
run block "$WT" 'echo `git add -A`'
run block "$WT" 'git push \
  --force origin hooktest'
run block "$WT" 'git add \
  -A'
run block "$WT" 'git commit -m "строка 1
строка 2" && git push --force'
run block "$WT" 'git commit -m "строка 1
строка 2" && git add -A'
run block "$WT" 'git add -vA'
run block "$WT" 'git add -Av'
run block "$WT" 'git add --al'
run block "$WT" 'git add --no-ignore-removal'
run block "$WT" 'git push --force-w origin hooktest'
run block "$WT" 'git push --force-with origin hooktest'
run block "$WT" 'git push --mirr'
run block "$WT" 'git push -uf origin hooktest'
run block "$WT" 'command git add -A'
run block "$WT" 'env git add -A'
run block "$WT" 'env GIT_TRACE=1 git push --force'
run block "$WT" '/usr/bin/git add -A'
run block "$WT" '\git add -A'
run block "$WT" 'git switch main && git commit -m x'
run block "$WT" 'git checkout main; git commit -m x'
run block "$NC" "cd \"$SP/.claude/worktrees/hooktest\" && git add -A"
run block "$NC" "git -C \"$SP\" commit -m x"
run block "$NC" "pushd $WT && git add -A"
run block "$WT" 'git push origin HEAD:main'
run block "$WT" 'git push origin hooktest:main'
run block "$WT" 'git push origin hooktest:refs/heads/main'
run block "$SB" 'git push origin main'
run block "$SB" 'git push origin HEAD'
run block "$WT" 'git add -- .'
run block "$WT" 'git add *'
run block "$WT" 'echo "итог: $(git add -A)"'

echo "== вторая приёмка: метки heredoc, обёртки, checkout файла, push без refspec"
run block "$WT" 'cat <<EOF-1
текст
EOF-1
git add -A'
run block "$WT" 'cat <<END.TXT
текст
END.TXT
git add -A'
run block "$WT" 'timeout 30 git push --force'
run block "$WT" 'nice -n 5 git add -A'
run block "$WT" 'sudo -E git add -A'
run block "$WT" 'env -u FOO git add -A'
run block "$WT" 'time -p git add -A'
run block "$WT" 'xargs -0 git add -A'
run block "$SB" 'git checkout README.md && git commit -m x'
run block "$SB" 'git push'
run block "$SB" 'git push origin'
run block "$WT" 'git checkout main && git merge hooktest && git push'
run block "$WT" 'git push --all origin'

echo "== после третьей приёмки (#16)"
run block "$WT" 'git push origin :'
run block "$WT" "git push origin 'refs/heads/*:refs/heads/*'"
run block "$WT" 'arch -arm64 git add -A'
run block "$SB" 'git checkout hooktest README.md && git commit -m x'
run block "$WT" 'sudo -u nobody git add -A'
run block "$WT" 'nice -n 5 timeout 30 git push -f'
run block "$WT" 'timeout --signal=KILL 30s git add -A'
run block "$WT" 'env -i PATH=/usr/bin git add -A'
run block "$WT" 'xargs -I {} git add -A'

echo "== перенаправления и длинные флаги обёрток (вторая приёмка #16)"
run block "$WT" 'git checkout main 2>&1 && git commit -m x'
run block "$WT" 'git checkout main 2>/dev/null && git commit -m x'
run block "$WT" 'git switch main >/dev/null 2>&1; git commit -m x'
run block "$SB" 'git push origin 2>&1'
run block "$SB" 'git push origin >/dev/null'
run block "$WT" 'timeout --signal KILL 30 git push --force'
run block "$WT" 'sudo --user nobody git add -A'
run block "$WT" 'env --unset FOO git add -A'
run block "$WT" 'stdbuf --output L git push -f'

echo "== перенаправления в разборщике (третья приёмка #16)"
run block "$WT" 'git commit -m "> цитата" -a'
run block "$WT" 'git commit -m "<тип>: описание" -a'
run block "$WT" 'git add ">" .'
run block "$WT" 'git commit -F - <<< "сообщение" -a'
run block "$WT" 'git add "<" -A'
run block "$WT" 'git commit -m ">" -a'
run block "$WT" 'git push origin ">" --force'
run block "$WT" 'jq . <<< "{}"
git push --force'
run block "$WT" 'read x <<< "$y"
git add -A'
run block "$WT" '2>&1 git add -A'
run block "$WT" 'git add -A 2>/dev/null'
run block "$WT" 'git add >/dev/null -A'
run block "$WT" 'git checkout main &>/dev/null && git commit -m x'

echo "== цели перенаправлений (#20)"
run block "$WT" 'echo x > "a\"b" ; git add -A'
run block "$WT" 'cat <<< "размер 5\"" && git push --force'
run block "$WT" 'read a <<< "$(git add -A)"'
run block "$WT" 'cat <<< x"$(git add -A)"'
run block "$WT" 'echo x > "$(git add -A)"'
run block "$WT" 'git commit -m "5">/dev/null -a'

echo "== должны проходить"
run allow "$WT" 'echo x > "a\"b" ; git status'
run allow "$WT" 'git commit -m "5">/dev/null'
run allow "$WT" 'cat <<< "$(git log -1)"'
run allow "$WT" 'git commit -m "> цитата"'
run allow "$WT" 'git commit -F - <<< "-a в тексте"'
run allow "$WT" 'git log --format=">%s<" -3'
run allow "$WT" 'git push -u origin hooktest >/dev/null 2>&1'
run allow "$WT" 'git push -u origin hooktest 2>&1'
run allow "$WT" 'git checkout hooktest 2>&1 && git commit -m x'
run allow "$SB" 'git push origin --tags'
run allow "$WT" 'xargs -n1 echo git push --force'
run allow "$WT" 'timeout 60 grep "git add -A" file.txt'
run allow "$WT" 'git checkout hooktest README.md && git status'
run allow "$WT" 'cat <<\EOF
git push --force
EOF'
run allow "$WT" 'git push'
run allow "$WT" 'git push origin'
run allow "$WT" 'git checkout README.md && git commit -m x'
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
run allow "$WT" 'git commit -m "многострочное
git add -A теперь блокируется"'
run allow "$WT" 'gh pr create --title t --body "текст
git add -A и git push --force в описании"'
run allow "$WT" 'git commit -m "-a в тексте"'
run allow "$SB" 'git switch -c feature && git commit -m x'
run allow "$SB" 'git checkout -b feature2; git commit -m x'
run allow "$WT" 'git push origin HEAD'
run allow "$WT" 'git push -o ci.skip origin hooktest'
run allow "$WT" 'git push origin --follow-tags hooktest'
run allow "$WT" 'git log --format="%H %s" -n 3 | cat'
run allow "$WT" 'echo "\$(git add -A)"'

echo "итог: верно $pass, ошибок $fail"
[ $fail = 0 ]
