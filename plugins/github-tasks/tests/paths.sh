#!/bin/bash
# Проверка поля paths (монорепозиторий): запреты коммита и push в основную ветку
# действуют, только если затрагивают папки процесса; force push и git add -A — всегда.
# Хуки guard-git.sh и unpushed.sh получают JSON, как от Claude Code. Песочница —
# локальный репозиторий с локальным «origin» (bare), в GitHub ничего не отправляется.
# Запуск: /bin/bash tests/paths.sh  (папку песочницы можно задать: GT_TEST_DIR=<папка>)
set -u
S=${GT_TEST_DIR:-$(mktemp -d)}
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
P=$S/paths
R=$P/repo
F=$R/.claude/worktrees/feature
pass=0; fail=0
g() { git -c user.name=test -c user.email=test@example.com "$@"; }

rm -rf "$P"; mkdir -p "$P"
git init -q --bare "$P/origin.git"
git -C "$P/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$P/origin.git" "$R" 2>/dev/null
cd "$R" || exit 1
g checkout -q -b main 2>/dev/null
mkdir -p .claude svc lib/core docs
echo '{"paths": ["svc/", "lib/core"]}' > .claude/github-tasks.json
for f in svc/a.txt lib/core/x.py lib/other.txt lib/core-old.txt docs/a.md docs/b.md; do echo v0 > "$f"; done
echo ".claude/worktrees/" > .gitignore
g add .gitignore .claude/github-tasks.json svc lib docs && g commit -q -m init && g push -q origin main
git remote set-head origin main
g worktree add -q -b feature "$F" origin/main 2>/dev/null

cfg() { printf '%s\n' "$1" > "$R/.claude/github-tasks.json"; }
reset_main() { g -C "$R" reset -q --hard origin/main; g -C "$F" reset -q --hard origin/main; }
edit() { for f in "$@"; do echo "$RANDOM" >> "$R/$f"; done; }

run() {  # ожидание(block|allow) каталог команда
  local want=$1 dir=$2 cmd=$3 json code got r
  json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$dir" "$cmd")
  printf '%s' "$json" | /bin/bash "$H/guard-git.sh" >/dev/null 2>&1; code=$?
  got=allow; [ $code = 2 ] && got=block
  if [ "$got" = "$want" ]; then pass=$((pass+1)); r=ok; else fail=$((fail+1)); r=ОШИБКА; fi
  printf '%-6s %-5s %s\n' "$r" "$want" "$cmd"
}
check() {  # описание условие...
  local d=$1; shift
  if "$@"; then pass=$((pass+1)); echo "ok           $d"; else fail=$((fail+1)); echo "ОШИБКА       $d"; fi
}

echo "== paths пуст или не задан — запрет на весь репозиторий, как раньше"
edit docs/a.md
for c in '{"paths": []}' '{}' '{"paths": ["."]}' '{"paths": ["./"]}' '{"paths": [1]}' '{"paths": ["svc", "../x"]}' '{"paths": '; do
  cfg "$c"
  run block "$R" 'git add docs/a.md && git commit -m x'
done
cfg '{"paths": []}'
run block "$R" 'git push origin main'
run block "$R" 'git push'
run allow "$F" 'git add docs/a.md && git commit -m x'
reset_main

cfg '{"paths": ["svc/", "./lib/core/"]}'
echo "== paths задан: коммит в main"
edit docs/a.md svc/a.txt lib/core/x.py lib/other.txt lib/core-old.txt
run allow "$R" 'git add docs/a.md && git commit -m "вне папок процесса"'
run allow "$R" 'git add lib/other.txt lib/core-old.txt && git commit -m x'
run allow "$R/docs" 'git add a.md && git commit -m x'
run allow "$R" 'git -C docs add a.md && git -C docs commit -m x'
run block "$R" 'git add svc/a.txt && git commit -m x'
run block "$R" 'git add lib/core/x.py && git commit -m x'
run block "$R/lib" 'git add core/x.py && git commit -m x'
run block "$R" 'git add docs/a.md svc/a.txt && git commit -m "смешанный"'
run block "$R" 'git add docs/a.md; git add svc/a.txt; git commit -m x'
run block "$R" 'git add lib && git commit -m x'
run block "$R" "git add 'svc/*.txt' && git commit -m x"
run block "$R" "git add 'l*' && git commit -m x"
run block "$R" 'git add "$X" && git commit -m x'
run block "$R" 'git add ":(top)svc" && git commit -m x'
run block "$R" 'git rm --cached svc/a.txt && git commit -m x'
run block "$R" 'git mv docs/b.md svc/b.md && git commit -m x'
run block "$R" 'git commit svc/a.txt -m x'
run block "$R" 'git commit -m x -- lib/core/x.py'
run block "$R" 'git commit -p -m x'
run block "$R" 'git commit --pathspec-from-file=list.txt -m x'
run block "$R" 'git add -p && git commit -m x'
run block "$R" 'ls | xargs git add && git commit -m x'
run block "$R" 'git stash pop && git commit -m x'
run block "$R" 'git checkout HEAD -- svc/a.txt && git commit -m x'
run block "$R" 'GIT_INDEX_FILE=/tmp/idx git commit -m x'
run allow "$R" 'git commit --allow-empty -m x'
run allow "$R" 'git add svc/a.txt && git commit -m x docs/a.md'
run block "$R" 'git add svc/a.txt && git commit -m x && git switch feature'
echo "-- уже проиндексировано до команды"
g -C "$R" add svc/a.txt
run block "$R" 'git commit -m x'
run allow "$R" 'git commit -m x docs/a.md'
run block "$R" 'git commit -i -m x docs/a.md'
g -C "$R" reset -q
g -C "$R" add docs/a.md
run allow "$R" 'git commit -m x'
g -C "$R" add lib/core/x.py
run block "$R" 'git commit -m "смешанный"'
g -C "$R" reset -q
echo "-- --amend: файлы последнего коммита тоже входят"
run block "$R" 'git commit --amend -m x'   # init трогает svc/
g -C "$R" commit -q -m docs docs/a.md
run allow "$R" 'git commit --amend -m x'
run allow "$R" 'git add docs/b.md && git commit --amend -m x'
run block "$R" 'git add svc/a.txt && git commit --amend -m x'
reset_main
echo "-- всегда, независимо от paths"
edit docs/a.md
run block "$R" 'git add -A'
run block "$R" 'git add .'
run block "$R" 'git add -u'
run block "$R" 'git commit -am x'
run block "$R" 'git commit -a -m x docs/a.md'
run allow "$F" 'git add svc/a.txt && git commit -m x'
run block "$F" 'git switch main && git add svc/a.txt && git commit -m x'

echo "== paths задан: push в main"
run allow "$R" 'git push origin main'   # отправлять нечего
g -C "$R" commit -q -m docs docs/a.md
run allow "$R" 'git push origin main'
run allow "$R" 'git push'
run allow "$R" 'git push origin'
run allow "$R" 'git push origin HEAD'
run allow "$R" 'git push origin main:main'
run allow "$R" 'git push origin refs/heads/main:refs/heads/main'
run allow "$F" 'git push origin main'
run allow "$R" 'git add docs/b.md && git commit -m y && git push'
run allow "$R" 'git pull --rebase && git push'
run allow "$R" 'git push -u origin main'
echo "-- force и удаление — всегда"
run block "$R" 'git push --force origin main'
run block "$R" 'git push -f'
run block "$R" 'git push --force-with-lease'
run block "$R" 'git push origin +main'
run block "$F" 'git push -f origin feature'
run block "$R" 'git push origin :main'
run block "$R" 'git push origin --delete main'
run block "$R" 'git push -d origin main'
echo "-- диапазон не вычислить — запрет"
run block "$R" 'git push https://example.com/r.git main'
run block "$R" 'git merge feature && git push origin main'
run block "$R" 'git reset HEAD~1 && git push'
run block "$F" 'git commit -m z && git push origin feature:main'
run block "$R" 'ls | xargs git push origin'
echo "-- отправляемые коммиты трогают папки процесса"
edit svc/a.txt
g -C "$R" commit -q -m svc svc/a.txt
run block "$R" 'git push origin main'
run block "$R" 'git push'
run block "$R" 'git push origin HEAD:main'
run block "$F" 'git push origin main'
reset_main
echo v1 >> "$F/svc/a.txt"; g -C "$F" commit -q -m svc svc/a.txt
run block "$F" 'git push origin HEAD:main'
run block "$F" 'git push origin feature:main'
run allow "$F" 'git push -u origin feature'
reset_main

echo "== регистр путей (приёмка #36)"
cfg '{"paths": ["svc/", "lib/core"]}'
if [ -d "$R/SVC" ] && [ "$(git -C "$R" config --bool core.ignorecase)" = true ]; then
  echo "-- файловая система не различает регистр: путь в другом регистре — та же папка"
  run block "$R" 'cd SVC && git add a.txt && git commit -q -m x'
  run block "$R" 'cd Svc && git add a.txt && cd .. && git commit -m x'
  run block "$R" 'git add Svc/NEW.txt && git commit -q -m x'
  run block "$R" 'git -C SVC add a.txt && git commit -q -m x'
  run block "$R" 'cd Svc && git commit -q -m x a.txt'
  run block "$R" 'git add LIB/Core/x.py && git commit -m x'
  run block "$R" 'git add lib/core/X.PY && git commit -m x'
  run allow "$R" 'cd DOCS && git add a.md && git commit -m x'
  run allow "$R" 'git add LIB/other.txt && git commit -m x'
  cfg '{"paths": ["SVC", "Lib/Core/"]}'
  run block "$R" 'git add svc/a.txt && git commit -m x'
  run block "$R" 'git add lib/core/x.py && git commit -m x'
  edit svc/a.txt; g -C "$R" add svc/a.txt
  run block "$R" 'git commit -m x'
  g -C "$R" commit -q -m svc svc/a.txt
  run block "$R" 'git push origin main'
  reset_main
  cfg '{"paths": ["svc/", "lib/core"]}'
else
  echo "-- пропущено: файловая система различает регистр"
fi
echo "-- особый разбор путей (--icase-pathspecs, --glob-pathspecs) — состав не вычислить"
run block "$R" 'git --icase-pathspecs add SVC/a.txt && git commit -q -m x'
run block "$R" 'GIT_ICASE_PATHSPECS=1 git add SVC/a.txt && git commit -q -m x'
run block "$R" 'export GIT_ICASE_PATHSPECS=1; git add SVC/a.txt && git commit -q -m x'
run block "$R" 'GIT_ICASE_PATHSPECS=1 git commit -q -m x SVC/a.txt'
run block "$R" 'git --glob-pathspecs add docs/a.md && git commit -m x'
run block "$R" 'GIT_GLOB_PATHSPECS=1 git commit -m x'
run block "$R" 'export GIT_GLOB_PATHSPECS=1 && git add docs/a.md && git commit -m x'
run block "$R" 'GIT_ICASE_PATHSPECS=1 git push origin main'
run allow "$R" 'git add docs/a.md && git commit -m x'

echo "-- файл настроек в paths (рекомендация PROCESS.md)"
run allow "$R" 'git add .claude/github-tasks.json && git commit -m x'
cfg '{"paths": [".claude/github-tasks.json", "svc/"]}'
run block "$R" 'git add .claude/github-tasks.json && git commit -m x'
run allow "$R" 'git add docs/a.md && git commit -m x'

echo "== base_branch: та же логика для неё"
g -C "$R" branch -q dev origin/main 2>/dev/null; g -C "$R" push -q origin dev
cfg '{"base_branch": "dev", "paths": ["svc"]}'
run allow "$F" 'git push origin HEAD:dev'   # отправлять нечего
echo v2 >> "$F/svc/a.txt"; g -C "$F" commit -q -m svc svc/a.txt
run block "$F" 'git push origin HEAD:dev'
run block "$F" 'git push origin HEAD:main'
reset_main
echo v3 >> "$F/docs/a.md"; g -C "$F" commit -q -m docs docs/a.md
run allow "$F" 'git push origin HEAD:dev'
reset_main

echo "== unpushed.sh: в основной копии — только незапушенное в папках процесса"
up() { printf '{"cwd": "%s"}' "$R" | /bin/bash "$H/unpushed.sh"; }
edit docs/a.md; g -C "$R" commit -q -m docs docs/a.md
cfg '{"paths": ["svc"]}'
check "paths задан, незапушено только вне папок — про основную копию молчит" eval '! up | grep -q "основная копия"'
cfg '{"paths": []}'
check "paths пуст — про основную копию напоминает" eval 'up | grep -q "основная копия: незапушенных коммитов — 1"'
edit svc/a.txt; g -C "$R" commit -q -m svc svc/a.txt
cfg '{"paths": ["svc"]}'
check "paths задан, незапушенный коммит в папке — напоминает (1 из 2)" eval 'up | grep -q "основная копия: незапушенных коммитов в папках процесса — 1"'
reset_main
g -C "$R" checkout -q -- . 2>/dev/null

echo "итог: верно $pass, ошибок $fail"
[ $fail = 0 ]
