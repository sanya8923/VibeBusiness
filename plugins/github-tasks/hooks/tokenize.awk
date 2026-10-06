# Разбор команды оболочки на простые команды и слова — для хуков github-tasks.
#
# На входе — текст команды (любое число строк). На выходе — по строке на каждую простую
# команду, слова разделены символом \037 (US), чтобы пробелы внутри кавычек не рвали
# слово. Разбор посимвольный и сквозной по всей команде:
#   - кавычки ' и " — состояние держится через переводы строк, кавычки снимаются;
#   - «\» + перевод строки склеивает строки, «\x» даёт x (\git → git);
#   - разделители команд: ; & | ( ) { } и перевод строки — подоболочки и группы
#     разбираются как отдельные команды;
#   - подстановка команды $(…) и `…` (в кавычках, без них, в цели перенаправления)
#     разбирается как вложенная команда: состояние внешней команды сохраняется в стеке
#     и восстанавливается после закрывающей скобки — аргументы после подстановки
#     остаются у своей команды;
#   - тела heredoc (<<TAG … TAG) пропускаются — это данные, а не команды;
#   - # в начале слова — комментарий до конца строки;
#   - ${…} остаётся частью слова;
#   - перенаправления ([N]>, >>, >|, [N]<, &>, &>>, [N]>&M, <<<) распознаются только вне
#     кавычек и выводятся отдельным словом с пометкой \002 в начале: «\002>файл».
#     Запреты git такие слова пропускают, хук «только чтение» по ним видит запись;
#   - границы подоболочки ( … ) и подстановки выводятся отдельными строками «\003(» и
#     «\003)»: cd внутри них не действует снаружи, хуки восстанавливают каталог; на месте
#     самой подстановки в слове стоит пометка \004.
# Это не полный разбор bash, а достаточный для запретов: ошибиться он должен в сторону
# «увидеть лишнюю команду», а не «пропустить настоящую».

BEGIN { US = sprintf("%c", 31); RD = sprintf("%c", 2); SM = sprintf("%c", 3); SB = sprintf("%c", 4) }
{ src = src $0 "\n" }

function flush_word() {
  if (inword) {
    # слово — цель перенаправления, начавшаяся с подстановки: пометить оператором
    if (rdop != "") { word = RD rdop word; rdop = "" }
    seg = (seg == "" ? word : seg US word)
  }
  word = ""; inword = 0; wq = 0
}
function flush_seg() {
  flush_word()
  if (seg != "") print seg
  seg = ""
}

# Вложенная подстановка: сохранить внешнюю команду и начать разбор внутренней.
function push(closer) {
  print SM "("
  sp++; S_seg[sp] = seg; S_word[sp] = word; S_q[sp] = q; S_wq[sp] = wq; S_cl[sp] = closer; S_pd[sp] = 0; S_rd[sp] = rdop
  seg = ""; word = ""; inword = 0; q = ""; wq = 0; rdop = ""
}
# Конец подстановки: вывести внутреннюю команду и вернуться к внешней. Подстановка — часть
# слова внешней команды (её текст неизвестен, поэтому слово просто продолжается).
function pop() {
  flush_seg()
  print SM ")"
  # на месте подстановки в слове — пометка \004: слово «$(…)» не пустое и не теряется
  seg = S_seg[sp]; word = S_word[sp] SB; q = S_q[sp]; wq = S_wq[sp]; rdop = S_rd[sp]; inword = 1; sp--
}

# Цель перенаправления: слово после оператора (кавычки снимаются). Выводится одним
# словом «\002<оператор><цель>».
function redirect(   t, ch, qq) {
  while (substr(src, i, 1) == " " || substr(src, i, 1) == "\t") i++
  t = ""
  while (i <= n) {
    ch = substr(src, i, 1)
    # цель начинается или продолжается подстановкой ($(…), `…`, <(…), >(…)): слово цели
    # дособерёт основной цикл, а оператор пометит его при выводе (rdop)
    if (substr(src, i, 2) == "$(" || ch == "`" || substr(src, i, 2) == "<(" || substr(src, i, 2) == ">(") {
      flush_word(); word = t; inword = 1; rdop = op; return
    }
    if (index(" \t\n;&|()<>", ch) > 0) break
    if (ch == "'" || ch == "\"") {
      qq = ch; i++
      while (i <= n && substr(src, i, 1) != qq) {
        if (qq == "\"" && substr(src, i, 1) == "\\") { t = t substr(src, i + 1, 1); i += 2; continue }
        if (qq == "\"" && (substr(src, i, 2) == "$(" || substr(src, i, 1) == "`")) {
          flush_word(); word = t; inword = 1; rdop = op; q = "\""; return
        }
        t = t substr(src, i, 1); i++
      }
      i++; continue
    }
    t = t ch; i++
  }
  flush_word(); word = RD op t; inword = 1; flush_word()
}

END {
  n = length(src); sp = 0; rdop = ""; q = ""; word = ""; inword = 0; seg = ""; ntags = 0
  i = 1
  while (i <= n) {
    c = substr(src, i, 1); nx = substr(src, i + 1, 1)

    if (q == "'") {
      if (c == "'") q = ""; else word = word c
      i++; continue
    }
    if (q == "\"") {
      if (c == "\\" && index("\"$`\\\n", nx) > 0) { if (nx != "\n") word = word nx; i += 2; continue }
      # $(…) и `…` внутри двойных кавычек исполняются — вложенная команда
      if (c == "$" && nx == "(") { i += 2; push(")"); continue }
      if (c == "`") {
        if (sp > 0 && S_cl[sp] == "`" && S_q[sp] == "\"" ) { i++; pop(); continue }
        i++; push("`"); continue
      }
      if (c == "\"") q = ""; else word = word c
      i++; continue
    }

    # Вне кавычек.
    if (c == "\\") {
      if (nx == "\n") { i += 2; continue }
      word = word nx; inword = 1; wq = 1; i += 2; continue
    }
    if (c == "'" || c == "\"") { q = c; inword = 1; wq = 1; i++; continue }
    if (c == " " || c == "\t") { flush_word(); i++; continue }
    if (c == "#" && !inword) {
      while (i <= n && substr(src, i, 1) != "\n") i++
      continue
    }
    if (c == "$" && nx == "{") {
      j = index(substr(src, i), "}")
      if (j == 0) j = n - i + 1
      word = word substr(src, i, j); inword = 1; i += j; continue
    }
    if (c == "$" && nx == "(") { i += 2; push(")"); continue }
    if (c == "`") {
      if (sp > 0 && S_cl[sp] == "`") { i++; pop(); continue }
      i++; push("`"); continue
    }
    # here-string <<< — оператор со своей целью, не heredoc
    if (substr(src, i, 3) == "<<<") { op = "<<<"; i += 3; redirect(); continue }
    if (c == "<" && nx == "<" && substr(src, i + 2, 1) != "<") {
      # heredoc: запомнить метку, тело пропустить после конца строки
      flush_word()
      j = i + 2; dash = 0
      if (substr(src, j, 1) == "-") { dash = 1; j++ }
      while (substr(src, j, 1) == " " || substr(src, j, 1) == "\t") j++
      # метка — всё до пробела или метасимвола; кавычки и «\» в ней снимаются
      tag = ""
      while (j <= n) {
        ch = substr(src, j, 1)
        if (index(" \t\n;&|()<>", ch) > 0) break
        if (ch != "'" && ch != "\"" && ch != "\\") tag = tag ch
        j++
      }
      if (tag != "") { ntags++; tags[ntags] = tag; dashes[ntags] = dash }
      i = j; continue
    }
    # подстановка процесса <(…) и >(…) — вложенная команда, как $(…)
    if ((c == "<" || c == ">") && nx == "(") { i += 2; push(")"); continue }
    # перенаправление: [N]> [N]>> >| [N]< <> [N]>& <& &> &>>
    if (c == ">" || c == "<" || (c == "&" && nx == ">")) {
      # номер дескриптора — только цифры без кавычек вплотную к оператору: "5">x — не 5>x
      if (inword && !wq && word ~ /^[0-9]+$/) { op = word; word = ""; inword = 0 } else { flush_word(); op = "" }
      if (c == "&") {
        op = op "&>"; i += 2
        if (substr(src, i, 1) == ">") { op = op ">"; i++ }
      } else {
        op = op c; i++; c2 = substr(src, i, 1)
        if (c == ">" && (c2 == ">" || c2 == "|" || c2 == "&")) { op = op c2; i++ }
        else if (c == "<" && (c2 == "&" || c2 == ">")) { op = op c2; i++ }
      }
      redirect(); continue
    }
    if (c == "\n") {
      flush_seg(); i++
      # пропустить тела heredoc, начатых в этой строке
      for (t = 1; t <= ntags; t++) {
        while (i <= n) {
          e = index(substr(src, i), "\n"); if (e == 0) e = n - i + 2
          line = substr(src, i, e - 1); i += e
          if (dashes[t]) sub(/^\t+/, "", line)
          if (line == tags[t]) break
        }
      }
      ntags = 0
      continue
    }
    if (c == ")" && sp > 0 && S_cl[sp] == ")") {
      if (S_pd[sp] > 0) { flush_seg(); print SM ")"; S_pd[sp]--; i++; continue }   # конец подоболочки внутри
      i++; pop(); continue
    }
    if (c == "(" && sp > 0) S_pd[sp]++
    if (c == "(") { flush_seg(); print SM "("; i++; continue }
    if (c == ")") { flush_seg(); print SM ")"; i++; continue }
    if (index(";&|{}", c) > 0) { flush_seg(); i++; continue }

    word = word c; inword = 1; i++
  }
  while (sp > 0) pop()
  flush_seg()
}
