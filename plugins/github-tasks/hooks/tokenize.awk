# Разбор команды оболочки на простые команды и слова — для хуков github-tasks.
#
# На входе — текст команды (любое число строк). На выходе — по строке на каждую простую
# команду, слова разделены символом \037 (US), чтобы пробелы внутри кавычек не рвали
# слово. Разбор посимвольный и сквозной по всей команде:
#   - кавычки ' и " — состояние держится через переводы строк, кавычки снимаются;
#   - «\» + перевод строки склеивает строки, «\x» даёт x (\git → git);
#   - разделители команд: ; & | ( ) { } ` $( и перевод строки — так подоболочки,
#     группы и подстановки команд разбираются как отдельные команды;
#   - тела heredoc (<<TAG … TAG) пропускаются — это данные, а не команды;
#   - # в начале слова — комментарий до конца строки;
#   - ${…} остаётся частью слова.
# Это не полный разбор bash, а достаточный для запретов: ошибиться он должен в сторону
# «увидеть лишнюю команду», а не «пропустить настоящую».

BEGIN { US = sprintf("%c", 31) }
{ src = src $0 "\n" }

function flush_word() {
  if (inword) { seg = (seg == "" ? word : seg US word) }
  word = ""; inword = 0
}
function flush_seg() {
  flush_word()
  if (seg != "") print seg
  seg = ""
}

END {
  n = length(src); ret = 0; q = ""; word = ""; inword = 0; seg = ""; ntags = 0
  i = 1
  while (i <= n) {
    c = substr(src, i, 1); nx = substr(src, i + 1, 1)

    if (q == "'") {
      if (c == "'") q = ""; else word = word c
      i++; continue
    }
    if (q == "\"") {
      if (c == "\\" && index("\"$`\\\n", nx) > 0) { if (nx != "\n") word = word nx; i += 2; continue }
      # $( внутри двойных кавычек исполняется — разбираем как отдельную команду
      if (c == "$" && nx == "(") { flush_seg(); ret++; q = ""; i += 2; continue }
      if (c == "\"") q = ""; else word = word c
      i++; continue
    }

    # Вне кавычек.
    if (c == "\\") {
      if (nx == "\n") { i += 2; continue }
      word = word nx; inword = 1; i += 2; continue
    }
    if (c == "'" || c == "\"") { q = c; inword = 1; i++; continue }
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
    if (c == "$" && nx == "(") { flush_seg(); i += 2; continue }
    if (c == "<" && nx == "<" && substr(src, i + 2, 1) != "<") {
      # heredoc: запомнить метку, тело пропустить после конца строки
      flush_word()
      j = i + 2; dash = 0
      if (substr(src, j, 1) == "-") { dash = 1; j++ }
      while (substr(src, j, 1) == " " || substr(src, j, 1) == "\t") j++
      qc = substr(src, j, 1); if (qc == "'" || qc == "\"") j++; else qc = ""
      tag = ""
      while (j <= n && substr(src, j, 1) ~ /[A-Za-z0-9_]/) { tag = tag substr(src, j, 1); j++ }
      if (qc != "" && substr(src, j, 1) == qc) j++
      if (tag != "") { ntags++; tags[ntags] = tag; dashes[ntags] = dash }
      i = j; continue
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
    if (c == ")" && ret > 0) { flush_seg(); ret--; q = "\""; inword = 1; i++; continue }
    if (index(";&|(){}`", c) > 0) { flush_seg(); i++; continue }

    word = word c; inword = 1; i++
  }
  flush_seg()
}
