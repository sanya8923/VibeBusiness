#!/usr/bin/env bash
# Общие функции скриптов github-tasks. Подключается через `. lib.sh`, сам не запускается.
#
# Только bash, git и gh. JSON ответов GitHub разбираем встроенным в gh фильтром
# (`--jq`), а файл настроек проекта — python3 или node: gh не умеет читать локальные
# файлы, а отдельный jq у пользователя может не стоять.

gt_die()  { echo "github-tasks: $*" >&2; exit 1; }
gt_busy() { echo "github-tasks: занято — $*" >&2; exit 3; }

# Корень основной рабочей копии — даже если скрипт вызван из .claude/worktrees/issue-N.
gt_root() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || gt_die "это не git-репозиторий"
  dirname "$common"
}

gt_config_file() { echo "$(gt_root)/.claude/github-tasks.json"; }

gt_require_config() {
  # gt_root вызываем не в подстановке: её gt_die завершил бы только подоболочку.
  git rev-parse --git-common-dir >/dev/null 2>&1 || gt_die "это не git-репозиторий"
  [ -f "$(gt_config_file)" ] || gt_die "в проекте нет .claude/github-tasks.json — процесс здесь не включён (настройка проекта создаёт файл)"
}

# Значение из файла настроек по пути через точку: `gt_cfg labels.ready`.
# Список печатается построчно, null и отсутствие поля — пустая строка.
gt_cfg() {
  local file key="$1"
  file=$(gt_config_file)
  [ -f "$file" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PY'
import json, sys
v = json.load(open(sys.argv[1], encoding="utf-8"))
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
if v is None:
    pass
elif isinstance(v, list):
    for x in v:
        print(json.dumps(x, ensure_ascii=False) if isinstance(x, (dict, list)) else x)
elif isinstance(v, bool):
    print("true" if v else "false")
else:
    print(v)
PY
  elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
let v = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const k of process.argv[2].split(".")) v = (v && typeof v === "object" && !Array.isArray(v)) ? v[k] : undefined;
if (v === undefined || v === null) process.exit(0);
if (Array.isArray(v)) for (const x of v) console.log(typeof x === "object" ? JSON.stringify(x) : String(x));
else console.log(String(v));
' "$file" "$key"
  else
    gt_die "для чтения .claude/github-tasks.json нужен python3 или node"
  fi
}

# Имя метки статуса по ключу: ready, in_progress, in_review, blocked, owner_decision.
gt_label() {
  local v
  v=$(gt_cfg "labels.$1")
  if [ -n "$v" ]; then echo "$v"; return; fi
  case "$1" in
    ready) echo ready ;;
    in_progress) echo in-progress ;;
    in_review) echo in-review ;;
    blocked) echo blocked ;;
    owner_decision) echo owner-decision ;;
    *) gt_die "неизвестный ключ статуса: $1" ;;
  esac
}

GT_STATUS_KEYS="ready in_progress in_review blocked owner_decision"

# Принимает и ключ (in_progress), и имя метки (in-progress) — возвращает ключ.
gt_status_key() {
  local k
  for k in $GT_STATUS_KEYS; do
    if [ "$1" = "$k" ] || [ "$1" = "$(gt_label "$k")" ]; then echo "$k"; return; fi
  done
  [ "$1" = none ] && { echo none; return; }
  gt_die "неизвестный статус: $1 (есть: $GT_STATUS_KEYS, none)"
}

gt_repo() {
  if [ -n "${GT_REPO:-}" ]; then echo "$GT_REPO"; return; fi
  (cd "$(gt_root)" && gh repo view --json nameWithOwner -q .nameWithOwner) || gt_die "не удалось определить репозиторий GitHub"
}

gt_default_branch() {
  gh repo view "$(gt_repo)" --json defaultBranchRef -q .defaultBranchRef.name
}

# Куда идут PR задач: base_branch из настроек, иначе основная ветка репозитория.
gt_base() {
  local b
  b=$(gt_cfg base_branch)
  if [ -n "$b" ]; then echo "$b"; else gt_default_branch; fi
}

gt_require_number() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || gt_die "нужен номер задачи цифрами, получено: «${1:-}»"
}

gt_worktree_path() { echo "$(gt_root)/.claude/worktrees/issue-$1"; }
