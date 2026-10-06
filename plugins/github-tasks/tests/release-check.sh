#!/bin/bash
# Проверка scripts/release-check.sh на тестовом репозитории: веха с открытой задачей и
# блокером → «Нельзя выкладывать»; после закрытия → «Можно выкладывать»; упавшая проверка
# проекта из release_checks → «Нельзя». Создаёт и закрывает задачи и веху — только песочница!
# Запуск: GT_TEST_DIR=<папка> GT_TEST_REPO=<владелец/репо> /bin/bash tests/release-check.sh
set -u
S=${GT_TEST_DIR:?укажи GT_TEST_DIR}
R=${GT_TEST_REPO:?укажи GT_TEST_REPO}
P="$(cd "$(dirname "$0")/../scripts" && pwd)"
SB=$S/sandbox
pass=0; fail=0
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); echo "ok      $d"; else fail=$((fail+1)); echo "ОШИБКА  $d"; fi; }

cd "$SB" || exit 1
git checkout -q -- . 2>/dev/null
M="release-check-test-$$"
gh api "repos/$R/milestones" -f title="$M" -q .number >/dev/null
u1=$(gh issue create -R "$R" -t "Релиз: обычная задача" -b t -m "$M"); n1=${u1##*/}
u2=$(gh issue create -R "$R" -t "Релиз: блокер" -b t -m "$M" -l blocked); n2=${u2##*/}
sleep 8

echo "== открытые задачи и блокер"
out=$(/bin/bash "$P/release-check.sh" "$M" 2>&1); code=$?
echo "$out" | sed 's/^/   /'
check "код 1" test "$code" = 1
check "последняя строка — «Нельзя выкладывать»" grep -q '^Нельзя выкладывать' <<<"$(tail -1 <<<"$out")"
check "названы незакрытые задачи вехи" grep -qF "#$n1" <<<"$out"
check "назван блокер" grep -qF "открытые блокеры: #$n2" <<<"$out"

echo "== всё закрыто"
gh issue close "$n1" -R "$R" >/dev/null; gh issue close "$n2" -R "$R" >/dev/null
sleep 8
out=$(/bin/bash "$P/release-check.sh" "$M" 2>&1); code=$?
echo "$out" | sed 's/^/   /'
check "код 0" test "$code" = 0
check "последняя строка — «Можно выкладывать.»" test "$(tail -1 <<<"$out")" = "Можно выкладывать."

echo "== упавшая проверка проекта"
printf '{\n  "release_checks": [{"name": "всегда падает", "run": "echo сломано; exit 3"}, {"name": "проходит", "run": "true"}]\n}\n' > .claude/github-tasks.json
out=$(/bin/bash "$P/release-check.sh" "$M" 2>&1); code=$?
echo "$out" | sed 's/^/   /'
check "код 1" test "$code" = 1
check "проверка «всегда падает» — не пройдена с кодом" grep -qF '✘ всегда падает (код 3)' <<<"$out"
check "вывод упавшей проверки показан" grep -qF 'сломано' <<<"$out"
check "проверка «проходит» — пройдена" grep -qF '✔ проходит' <<<"$out"

git checkout -q -- . 2>/dev/null
num=$(gh api "repos/$R/milestones?state=all" -q ".[] | select(.title==\"$M\") | .number")
[ -n "$num" ] && gh api -X DELETE "repos/$R/milestones/$num" >/dev/null 2>&1
echo "итог: верно $pass, ошибок $fail"
[ $fail = 0 ]
