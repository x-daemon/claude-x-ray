# S2A Claude X-Ray 0.8.0

Использование Claude Code в реальном времени и по истории, API‑эквивалент для подписки Pro/Max, Live‑трасса и подсказки по оптимизации. Для macOS 14+ (Apple Silicon и Intel) и Windows 10 и 11 (x64 и ARM64).

## Что нового

- **Язык интерфейса: русский, English, Deutsch.** «Настройки → Язык и оформление». Переведено всё: экраны, подсказки по оптимизации, разбор сессий в Live‑трассе, отчёты (PDF, Markdown, CSV), меню в строке меню и в трее, строка статуса Claude Code; даты, единицы и множественное число — по правилам языка. «Как в системе» берёт язык macOS или Windows. Язык меняется сразу, без перезапуска. Кто пользовался X‑Ray раньше, остаётся на русском, пока не выберет другой язык.
- **Облачные сессии на нескольких компьютерах.** Облачная среда отправляет лог сразу на все подключённые компьютеры (Mac и Windows): выключенный компьютер не задерживает остальные и догоняет, когда снова в сети. Строка лога длиннее 4 МБ больше не останавливает отправку.

**English.** The interface is now available in English and German as well as Russian: Settings → Language & appearance. Everything is translated: screens, optimization tips, the Live trace, reports (PDF, Markdown, CSV), the menu bar and tray menus and the Claude Code status line, with dates, units and plurals that follow the language. “System” uses the macOS or Windows language. People who used X‑Ray before keep Russian until they pick another language.

**Deutsch.** Die Oberfläche gibt es jetzt neben Russisch auch auf Englisch und Deutsch: „Einstellungen → Sprache & Darstellung“. Übersetzt ist alles: Ansichten, Optimierungshinweise, der Live‑Trace, Berichte (PDF, Markdown, CSV), die Menüs in Menüleiste und Infobereich und die Statuszeile von Claude Code; Datum, Einheiten und Mehrzahl folgen der Sprache. „System“ nimmt die Sprache von macOS oder Windows. Wer X‑Ray schon benutzt hat, behält Russisch, bis eine andere Sprache gewählt wird.

### Из 0.7.0

- **LLM‑запросы и цикл агента.** В Live‑трассе каждый вызов модели отдельной карточкой: причина остановки, состав контекста, почему не сработал кэш, какие размышления API убрало из истории, аргументы, которые сгенерировала модель, и что Claude Code реально выполнил; для каждого хода — цепочка «мысль → действие → результат». В «Оптимизации» и отчёте — блок «Запросы к модели».

### Из 0.6.0

- **Версия для Windows.** То же приложение с теми же экранами, тема S2A, значок в области уведомлений, строка статуса Claude Code, импорт логов и приём логов облачных сессий.

### Из 0.5.0

- **Графические отчёты.** Экран «Отчёты» показывает отчёт с графиками: обложку с итогом периода и сравнением с прошлым периодом, ключевые показатели с изменениями, расход по дням и моделям, из чего складывается стоимость, рейтинги проектов и самых дорогих сессий, долю кэша и размер контекста по дням, тепловую карту «день × час» и рекомендации. «Сохранить PDF…» (⌘S) сохраняет его в PDF; данные выгружаются в Markdown и CSV.

### Из 0.4.0

- **Облачные сессии вживую.** «Настройки → Облако» включает приём логов облачных сессий. Через туннель к Mac (например, Tailscale Funnel) каждая облачная сессия после каждого шага присылает сюда свой лог: контекст, токены каждого запроса, размышления, промпты, ответы и инструменты. Облачная среда настраивается один раз: Claude делает это по просьбе «Подключи X-Ray: <адрес туннеля>».

### Из 0.3.1

- Полоски лимитов, окна и контекста сохраняют цвет (жёлтый от 70 %, красный от 90 %), даже когда окно X-Ray неактивно: раньше системный индикатор становился серым.

### Из 0.3.0

- **Реальные лимиты всего аккаунта.** Процент 5‑часового и недельного лимита с временем сброса, как его сообщает Claude Code. Цифры учитывают чаты, облачные сессии, Cowork и сессии на этом Mac. Они видны на экране «Сейчас» и в строке меню. Подключение: «Настройки → Лимиты аккаунта → Подключить», после этого цифры обновляются при каждом ответе Claude Code в Терминале на этом Mac.
- **Импорт облачных сессий.** Перетащите лог сессии (`.jsonl` или `.zip`) в окно X-Ray или выберите «Файл → Импортировать лог сессии…» (⌘I). Облачная сессия появится со всеми токенами, инструментами и стоимостью.
- Пустые экраны объясняют, почему они пусты: какие папки X-Ray читает, сколько в них логов, когда была последняя запись и почему облачных сессий там нет.
- График «Активность за 3 часа» больше не рисует ряд чёрточек, когда запросов не было.

## Установка на Windows

Скачайте и запустите [`S2A-Claude-X-Ray-Setup.exe`](https://github.com/x-daemon/claude-x-ray/releases/latest/download/S2A-Claude-X-Ray-Setup.exe) (x64). Для ARM64 — `S2A-Claude-X-Ray-Setup-0.7.0-arm64.exe`; без установки — `S2A-Claude-X-Ray-0.7.0-win-x64.zip` или `-win-arm64.zip`. Или в PowerShell:

```powershell
Invoke-WebRequest https://github.com/x-daemon/claude-x-ray/releases/latest/download/S2A-Claude-X-Ray-Setup.exe -OutFile "$env:TEMP\S2A-Claude-X-Ray-Setup.exe"; Start-Process "$env:TEMP\S2A-Claude-X-Ray-Setup.exe"
```

Установщик не требует прав администратора. Сборка не подписана сертификатом, поэтому SmartScreen покажет «Система Windows защитила ваш компьютер»: нажмите «Подробнее» → «Выполнить в любом случае». Приложение читает `%USERPROFILE%\.claude\projects` (или `%CLAUDE_CONFIG_DIR%\projects`) и хранит свои данные в `%APPDATA%\S2AClaudeXRay`.

## Установка и обновление на macOS

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

Или вручную: откройте `S2A-Claude-X-Ray-0.7.0.dmg` и перетащите **S2A Claude X-Ray** в «Программы». Сборка подписана ad‑hoc, без Apple Developer ID, поэтому при первом запуске нажмите «Готово», затем «Системные настройки → Конфиденциальность и безопасность → Всё равно открыть», или снимите карантин:

```bash
xattr -dr com.apple.quarantine "/Applications/S2A Claude X-Ray.app"
```

Приложение читает `~/.claude/projects` (или `$CLAUDE_CONFIG_DIR/projects`) и никуда не отправляет данные. Вне своей папки оно меняет только `statusLine` в `~/.claude/settings.json`, и только после нажатия «Подключить» (копия прежнего файла: `settings.json.xray-backup`). Проверить целостность: `shasum -a 256 -c SHA256SUMS.txt`.
