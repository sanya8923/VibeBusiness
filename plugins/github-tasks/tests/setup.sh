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
check "ссылка «На приёмке» ведёт на фильтр по in-review" grep -qF 'label%3A%22in-review%22' README.md

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

echo "== сопоставленная метка с пробелом в имени"
git checkout -q -- . 2>/dev/null
printf '{\n  "labels": {"blocked": "good first issue"}\n}\n' > .claude/github-tasks.json
/bin/bash "$P/setup.sh" >/dev/null 2>&1; code=$?
check "запуск без ошибки" test "$code" = 0
check "ссылка «Блокеры» — метка в кавычках, запрос закодирован" grep -qF 'label%3A%22good%20first%20issue%22' README.md
check "метка «good first issue» не задвоена" test "$(gh label list -R "$R" --limit 200 --json name -q '[.[] | select(.name | ascii_downcase == "good first issue")] | length')" = 1

echo "== сопоставленная метка на кириллице"
git checkout -q -- . 2>/dev/null
printf '{\n  "labels": {"in_progress": "в работе"}\n}\n' > .claude/github-tasks.json
/bin/bash "$P/setup.sh" >/dev/null 2>&1; code=$?
check "запуск без ошибки" test "$code" = 0
check "кириллица закодирована верно (%D0%B2 = «в»)" grep -qF 'label%3A%22%D0%B2%20%D1%80%D0%B0%D0%B1%D0%BE%D1%82%D0%B5%22' README.md
before=$(cksum < README.md)
/bin/bash "$P/setup.sh" >/dev/null 2>&1
check "повторный запуск под /bin/bash README не меняет" test "$before" = "$(cksum < README.md)"
gh label delete "в работе" -R "$R" --yes >/dev/null 2>&1

echo "== метка уже есть в другом регистре"
git checkout -q -- . 2>/dev/null
printf '{\n  "labels": {"blocked": "Blocked"}\n}\n' > .claude/github-tasks.json
out=$(/bin/bash "$P/setup.sh" 2>&1); code=$?
check "запуск без ошибки" test "$code" = 0
check "метка считается существующей" grep -qF 'метка Blocked — уже есть' <<<"$out"

echo "== README без закрывающего маркера не портится"
git checkout -q -- . 2>/dev/null
printf '# Проект\n<!-- github-tasks:filters -->\nстарое\n## Важный раздел\nтекст\n' > README.md
before=$(cksum < README.md)
out=$(/bin/bash "$P/setup.sh" 2>&1); code=$?
check "скрипт отказал" test "$code" != 0
check "README не тронут" test "$before" = "$(cksum < README.md)"
check "понятная причина" grep -qF 'маркеры блока фильтров непарные' <<<"$out"

git checkout -q -- . 2>/dev/null
git clean -qfd .github 2>/dev/null
git ls-files --error-unmatch .gitignore >/dev/null 2>&1 || rm -f .gitignore
gh label edit ready -R "$R" -c 0e8a16 -d "Постановка полная, задачу можно брать" >/dev/null 2>&1
echo "итог: верно $pass, ошибок $fail"
[ $fail = 0 ]
