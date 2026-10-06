#!/bin/bash
# Проверка scripts/setup.sh на тестовом репозитории: первый запуск заводит метки, шаблон,
# строку в .gitignore и блок фильтров в README; повторный — ничего не дублирует.
# Метки процесса в тестовом репозитории перед прогоном удаляются — только песочница!
# Локальные правки файлов после прогона откатываются.
# Запуск: GT_TEST_DIR=<папка> GT_TEST_REPO=<владелец/репо> /bin/bash tests/setup.sh
#   <папка>/sandbox — клон тестового репозитория с .claude/github-tasks.json.
set -u
S=${GT_TEST_DIR:?укажи GT_TEST_DIR}
R=${GT_TEST_REPO:?укажи GT_TEST_REPO}
P="$(cd "$(dirname "$0")/../scripts" && pwd)"
SB=$S/sandbox
pass=0; fail=0
check() {  # описание условие...
  local d=$1; shift
  if "$@"; then pass=$((pass+1)); echo "ok      $d"; else fail=$((fail+1)); echo "ОШИБКА  $d"; fi
}

cd "$SB" || exit 1
git checkout -q -- . 2>/dev/null
for l in ready in-progress in-review blocked owner-decision P0 P1 P2 P3; do
  gh label delete "$l" -R "$R" --yes >/dev/null 2>&1
done

echo "== первый запуск"
out1=$(/bin/bash "$P/setup.sh" 2>&1); echo "$out1" | sed 's/^/   /'
labels=$(gh label list -R "$R" --limit 200 --json name -q '.[].name')
for l in ready in-progress in-review blocked owner-decision P0 P1 P2 P3; do
  check "метка $l заведена" grep -qxF "$l" <<<"$labels"
done
check "шаблон задачи положен" test -f .github/ISSUE_TEMPLATE/task.md
check ".gitignore прячет рабочие копии" grep -qxF ".claude/worktrees/" .gitignore
check "в README блок фильтров" grep -qF '<!-- github-tasks:filters -->' README.md
check "ссылка «На приёмке» ведёт на фильтр по in-review" grep -qF 'label%3Ain-review' README.md

echo "== повторный запуск"
before=$(cat README.md .gitignore .github/ISSUE_TEMPLATE/task.md | cksum)
out2=$(/bin/bash "$P/setup.sh" 2>&1); echo "$out2" | sed 's/^/   /'
after=$(cat README.md .gitignore .github/ISSUE_TEMPLATE/task.md | cksum)
check "файлы не изменились" test "$before" = "$after"
check "изменённых файлов нет" grep -qE '^изменённые файлы: *$' <<<"$out2"
check "блок фильтров в README один" test "$(grep -c '<!-- github-tasks:filters -->' README.md)" = 1
check "строка в .gitignore одна" test "$(grep -cxF '.claude/worktrees/' .gitignore)" = 1
check "меток не прибавилось" test "$(gh label list -R "$R" --limit 200 --json name -q 'length')" = "$(wc -l <<<"$labels" | tr -d ' ')"

echo "== существующие метки не трогаются"
gh label edit ready -R "$R" -c 123456 -d "своё описание" >/dev/null
/bin/bash "$P/setup.sh" >/dev/null 2>&1
check "цвет и описание существующей метки сохранены" test "$(gh label list -R "$R" --json name,color,description -q '.[] | select(.name=="ready") | .color + "|" + .description')" = "123456|своё описание"

git checkout -q -- . 2>/dev/null
git clean -qfd .github 2>/dev/null
echo "итог: верно $pass, ошибок $fail"
[ $fail = 0 ]
