#!/bin/bash
# Запуск: GT_TEST_DIR=<папка> GT_TEST_REPO=<владелец/репо> /bin/bash tests/claim-race.sh
# Тест создаёт и закрывает задачи в тестовом репозитории — только песочница, не рабочий проект.
# 10 прогонов: две одновременные claim.sh на одну задачу → ровно один победитель.
# Запускается системным /bin/bash 3.2, как у получателя на macOS.
set -u
S=${GT_TEST_DIR:?укажи GT_TEST_DIR — папку, где лежит клон тестового репозитория в подпапке sandbox}
P="$(cd "$(dirname "$0")/../scripts" && pwd)"
R=${GT_TEST_REPO:?укажи GT_TEST_REPO — тестовый репозиторий владелец/имя с файлом .claude/github-tasks.json и метками}
cd "$S/sandbox"
pass=0
for i in $(seq 1 10); do
  url=$(gh issue create -R "$R" -t "Гонка захвата, прогон $i" -b "Тест claim.sh" -l ready)
  n=${url##*/}
  CLAUDE_CODE_SESSION_ID="A-$i" /bin/bash "$P/claim.sh" "$n" > "$S/race-a.out" 2>&1 & pa=$!
  CLAUDE_CODE_SESSION_ID="B-$i" /bin/bash "$P/claim.sh" "$n" > "$S/race-b.out" 2>&1 & pb=$!
  wait $pa; ca=$?; wait $pb; cb=$?
  claims=$(gh api "repos/$R/issues/$n/comments" -q '[.[] | select(.body | startswith("<!-- github-tasks:claim "))] | length')
  labels=$(gh issue view "$n" -R "$R" --json labels,assignees -q '([.labels[].name] | join(",")) + " / исполнителей: " + (.assignees | length | tostring)')
  winners=0; [ $ca = 0 ] && winners=$((winners+1)); [ $cb = 0 ] && winners=$((winners+1))
  ok=no
  if [ $winners = 1 ] && [ "$claims" = 1 ] && [ "$labels" = "in-progress / исполнителей: 1" ]; then ok=yes; pass=$((pass+1)); fi
  echo "прогон $i (#$n): коды A=$ca B=$cb, заявок осталось $claims, метки $labels → $ok"
  gh issue close "$n" -R "$R" >/dev/null
done
echo "итог: $pass из 10"
