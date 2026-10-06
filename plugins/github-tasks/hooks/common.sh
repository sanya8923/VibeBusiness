#!/usr/bin/env bash
# Общее для хуков github-tasks. Подключается через `. common.sh`.
#
# Хуки действуют только в проекте, где есть .claude/github-tasks.json и в нём не
# выключены хуки ("hooks": false). В остальных проектах пользователя плагин молчит.

# Поле из JSON на stdin хука: `hk_field tool_input.command`. Читает python3 или node.
hk_field() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
v = json.loads(sys.stdin.read() or "{}")
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$1"
  elif command -v node >/dev/null 2>&1; then
    node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  let v = JSON.parse(s || "{}");
  for (const k of process.argv[1].split(".")) v = (v && typeof v === "object") ? v[k] : undefined;
  console.log(v === undefined || v === null ? "" : String(v));
});' "$1"
  else
    cat >/dev/null; echo ""
  fi
}

# Корень основной копии репозитория для каталога $1 (или пусто, если не репозиторий).
hk_root() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  dirname "$common"
}

# Включён ли процесс в репозитории с корнем $1: есть файл настроек и hooks не false.
hk_enabled() {
  local cfg="$1/.claude/github-tasks.json"
  [ -f "$cfg" ] || return 1
  ! grep -qE '"hooks"[[:space:]]*:[[:space:]]*false' "$cfg"
}

# base_branch из файла настроек (пусто, если не задана).
hk_base_branch() {
  sed -nE 's/.*"base_branch"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$1/.claude/github-tasks.json" | head -1
}

# Основная ветка репозитория по origin/HEAD, без обращения к сети.
hk_default_branch() {
  local ref
  ref=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || ref=""
  [ -n "$ref" ] && echo "${ref#origin/}" || echo main
}
