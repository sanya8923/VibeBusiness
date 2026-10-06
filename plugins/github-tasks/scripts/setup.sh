#!/usr/bin/env bash
# Механическая часть настройки проекта: setup.sh
#
# Запускается скиллом настройки ПОСЛЕ того, как .claude/github-tasks.json записан и
# согласован с человеком. Повторный запуск ничего не дублирует:
#   - заводит недостающие метки статуса и приоритета; существующие не трогает;
#   - кладёт шаблон задачи в .github/ISSUE_TEMPLATE/task.md, если его нет;
#   - дописывает .claude/worktrees/ в .gitignore, если строки нет;
#   - ставит в README блок ссылок-фильтров между метками-маркерами (заменяет старый блок).
# Печатает список изменённых файлов — их скилл коммитит поимённо.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

gt_require_config
ROOT=$(gt_root)
R=$(gt_repo)
TEMPLATES="$(cd "$(dirname "$0")/../templates" && pwd)"
changed=()

existing=$(gh label list -R "$R" --limit 500 --json name -q '.[].name')
# Имена меток в GitHub не различают регистр: «Blocked» и «blocked» — одна метка.
has_label() { printf '%s\n' "$existing" | grep -qixF "$1"; }
mk() {  # имя цвет описание
  if has_label "$1"; then echo "метка $1 — уже есть"; else
    gh label create "$1" -R "$R" -c "$2" -d "$3" >/dev/null && echo "метка $1 — создана"; fi
}
mk "$(gt_label ready)"          0e8a16 "Постановка полная, задачу можно брать"
mk "$(gt_label in_progress)"    fbca04 "Задачу взял агент или человек"
mk "$(gt_label in_review)"      1d76db "Открыт PR, идёт приёмка"
mk "$(gt_label blocked)"        b60205 "Ждёт другой задачи или внешнего события"
mk "$(gt_label owner_decision)" d93f0b "Ждёт решения владельца"
mk P0 b60205 "Горит"
mk P1 d93f0b "Важно, следующее в очереди"
mk P2 fbca04 "Обычный приоритет"
mk P3 c2e0c6 "Когда руки дойдут"

tpl="$ROOT/.github/ISSUE_TEMPLATE/task.md"
if [ -f "$tpl" ]; then echo "шаблон задачи — уже есть"; else
  mkdir -p "$(dirname "$tpl")"; cp "$TEMPLATES/task.md" "$tpl"; changed+=(".github/ISSUE_TEMPLATE/task.md"); echo "шаблон задачи — добавлен"; fi

gi="$ROOT/.gitignore"
if [ -f "$gi" ] && grep -qxF ".claude/worktrees/" "$gi"; then echo ".gitignore — уже прячет рабочие копии"; else
  { [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ] && echo; echo ".claude/worktrees/"; } >> "$gi"
  changed+=(".gitignore"); echo ".gitignore — добавлена строка .claude/worktrees/"; fi

# Блок ссылок-фильтров: вместо доски — сохранённые поиски по меткам.
base="https://github.com/$R/issues?q="
# Запрос кодируется целиком; имена меток — в кавычках, чтобы «in progress» был одной меткой.
urlencode() {
  local LC_ALL=C s=$1 out="" k ch
  for ((k = 0; k < ${#s}; k++)); do
    ch=${s:$k:1}
    case "$ch" in
      [A-Za-z0-9._~-]) out="$out$ch" ;;
      # & 255: bash 3.2 читает байт старше 0x7F как отрицательное число
      *) out="$out$(printf '%%%02X' $(( $(printf '%d' "'$ch") & 255 )))" ;;
    esac
  done
  printf '%s' "$out"
}
q() { urlencode "is:issue is:open $1"; }
L_R=$(gt_label ready); L_P=$(gt_label in_progress); L_V=$(gt_label in_review)
L_B=$(gt_label blocked); L_O=$(gt_label owner_decision)
block=$(cat <<EOF
<!-- github-tasks:filters -->
## Задачи проекта

Статус задачи — метка, доски нет. Сохранённые фильтры:

- [На приёмке]($base$(q "label:\"$L_V\""))
- [Ждёт моего решения]($base$(q "label:\"$L_O\""))
- [Блокеры]($base$(q "label:\"$L_B\""))
- [В работе]($base$(q "label:\"$L_P\""))
- [Готово к работе]($base$(q "label:\"$L_R\""))
- [Черновики и задачи без статуса]($base$(q "-label:\"$L_R\" -label:\"$L_P\" -label:\"$L_V\" -label:\"$L_B\" -label:\"$L_O\""))
<!-- /github-tasks:filters -->
EOF
)
readme="$ROOT/README.md"
[ -f "$readme" ] || : > "$readme"
tmp=$(mktemp); blockfile=$(mktemp)
printf '%s\n' "$block" > "$blockfile"
open_n=$(grep -cF '<!-- github-tasks:filters -->' "$readme" || true)
close_n=$(grep -cF '<!-- /github-tasks:filters -->' "$readme" || true)
if [ "$open_n" != "$close_n" ]; then
  rm -f "$tmp" "$blockfile"
  gt_die "в README.md маркеры блока фильтров непарные (открывающих: $open_n, закрывающих: $close_n) — поправь README вручную, файл не тронут"
fi
if [ "$open_n" -gt 1 ]; then
  rm -f "$tmp" "$blockfile"
  gt_die "в README.md блок фильтров встречается $open_n раза — оставь один и запусти снова, файл не тронут"
fi
if [ "$open_n" = 1 ] && [ "$(grep -nF '<!-- github-tasks:filters -->' "$readme" | cut -d: -f1)" -gt "$(grep -nF '<!-- /github-tasks:filters -->' "$readme" | cut -d: -f1)" ]; then
  rm -f "$tmp" "$blockfile"
  gt_die "в README.md закрывающий маркер блока фильтров стоит раньше открывающего — поправь README вручную, файл не тронут"
fi
if [ "$open_n" = 1 ]; then
  # блок — из файла: awk из macOS не принимает многострочное значение в -v
  awk -v bf="$blockfile" '
    /<!-- github-tasks:filters -->/ { while ((getline l < bf) > 0) print l; skip = 1; next }
    /<!-- \/github-tasks:filters -->/ { skip = 0; next }
    !skip { print }' "$readme" > "$tmp"
else
  { cat "$readme"; [ -s "$readme" ] && echo; echo "$block"; } > "$tmp"
fi
rm -f "$blockfile"
if cmp -s "$tmp" "$readme"; then rm -f "$tmp"; echo "README — фильтры уже актуальны"; else
  mv "$tmp" "$readme"; changed+=("README.md"); echo "README — блок фильтров обновлён"; fi

echo "изменённые файлы: ${changed[*]+"${changed[*]}"}"
