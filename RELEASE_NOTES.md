# S2A Claude X-Ray 0.2.2

Нативное приложение для macOS 14+ (Apple Silicon и Intel): использование Claude Code в реальном времени и по истории, API‑эквивалент для подписки Pro/Max, Live‑трасса и подсказки по оптимизации.

## Что нового

- График «Активность за 3 часа» больше не рисует ряд чёрточек, когда запросов не было: вместо этого пишет «За последние 3 часа запросов не было».

### Из 0.2.1

- **Пустой экран объясняет, почему он пуст.** Если на этом Mac нет свежей активности, Live‑трасса и экран «Сейчас» показывают, какие папки X-Ray читает, сколько в них логов и когда Claude Code в последний раз писал лог. Папку можно открыть в Finder, пересканировать или заменить в настройках.
- **Облачные сессии.** Сессии в облаке (claude.ai/code, мобильное приложение Claude, облачная среда в Claude Desktop) выполняются на серверах Anthropic, и их логи на Mac не попадают. Теперь приложение говорит об этом прямо и подсказывает, как запустить сессию на Mac, чтобы видеть её вживую: `claude` в Терминале, локальная среда в Claude Desktop или `claude remote-control`.
- В боковой панели видно, когда был записан последний лог.
- В релизе есть `S2A-Claude-X-Ray.zip` без номера версии: ссылка `releases/latest/download/S2A-Claude-X-Ray.zip` всегда ведёт на последнюю версию.

## Установка и обновление

В Терминале (файл, скачанный через `curl`, не получает карантин, поэтому подтверждать запуск не нужно):

```bash
curl -L -o /tmp/S2A-Claude-X-Ray.zip https://github.com/x-daemon/claude-x-ray/releases/latest/download/S2A-Claude-X-Ray.zip
```

```bash
pkill -x S2AClaudeXRay; rm -rf "/Applications/S2A Claude X-Ray.app"; ditto -x -k /tmp/S2A-Claude-X-Ray.zip /Applications
```

```bash
open "/Applications/S2A Claude X-Ray.app"
```

Или вручную: откройте `S2A-Claude-X-Ray-0.2.2.dmg` и перетащите **S2A Claude X-Ray** в «Программы». Сборка подписана ad‑hoc, без Apple Developer ID, поэтому при первом запуске нажмите «Готово», затем «Системные настройки → Конфиденциальность и безопасность → Всё равно открыть», или снимите карантин:

```bash
xattr -dr com.apple.quarantine "/Applications/S2A Claude X-Ray.app"
```

Приложение читает `~/.claude/projects` (или `$CLAUDE_CONFIG_DIR/projects`) и никуда не отправляет данные. Проверить целостность: `shasum -a 256 -c SHA256SUMS.txt`.
