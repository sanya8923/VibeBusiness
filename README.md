# Подарки Vibe Business

Плагины и скиллы для Claude Code и готовые воркфлоу n8n. Всё, что здесь лежит, я сам
использую в работе — забирай и пользуйся.

## Плагины Claude Code

Подключи витрину один раз — дальше любой плагин ставится одной командой:

```
/plugin marketplace add sanya8923/VibeBusiness
```

| Плагин | Что делает | Установка |
|---|---|---|
| [github-tasks](plugins/github-tasks/) | Задачи проекта на GitHub: несколько сессий Claude берут задачи без драки, каждая работает в своей ветке, работу принимает отдельный агент-приёмщик, задача закрывается слиянием PR | `/plugin install github-tasks@vibe-business` |

## Скиллы Claude Code

Скопируй папку скилла в `~/.claude/skills/` или в `.claude/skills/` проекта.

| Скилл | Что делает |
|---|---|
| [handoff](skills/handoff/) | Сохраняет состояние рабочей сессии, чтобы следующая продолжила без потери контекста |
| [research-buy](skills/research-buy/) | Подбирает оборудование под задачу и привязывает к покупке в твоём городе: готовая HTML-страница со сборками и ссылками на магазины |

## Воркфлоу n8n

Скачай JSON и импортируй в n8n: открой новый воркфлоу, в меню «…» справа вверху выбери «Import from File…» (импорт из файла). Ещё можно скопировать содержимое JSON и вставить прямо на холст через Cmd+V или Ctrl+V.

| Воркфлоу | Что делает |
|---|---|
| [error-trigger-selfhealing](workflows/error-trigger-selfhealing/) | Ловит ошибки воркфлоу через Error Trigger и разбирает их с помощью AI |
| [error_workflow_with_n8n_doctor.json](workflows/error_workflow_with_n8n_doctor.json) | Обработчик ошибок для связки с n8n Doctor |
| [telegram_payment.json](workflows/telegram_payment.json) | Оплата в Telegram-боте |
| [GazelleType.json](workflows/GazelleType.json) | Пример из ролика на канале |
| [Barbershop Ai Agent + MCP Server](workflows/Barbershop%20Ai%20Agent%20+%20MCP%20Server) | AI-агент записи в барбершоп с MCP-сервером |

Подробнее про воркфлоу — в [Vibe Business.md](Vibe%20Business.md).

## Где следить

- [Telegram-канал @vibe_bus](https://t.me/vibe_bus) — разборы и новые подарки к каждому ролику
- [YouTube @vibe_business](https://www.youtube.com/@vibe_business)
- [Чат](https://t.me/vibe_bus_chat) — вопросы и обсуждения

Лицензия — [MIT](LICENSE).
