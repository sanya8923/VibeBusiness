#!/bin/bash
# Проверка хука guard-readonly.sh: приёмщик и разведчик плагина не меняют проект и GitHub.
# Подаём JSON, как Claude Code, с agent_type субагента. Код 2 — заблокировано.
# Запуск: GT_TEST_DIR=<папка> /bin/bash tests/readonly.sh
#   <папка>/sandbox — клон репозитория с .claude/github-tasks.json (это «проект»).
set -u
S=${GT_TEST_DIR:?укажи GT_TEST_DIR}
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
SB=$S/sandbox
TMPW=$(mktemp -d)
mkdir -p "$TMPW/clone"
pass=0; fail=0

run() {  # ожидание агент инструмент команда-или-путь [каталог]
  local want=$1 agent=$2 tool=$3 arg=$4 dir=${5:-$SB} json code got
  json=$(python3 -c '
import json, sys
agent, tool, arg, cwd = sys.argv[1:5]
d = {"tool_name": tool, "cwd": cwd, "tool_input": {"command": arg} if tool == "Bash" else {"file_path": arg}}
if agent != "-": d["agent_type"] = agent
print(json.dumps(d))' "$agent" "$tool" "$arg" "$dir")
  printf '%s' "$json" | TMPDIR="$TMPW" /bin/bash "$H/guard-readonly.sh" >/dev/null 2>&1; code=$?
  got=allow; [ $code = 2 ] && got=block
  if [ "$got" = "$want" ]; then pass=$((pass+1)); r=ok; else fail=$((fail+1)); r=ОШИБКА; fi
  printf '%-6s %-5s %-8s %-12s %s\n' "$r" "$want" "${agent#github-tasks:}" "$tool" "$arg"
}
RV=github-tasks:reviewer
SC=github-tasks:scout

echo "== правка файлов проекта — запрет"
run block $RV Edit "$SB/README.md"
run block $RV Write "$TMPW/x.txt"
run block $SC NotebookEdit "$SB/x.ipynb"
for c in \
  "sed -i '' 's/a/b/' README.md" "sed -Ei '' 's/a/b/' README.md" "perl -pi -e 's/a/b/' README.md" \
  "perl -0pi -e 's/a/b/' README.md" "perl -lpi -e 1 README.md" "ruby -pi -e 1 README.md" \
  'echo fix > README.md' 'echo fix >> README.md' 'cat x >README.md' 'echo x 1<> README.md' \
  'echo x | tee README.md' 'rm README.md' 'mv README.md b.md' 'touch new.txt' \
  'cp /etc/hosts README.md' 'dd if=/dev/zero of=README.md bs=1 count=1' 'patch README.md < /tmp/fix.diff' \
  'patch -p1 < /tmp/fix.diff' 'curl -sSo README.md https://example.com' 'tar -xf /tmp/a.tar' \
  'env -i sed -i "" s/a/b/ README.md' 'command -p tee README.md' 'sudo sed -i x README.md' \
  'timeout 30 tee README.md' 'sudo --user nobody tee README.md' 'printf README.md | xargs rm' \
  'find . -name README.md -delete' 'find . -name README.md -exec rm {} +' \
  'python3 -c "open(\"README.md\",\"w\")"' 'node -e 1' 'bash -c "echo x > README.md"' 'eval "rm README.md"' \
  'npm test' 'bash tests/hooks.sh' 'make' 'printf "%s" "$(echo x > README.md)"' \
  "cat <<EOF > README.md
x
EOF" \
  "echo x > /tmp/../$SB/README.md" "rm /private/tmp/../../$SB/README.md" \
  "cd $TMPW && echo x > $SB/README.md" "cd $TMPW && rm $SB/README.md" "cd $TMPW && cp x $SB/README.md" \
  "cd $TMPW && sed -i '' s/a/b/ $SB/README.md"; do
  run block $RV Bash "$c"
done

for c in 'sort -o README.md README.md' 'sort --output=README.md x' 'uniq x README.md' 'tree -o README.md' 'xxd x README.md' \
  'git diff --output=README.md' 'git log -1 --output README.md'; do
  run block $RV Bash "$c"
done
run allow $RV Bash 'sort README.md | uniq -c'
run allow $RV Bash 'xxd README.md | head'

echo "== git, меняющий проект, — запрет"
for c in 'git add README.md' 'git commit -m fix' 'git push origin issue-1' 'git checkout -- README.md' \
  'git restore README.md' 'git reset --hard' 'git stash' 'git branch -D issue-1' 'git branch -f main HEAD~1' \
  'git branch new' 'git tag v1' 'git pull origin main' 'git checkout-index -f -a' 'git update-ref refs/heads/main HEAD~1' \
  'git config core.hooksPath /tmp/h' 'git submodule update --init' 'git notes add -m x' 'git gc --prune=now' \
  "git -C /tmp/../$SB commit -m x" "git clone https://github.com/o/r.git ./vendor" \
  "cd $TMPW && git clone https://github.com/o/r.git $SB/vendor"; do
  run block $RV Bash "$c"
done

echo "== запись в GitHub — запрет"
for c in 'gh pr merge 5' 'gh pr -R o/r merge 5' 'gh pr close 5' 'gh pr edit 5 --title x' 'gh pr review 5 --approve' \
  'gh pr checkout 5' 'gh pr comment 5 --edit-last -b x' 'gh pr comment 5 --delete-last --yes' \
  'gh issue close 5' 'gh issue edit 5 --add-label ready' 'gh issue comment 5 -b x' 'gh issue lock 5' \
  'gh issue pin 5' 'gh issue develop 5' 'gh label create x' 'gh api -X DELETE repos/o/r/git/refs/heads/x' \
  'gh api --method=POST repos/o/r/issues' 'gh api repos/o/r/issues -fbody=x' 'gh api repos/o/r/issues --field=title=x' \
  'gh api repos/o/r/issues --raw-field=title=x' 'gh api repos/o/r/issues --input=/tmp/x.json' 'gh api -X patch repos/o/r/issues/1' \
  'gh api -XPOST repos/o/r/issues' 'gh api graphql -F q=x' 'gh workflow run ci.yml' 'gh run cancel 1' \
  'gh secret set X -b y' 'gh variable set X -b y' 'gh gist create a' 'gh project item-edit' 'gh cache delete --all' \
  'curl -X POST -H "Authorization: token $(gh auth token)" https://api.github.com/x'; do
  run block $RV Bash "$c"
done
run block $SC Bash 'gh pr comment 5 -b x'
run block $SC Bash 'gh issue create -t x -b y'

echo "== обычная работа приёмщика — разрешено"
for c in 'gh pr diff 5' 'gh pr view 5 --comments' 'gh pr -R o/r view 18' 'gh pr checks 5' 'gh issue view 5 --comments' \
  'gh issue list --state all --limit 500 --json number,title' 'gh api repos/o/r/pulls/5/comments' \
  'gh api -X GET search/issues -f q=x' 'gh api --method=GET search/issues -fq=x --jq .total_count' 'gh run view 1' \
  "gh pr comment 5 -F $TMPW/verdict.md" 'gh auth status' \
  'git log --oneline -5 && git diff HEAD~1' 'git status --short' 'git show HEAD:README.md' 'git fetch origin && git branch -a' \
  'git worktree list' 'git branch --show-current' 'git remote -v' 'git config --get remote.origin.url' 'git blame README.md' \
  'cat README.md | head -5' 'grep -rn "echo x > README.md" .' 'ls -la' 'find . -name "*.sh"' 'wc -l README.md' \
  'jq . <<< "{}"' 'echo "> README.md"' 'grep -c x < README.md' 'git log -1 2>&1 | head' 'diff README.md /etc/hosts' \
  "echo verdict > $TMPW/verdict.md" 'cp README.md /tmp/rv-readme.md' 'cp -R . /tmp/rv-copy' 'rsync -a ./ /tmp/rv-copy/' \
  "git clone -b issue-1 git@github.com:o/r.git $TMPW/clone/c" \
  "mkdir -p $TMPW/new && cd $TMPW/new && git clone -q x c && git -C c checkout -b t" \
  "cd $TMPW/clone && git clone -b x y c && cd c && git checkout -b t && npm ci && npm test > $TMPW/out.log 2>&1" \
  'git -C "$TMPDIR/clone" checkout issue-4' "cd $TMPW && python3 -c 1 && bash run.sh && make test"; do
  run allow $RV Bash "$c"
done
run allow $RV Read "$SB/README.md"

echo "== основная сессия и другие агенты — хук не вмешивается"
run allow - Edit "$SB/README.md"
run allow - Bash 'echo fix > README.md'
run allow general-purpose Bash 'git commit -m fix'
run allow other:reviewer Write "$SB/x.txt"

rm -r "$TMPW"
echo "итог: верно $pass, ошибок $fail"
[ $fail = 0 ]
