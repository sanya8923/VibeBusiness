#!/bin/bash
# Запуск: GT_TEST_DIR=<папка> GT_TEST_REPO=<владелец/репо> /bin/bash tests/chain.sh
# Тест создаёт и закрывает задачи в тестовом репозитории — только песочница, не рабочий проект.
# Цепочка задачи в песочнице: claim → worktree → коммит → open-pr → возврат → open-pr → вердикт → merge.
set -u
S=${GT_TEST_DIR:?укажи GT_TEST_DIR — папку, где лежит клон тестового репозитория в подпапке sandbox}
P="$(cd "$(dirname "$0")/../scripts" && pwd)"
R=${GT_TEST_REPO:?укажи GT_TEST_REPO — тестовый репозиторий владелец/имя с файлом .claude/github-tasks.json и метками}
cd "$S/sandbox" && git pull -q
lbl() { gh issue view "$1" -R "$R" --json labels,assignees,state -q '.state + " | " + ([.labels[].name] | join(",")) + " | исполнителей " + (.assignees | length | tostring)'; }
step() { echo; echo "== $*"; }

url=$(gh issue create -R "$R" -t "Цепочка: добавить файл hello.txt" -b "Тест цепочки скриптов" -l ready); N=${url##*/}
step "задача #$N создана: $(lbl $N)"

step "claim вне git-репозитория (ожидаем отказ)"
(cd / && /bin/bash "$P/claim.sh" "$N"; echo "код $?")
step "claim в репозитории без файла настроек (ожидаем отказ)"
NC=$(mktemp -d) && git -C "$NC" init -q && (cd "$NC" && /bin/bash "$P/claim.sh" "$N"; echo "код $?"); rm -rf "$NC"
step "claim из подпапки репозитория — рабочая копия создаётся от корня"
(cd "$S/sandbox/.claude" && /bin/bash "$P/worktree.sh" 999999 >/dev/null 2>&1; echo "код $?"; git -C "$S/sandbox" worktree remove "$S/sandbox/.claude/worktrees/issue-999999" 2>/dev/null; git -C "$S/sandbox" branch -q -D issue-999999 2>/dev/null)

step "claim"; CLAUDE_CODE_SESSION_ID=chain /bin/bash "$P/claim.sh" "$N"; echo "код $? → $(lbl $N)"
step "повторный claim той же задачи (ожидаем 3)"; /bin/bash "$P/claim.sh" "$N"; echo "код $?"

step "status.sh ready — освобождение"; /bin/bash "$P/status.sh" "$N" ready
echo "→ $(lbl $N), заявок: $(gh api repos/$R/issues/$N/comments -q '[.[] | select(.body | startswith("<!-- github-tasks:claim "))] | length')"
step "claim снова сразу после освобождения"; CLAUDE_CODE_SESSION_ID=chain2 /bin/bash "$P/claim.sh" "$N"; echo "код $? → $(lbl $N)"

step "worktree"; WT=$(/bin/bash "$P/worktree.sh" "$N" | tail -1); echo "путь: $WT"; git -C "$WT" status --short --branch | head -1
step "open-pr без коммитов (ожидаем отказ)"; /bin/bash "$P/open-pr.sh" "$N"; echo "код $?"
echo "привет" > "$WT/hello.txt"
step "open-pr с незакоммиченным файлом (ожидаем отказ)"; /bin/bash "$P/open-pr.sh" "$N"; echo "код $?"
git -C "$WT" add hello.txt && git -C "$WT" commit -q -m "hello.txt"
printf 'Что сделано: файл hello.txt.\nЧем проверено: cat hello.txt → привет.\n' > "$S/report.md"
step "open-pr"; PRURL=$(/bin/bash "$P/open-pr.sh" "$N" "$S/report.md" | tail -1); PR=${PRURL##*/}; echo "PR: $PRURL → $(lbl $N)"
echo "тело PR, первая строка: $(gh pr view $PR -R $R --json body -q .body | head -1)"

step "merge без вердикта (ожидаем отказ)"; /bin/bash "$P/merge.sh" "$PR"; echo "код $?"
gh pr comment "$PR" -R "$R" -b "Вердикт: Возврат
- нет перевода строки в конце → добавить" >/dev/null
step "merge при вердикте «Возврат» (ожидаем отказ)"; /bin/bash "$P/merge.sh" "$PR"; echo "код $?"

step "возврат: in_progress, исправление, повторный open-pr"
/bin/bash "$P/status.sh" "$N" in_progress; echo "!" >> "$WT/hello.txt"; git -C "$WT" commit -q -am "hello.txt: исправление"
/bin/bash "$P/open-pr.sh" "$N" "$S/report.md" | tail -1; echo "→ $(lbl $N), открытых PR по ветке: $(gh pr list -R $R --head issue-$N --json number -q length)"

gh pr comment "$PR" -R "$R" -b "Вердикт: Принято" >/dev/null
step "merge при вердикте «Принято»"; /bin/bash "$P/merge.sh" "$PR"; echo "код $?"
sleep 3; echo "задача: $(lbl $N); PR: $(gh pr view $PR -R $R --json state -q .state)"
git -C "$S/sandbox" worktree remove "$WT" && echo "рабочая копия убрана"
