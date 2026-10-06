#!/usr/bin/env bash
# Проверка перед релизом: release-check.sh [веха]
#
# Общие проверки любого проекта на GitHub плюс проверки проекта из поля release_checks
# файла настроек. Печатает отчёт по каждой проверке, последней строкой — вердикт.
# Ничего не выкладывает, тегов не ставит, PR не сливает.
# Правило: «✔» ставится только тому, что действительно проверено; не удалось проверить —
# «✘ не удалось проверить», а не «✔».
# Код выхода: 0 — можно выкладывать, 1 — нельзя.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

gt_require_config
ROOT=$(gt_root)
R=$(gt_repo)
BLOCKED=$(gt_label blocked)
fails=()
ok()   { echo "  ✔ $*"; }
bad()  { echo "  ✘ $*"; fails+=("$1"); }
skip() { echo "  – $*"; }

# gh с проверкой: вывод в $GHOUT, код — свой. Ошибку не превращаем в «пусто = всё хорошо».
ghq() { GHOUT=$(gh "$@" 2>&1); }

if ! ghq repo view "$R" --json defaultBranchRef -q .defaultBranchRef.name; then
  echo "Проверка перед релизом: $R"
  bad "не удалось обратиться к репозиторию на GitHub: $(printf '%s' "$GHOUT" | head -1)"
  echo; echo "Нельзя выкладывать: не удалось проверить репозиторий"; exit 1
fi
BASE=$(gt_cfg base_branch); [ -n "$BASE" ] || BASE=$GHOUT
echo "Проверка перед релизом: $R, ветка $BASE"

# 1. Задачи вехи
echo "1. Задачи вехи"
M=${1:-}
if [ -n "$M" ]; then
  if ! ghq api --paginate "repos/$R/milestones?state=all&per_page=100" -q '.[].title'; then
    bad "не удалось получить вехи: $(printf '%s' "$GHOUT" | head -1)"; M=""
  elif ! printf '%s\n' "$GHOUT" | grep -qxF "$M"; then
    bad "веха «${M}» не найдена в репозитории"; M=""
  fi
else
  # ближайшая открытая веха со сроком; без срока — только если других нет
  if ghq api "repos/$R/milestones?state=open&per_page=100" \
       -q '[.[] | select(.due_on != null)] | sort_by(.due_on) | .[0].title // ""'; then
    M=$GHOUT
    if [ -z "$M" ] && ghq api "repos/$R/milestones?state=open&per_page=100" -q '.[0].title // ""'; then M=$GHOUT; fi
    if [ -n "$M" ]; then echo "  (веха не указана — взята ближайшая открытая: «${M}»)"
    else skip "открытых вех нет — проверка задач вехи пропущена"; fi
  else
    bad "не удалось получить вехи: $(printf '%s' "$GHOUT" | head -1)"; M=""
  fi
fi
if [ -n "$M" ]; then
  if ghq issue list -R "$R" --milestone "$M" --state open --limit 500 --json number -q '[.[] | "#\(.number)"] | join(", ")'; then
    if [ -z "$GHOUT" ]; then ok "веха «${M}»: открытых задач нет"; else bad "задачи вехи «${M}» не закрыты: $GHOUT"; fi
  else
    bad "не удалось получить задачи вехи: $(printf '%s' "$GHOUT" | head -1)"
  fi
fi

# 2. Блокеры — по всему репозиторию
echo "2. Блокеры"
if ghq issue list -R "$R" --label "$BLOCKED" --state open --limit 200 --json number -q '[.[] | "#\(.number)"] | join(", ")'; then
  if [ -z "$GHOUT" ]; then ok "открытых блокеров нет"; else bad "открытые блокеры: $GHOUT"; fi
else
  bad "не удалось проверить блокеры: $(printf '%s' "$GHOUT" | head -1)"
fi

# 3. CI — последний прогон каждого активного воркфлоу на базовой ветке
echo "3. CI на ветке $BASE"
if ! ghq workflow list -R "$R" --json id,name,state -q '.[] | select(.state == "active") | "\(.id)\u001f\(.name)"'; then
  bad "не удалось получить воркфлоу: $(printf '%s' "$GHOUT" | head -1)"
elif [ -z "$GHOUT" ]; then
  skip "воркфлоу CI в репозитории нет — проверка пропущена"
else
  wfs=$GHOUT; any=0
  while IFS=$'\x1f' read -r wid wname; do
    [ -n "$wid" ] || continue
    if ! ghq run list -R "$R" --workflow "$wid" --branch "$BASE" --limit 1 --json status,conclusion -q '.[] | "\(.status)\u001f\(.conclusion)"'; then
      bad "CI «${wname}»: не удалось получить прогоны"; continue
    fi
    if [ -z "$GHOUT" ]; then skip "CI «${wname}»: прогонов на ветке нет"; continue; fi
    any=1
    IFS=$'\x1f' read -r st co <<<"$GHOUT"
    if [ "$st" != completed ]; then bad "CI «${wname}» ещё идёт ($st)"
    elif [ "$co" = success ] || [ "$co" = skipped ] || [ "$co" = neutral ]; then ok "CI «${wname}»: $co"
    else bad "CI «${wname}»: $co"; fi
  done <<<"$wfs"
  [ "$any" = 1 ] || skip "ни у одного воркфлоу нет прогонов на ветке $BASE"
fi

# 4. Секреты в изменениях с прошлого релиза
echo "4. Секреты с прошлого релиза"
git -C "$ROOT" fetch -q origin "$BASE" 2>/dev/null
# последний тег, который есть на GitHub (локальные теги, удалённые на GitHub, не считаем)
remote_tags=$(git -C "$ROOT" ls-remote --tags --refs origin 2>/dev/null | sed 's|.*refs/tags/||')
tag=""
if [ -n "$remote_tags" ]; then
  git -C "$ROOT" fetch -q --tags origin 2>/dev/null
  for t in $(git -C "$ROOT" tag --merged "origin/$BASE" --sort=-creatordate 2>/dev/null); do
    if printf '%s\n' "$remote_tags" | grep -qxF "$t"; then tag=$t; break; fi
  done
fi
if [ -n "$tag" ]; then range="$tag..origin/$BASE"; scope="с тега $tag"
else range="--max-count=1000 origin/$BASE"; scope="последние 1000 коммитов ветки — тегов нет"; fi
SECRET_RE='AKIA[0-9A-Z]{16}|(^|[^A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|(^|[^A-Za-z0-9_-])sk-(proj-)?[A-Za-z0-9_-]{20,}|(sk|rk)_(live|test)_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+|(^|[^0-9])[0-9]{8,10}:AA[A-Za-z0-9_-]{33}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{36}|GOCSPX-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|aws_secret_access_key[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9/+=]{40}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
# shellcheck disable=SC2086
if ! log=$(git -C "$ROOT" log -p --no-color --format='commit %h' $range 2>&1); then
  bad "не удалось проверить секреты: $(printf '%s' "$log" | head -1)"
else
  # «коммит<TAB>файл<TAB>строка» для каждой добавленной строки
  hits=$(printf '%s\n' "$log" | awk '
    /^commit / { c = $2; next }
    /^\+\+\+ / { f = substr($0, 7); next }
    /^\+/ { print c "\t" f "\t" substr($0, 2) }' | grep -E "$SECRET_RE" | head -10 || true)
  if [ -z "$hits" ]; then ok "похожих на ключи строк нет ($scope)"
  else
    bad "в изменениях есть строки, похожие на ключи ($scope)"
    # само значение не печатаем — только коммит и файл
    printf '%s\n' "$hits" | awk -F'\t' '{ print "      коммит " $1 ", файл " $2 }' | sort -u
  fi
fi

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
    # stdin — пустой: иначе проверка, читающая stdin, «съест» список остальных проверок
    out=$(cd "$ROOT" && bash -c "$run" </dev/null 2>&1); code=$?
    if [ $code = 0 ]; then ok "$name"; else bad "$name (код $code)"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /'; fi
  done <<<"$checks"
fi

# Список изменений: PR, слитые после коммита тега (по полной метке времени)
echo "Изменения${tag:+ с ${tag}}:"
since=""
[ -n "$tag" ] && since=$(TZ=UTC git -C "$ROOT" log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd "$tag" 2>/dev/null)
if ghq pr list -R "$R" --state merged --base "$BASE" --limit 100 ${since:+--search "merged:>$since"} \
     --json number,title -q '.[] | "  - #\(.number) \(.title)"'; then
  if [ -n "$GHOUT" ]; then printf '%s\n' "$GHOUT"; else echo "  (слитых PR нет)"; fi
else
  echo "  (не удалось получить список PR: $(printf '%s' "$GHOUT" | head -1))"
fi

echo
if [ ${#fails[@]} = 0 ]; then echo "Можно выкладывать."; exit 0; fi
msg=""; for f in "${fails[@]}"; do msg="${msg:+$msg; }$f"; done
echo "Нельзя выкладывать: $msg"
exit 1
