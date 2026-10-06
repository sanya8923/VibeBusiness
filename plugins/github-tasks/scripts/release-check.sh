#!/usr/bin/env bash
# Проверка перед релизом: release-check.sh [веха]
#
# Общие проверки любого проекта на GitHub плюс проверки проекта из поля release_checks
# файла настроек. Печатает отчёт по каждой проверке, последней строкой — вердикт.
# Ничего не выкладывает, тегов не ставит, PR не сливает.
# Код выхода: 0 — можно выкладывать, 1 — нельзя.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

gt_require_config
ROOT=$(gt_root)
R=$(gt_repo)
BASE=$(gt_base)
BLOCKED=$(gt_label blocked)
fails=()
ok()   { echo "  ✔ $*"; }
bad()  { echo "  ✘ $*"; fails+=("$1"); }
skip() { echo "  – $*"; }

echo "Проверка перед релизом: $R, ветка $BASE"

# 1. Задачи вехи
M=${1:-}
if [ -z "$M" ]; then
  M=$(gh api "repos/$R/milestones?state=open&sort=due_on&direction=asc" -q '.[0].title // ""')
fi
echo "1. Задачи вехи"
if [ -n "$M" ]; then
  open=$(gh issue list -R "$R" --milestone "$M" --state open --limit 200 --json number -q 'length')
  if [ "$open" = 0 ]; then ok "веха «${M}»: открытых задач нет"; else
    bad "задачи вехи «${M}» не закрыты: $open — $(gh issue list -R "$R" --milestone "$M" --state open --limit 10 --json number -q '[.[] | "#\(.number)"] | join(", ")')"; fi
else
  skip "открытых вех нет — проверка пропущена"
fi

# 2. Блокеры
echo "2. Блокеры"
if [ -n "$M" ]; then scope=(--milestone "$M"); else scope=(); fi
blk=$(gh issue list -R "$R" ${scope[@]+"${scope[@]}"} --label "$BLOCKED" --state open --limit 50 --json number -q '[.[] | "#\(.number)"] | join(", ")')
if [ -z "$blk" ]; then ok "открытых блокеров нет"; else bad "открытые блокеры: $blk"; fi

# 3. CI на базовой ветке — последний прогон каждого воркфлоу
echo "3. CI на ветке $BASE"
runs=$(gh run list -R "$R" --branch "$BASE" --limit 30 --json workflowName,conclusion,status \
  -q 'reduce .[] as $r ({}; if has($r.workflowName) then . else .[$r.workflowName] = $r end) | .[] | "\(.workflowName)\u001f\(.status)\u001f\(.conclusion)"' 2>/dev/null || true)
if [ -z "$runs" ]; then skip "прогонов CI на ветке нет — проверка пропущена"; else
  while IFS=$'\x1f' read -r wf st co; do
    if [ "$st" != completed ]; then bad "CI «${wf}» ещё идёт ($st)"
    elif [ "$co" = success ] || [ "$co" = skipped ]; then ok "CI «${wf}»: $co"
    else bad "CI «${wf}»: $co"; fi
  done <<<"$runs"
fi

# 4. Секреты в изменениях с прошлого релиза
echo "4. Секреты с прошлого релиза"
git -C "$ROOT" fetch -q --tags origin "$BASE" 2>/dev/null || true
tag=$(git -C "$ROOT" describe --tags --abbrev=0 "origin/$BASE" 2>/dev/null || true)
range=${tag:+$tag..}origin/$BASE
[ -n "$tag" ] || range="origin/$BASE~50..origin/$BASE"
hits=$(git -C "$ROOT" log -p --no-color "$range" 2>/dev/null \
  | grep -E '^\+' \
  | grep -nE 'AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AIza[0-9A-Za-z_-]{35}' \
  | head -5 || true)
if [ -z "$hits" ]; then ok "похожих на ключи строк нет (${tag:-последние 50 коммитов})"; else
  bad "похожие на ключи строки в изменениях:"; printf '%s\n' "$hits" | cut -c1-120 | sed 's/^/      /'; fi

# 5. Проверки проекта
echo "5. Проверки проекта (release_checks)"
release_checks() {  # «имя␟команда» по строке на проверку из файла настроек
  local f
  f=$(gt_config_file)
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
for x in c.get("release_checks") or []:
    print((x.get("name") or x["run"]) + "\x1f" + x["run"])' "$f"
  elif command -v node >/dev/null 2>&1; then
    node -e '
const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
for (const x of c.release_checks || []) console.log((x.name || x.run) + "\u001f" + x.run);' "$f"
  fi
}
checks=$(release_checks)
if [ -z "$checks" ]; then skip "в настройках проверок нет"; else
  while IFS=$'\x1f' read -r name run; do
    out=$(cd "$ROOT" && bash -c "$run" 2>&1); code=$?
    if [ $code = 0 ]; then ok "$name"; else bad "$name (код $code)"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /'; fi
  done <<<"$checks"
fi

# Список изменений
echo "Изменения ${tag:+с $tag}:"
since=""
[ -n "$tag" ] && since=$(git -C "$ROOT" log -1 --format=%cI "$tag" 2>/dev/null | cut -c1-10)
gh pr list -R "$R" --state merged --base "$BASE" --limit 50 ${since:+--search "merged:>=$since"} \
  --json number,title -q '.[] | "  - #\(.number) \(.title)"'

echo
if [ ${#fails[@]} = 0 ]; then echo "Можно выкладывать."; exit 0; fi
echo "Нельзя выкладывать: $(IFS=';'; echo "${fails[*]}")"
exit 1
