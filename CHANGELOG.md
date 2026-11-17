# Changelog / История изменений

## Unreleased / Следующее обновление

### Русский

- Вкладка «Агенты» объединяет Claude и локальные чаты Codex: состояние, последнее действие, заполнение контекста и переход в чат. Для Codex не нужны хуки или MCP. Сообщения и подтверждения разрешений пока обрабатываются в самом Codex.
- Исправлено закрытие приложения через несколько секунд после запуска, если у одного чата Codex несколько файлов истории. Повторяющиеся ID больше не вызывают падение; карточка показывает самое свежее состояние.
- Добавлены проверки повторных файлов истории, обновления состояния и уникальности ID чатов.

### English

- The Agents tab combines Claude and local Codex chats: status, latest action, context usage and a link to the chat. Codex requires no hooks or MCP setup. Messages and permission approvals are currently handled in Codex itself.
- Fixed the app quitting a few seconds after launch when several log files belonged to the same Codex chat. Duplicate IDs no longer cause a crash; the card shows the latest state.
- Added regression checks for duplicate log files, state updates and unique chat IDs.
