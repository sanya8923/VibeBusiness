#!/bin/bash
# Запуск: GT_TEST_DIR=<папка> GT_TEST_REPO=<владелец/репо> /bin/bash tests/stale-claim.sh
# Тест создаёт и закрывает задачи в тестовом репозитории — только песочница, не рабочий проект.
# Брошенная заявка: сессия написала заявку и упала. Через «10 минут» (здесь 2 секунды)
# новая сессия берёт задачу и удаляет брошенную заявку.
set -u
S=${GT_TEST_DIR:?укажи GT_TEST_DIR — папку, где лежит клон тестового репозитория в подпапке sandbox}
P="$(cd "$(dirname "$0")/../scripts" && pwd)"
R=${GT_TEST_REPO:?укажи GT_TEST_REPO — тестовый репозиторий владелец/имя с файлом .claude/github-tasks.json и метками}
cd "$S/sandbox"
url=$(gh issue create -R "$R" -t "Брошенная заявка" -b "Тест" -l ready); N=${url##*/}
gh api "repos/$R/issues/$N/comments" -f body='<!-- github-tasks:claim session=dead -->
Беру в работу (сессия `dead`).' -q .id >/dev/null
sleep 4
GT_CLAIM_STALE_SECONDS=2 CLAUDE_CODE_SESSION_ID=alive /bin/bash "$P/claim.sh" "$N"; echo "код $?"
echo "заявки в задаче: $(gh api repos/$R/issues/$N/comments -q '[.[] | select(.body | startswith("<!-- github-tasks:claim ")) | .body | capture("session=(?<s>[^ ]+)").s] | join(",")')"
gh issue close "$N" -R "$R" >/dev/null
