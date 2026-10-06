#!/bin/bash
# Быстрая проверка скриптов плагина без GitHub: синтаксис под системным bash и
# переменные, к которым вплотную примыкает не-ASCII символ («$x»): bash 3.2 в локали
# UTF-8 приклеивает первый байт символа к имени переменной, и при set -u скрипт падает
# с «unbound variable». Такие места пишем как «${x}».
# Запуск: /bin/bash tests/lint.sh
set -u
cd "$(dirname "$0")/.."
fail=0
for f in scripts/*.sh hooks/*.sh tests/*.sh; do
  [ -f "$f" ] || continue
  /bin/bash -n "$f" || { echo "синтаксис: $f"; fail=1; }
done
bad=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' scripts/*.sh hooks/*.sh tests/*.sh 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
if [ -n "$bad" ]; then echo "переменная вплотную к не-ASCII символу — нужно \${имя}:"; echo "$bad"; fail=1; fi
[ $fail = 0 ] && echo "lint: чисто"
exit $fail
