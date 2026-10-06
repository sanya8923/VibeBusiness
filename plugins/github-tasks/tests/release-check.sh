#!/bin/bash
# Проверка scripts/release-check.sh. Создаёт и закрывает задачи и вехи в тестовом
# репозитории — только песочница! Проверка секретов идёт на локальном репозитории с
# локальным «origin» (bare), в GitHub ничего не отправляется.
# Запуск: GT_TEST_DIR=<папка> GT_TEST_REPO=<владелец/репо> /bin/bash tests/release-check.sh
set -u
S=${GT_TEST_DIR:?укажи GT_TEST_DIR}
R=${GT_TEST_REPO:?укажи GT_TEST_REPO}
P="$(cd "$(dirname "$0")/../scripts" && pwd)"
SB=$S/sandbox
pass=0; fail=0
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); echo "ok      $d"; else fail=$((fail+1)); echo "ОШИБКА  $d"; fi; }
has() { grep -qF -- "$1" <<<"$out"; }
last() { tail -1 <<<"$out"; }
ms_num() { gh api "repos/$R/milestones?state=all&per_page=100" -q ".[] | select(.title==\"$1\") | .number"; }

cd "$SB" || exit 1
git checkout -q -- . 2>/dev/null
M="rc-test-$$"; MD="rc-due-$$"; MN="rc-nodue-$$"
gh api "repos/$R/milestones" -f title="$M" -q .number >/dev/null
u1=$(gh issue create -R "$R" -t "Релиз: обычная задача" -b t -m "$M"); n1=${u1##*/}
u2=$(gh issue create -R "$R" -t "Релиз: блокер вне вехи" -b t -l blocked); n2=${u2##*/}
sleep 8

echo "== открытая задача вехи и блокер вне вехи"
out=$(/bin/bash "$P/release-check.sh" "$M" 2>&1); code=$?
check "код 1" test "$code" = 1
check "последняя строка — «Нельзя выкладывать»" grep -q '^Нельзя выкладывать' <<<"$(last)"
check "названа незакрытая задача вехи" has "#$n1"
check "блокер вне вехи найден" has "открытые блокеры: #$n2"

echo "== несуществующая веха"
out=$(/bin/bash "$P/release-check.sh" "Нет такой вехи $$" 2>&1); code=$?
check "код 1" test "$code" = 1
check "веха не найдена" has "веха «Нет такой вехи $$» не найдена"

echo "== без аргумента: веха со сроком важнее вехи без срока"
gh issue close "$n1" -R "$R" >/dev/null; gh issue close "$n2" -R "$R" >/dev/null
gh api "repos/$R/milestones" -f title="$MN" -q .number >/dev/null
gh api "repos/$R/milestones" -f title="$MD" -f due_on="2099-12-31T00:00:00Z" -q .number >/dev/null
u3=$(gh issue create -R "$R" -t "Релиз: задача вехи со сроком" -b t -m "$MD"); n3=${u3##*/}
sleep 8
gh api -X PATCH "repos/$R/milestones/$(ms_num "$M")" -f state=closed >/dev/null
out=$(/bin/bash "$P/release-check.sh" 2>&1); code=$?
check "взята веха со сроком" has "взята ближайшая открытая: «${MD}»"
check "её открытая задача названа" has "#$n3"
check "код 1" test "$code" = 1

echo "== всё закрыто"
gh issue close "$n3" -R "$R" >/dev/null; sleep 8
out=$(/bin/bash "$P/release-check.sh" "$MD" 2>&1); code=$?
check "код 0" test "$code" = 0
check "последняя строка — «Можно выкладывать.»" test "$(last)" = "Можно выкладывать."

echo "== проверка, читающая stdin, не «съедает» следующие"
printf '{\n  "release_checks": [{"name": "читает stdin", "run": "cat >/dev/null"}, {"name": "должна упасть", "run": "echo сломано; exit 3"}, {"name": "проходит", "run": "true"}]\n}\n' > .claude/github-tasks.json
out=$(/bin/bash "$P/release-check.sh" "$MD" 2>&1); code=$?
check "код 1" test "$code" = 1
check "«читает stdin» — пройдена" has "✔ читает stdin"
check "«должна упасть» запущена и не пройдена" has "✘ должна упасть (код 3)"
check "вывод упавшей проверки показан" has "сломано"
check "«проходит» — пройдена" has "✔ проходит"
git checkout -q -- . 2>/dev/null

echo "== сломанный файл настроек — не «можно»"
printf '{\n  "release_checks": [{"name": "тесты", "run": "exit 1"},]\n}\n' > .claude/github-tasks.json
out=$(/bin/bash "$P/release-check.sh" "$MD" 2>&1); code=$?
check "код 1" test "$code" = 1
check "названа ошибка чтения" has "не удалось прочитать release_checks"
printf '{\n  "release_checks": [{"name": "без команды"}]\n}\n' > .claude/github-tasks.json
out=$(/bin/bash "$P/release-check.sh" "$MD" 2>&1); code=$?
check "проверка без run — ошибка" has "без поля run"
git checkout -q -- . 2>/dev/null

echo "== тег на коммите слияния PR — этого PR в списке нет"
read -r prn oid <<<"$(gh pr list -R "$R" --state merged --limit 1 --json number,mergeCommit -q '.[0] | "\(.number) \(.mergeCommit.oid)"')"
TAG="rc-tag-$$"
gh api "repos/$R/git/refs" -f ref="refs/tags/$TAG" -f sha="$oid" >/dev/null
git fetch -q --tags origin 2>/dev/null
out=$(/bin/bash "$P/release-check.sh" "$MD" 2>&1)
check "взят тег $TAG" has "Изменения с $TAG"
check "PR #$prn на теге в список не попал" test -z "$(sed -n '/^Изменения/,$p' <<<"$out" | grep -F "#$prn ")"
gh api -X DELETE "repos/$R/git/refs/tags/$TAG" >/dev/null 2>&1; git tag -d "$TAG" >/dev/null 2>&1

echo "== недоступный репозиторий"
out=$(GT_REPO=sanya8923/no-such-repo-$$ /bin/bash "$P/release-check.sh" 2>&1); code=$?
check "код 1" test "$code" = 1
check "понятная причина" has "не удалось обратиться к репозиторию"

echo "== секреты: короткая история без тега, локальный origin"
T=$(mktemp -d)
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/work" 2>/dev/null
cd "$T/work" && git checkout -q -b main 2>/dev/null
mkdir -p .claude && cp "$SB/.claude/github-tasks.json" .claude/
echo "risk-assessment-framework-for-teams-v2 и mask-image-linear-gradient-x" > code.txt
git add .claude code.txt && git commit -qm "начало" && git push -q origin main 2>/dev/null
out=$(GT_REPO=$R /bin/bash "$P/release-check.sh" "$MD" 2>&1)
check "обычные имена через дефис — не ключи" has "✔ похожих на ключи строк нет"
key="AKIA""IOSFODNN7""EXAMPLE"
echo "aws_key = $key" > keys.txt
git add keys.txt && git commit -qm "ключ" && git push -q origin main 2>/dev/null
out=$(GT_REPO=$R /bin/bash "$P/release-check.sh" "$MD" 2>&1); code=$?
check "ключ найден при истории из 2 коммитов" has "строки, похожие на ключи"
check "названы коммит и файл" has "файл keys.txt"
check "значение ключа в отчёт не попало" test -z "$(grep -F "$key" <<<"$out")"
check "код 1" test "$code" = 1
cd "$SB"; rm -r "$T"

for m in "$M" "$MD" "$MN"; do num=$(ms_num "$m"); [ -n "$num" ] && gh api -X DELETE "repos/$R/milestones/$num" >/dev/null 2>&1; done
echo "итог: верно $pass, ошибок $fail"
[ $fail = 0 ]
