# S2A Claude X-Ray 0.9.0

Использование Claude Code в реальном времени и по истории, API‑эквивалент для подписки Pro/Max, Live‑трасса и подсказки по оптимизации. Для macOS 14+ (Apple Silicon и Intel), Windows 10 и 11 (x64 и ARM64) и iPad (iPadOS 17+, в том числе iPad mini).

## Что нового

- **X-Ray для iPad.** Нативное приложение для iPad, в том числе iPad mini, со всеми экранами: «Сейчас» с лимитами аккаунта, Live‑трасса со всеми вкладками, обзор, сессии, проекты, модели, оптимизация и отчёты (PDF, Markdown и CSV через «Поделиться»). Логи оно берёт с ваших компьютеров и, пока открыто, каждые 3 секунды догружает новые строки. Можно подключить Mac и ПК сразу. Ставится из Xcode со своим Apple ID: `iPad/XRay.xcodeproj`, пошагово в README.
- **«Настройки → iPad» на Mac и Windows.** Переключатель «Разрешить iPad читать логи», адрес из Tailscale и QR‑код: камера iPad открывает его в X-Ray, и iPad подключается. Доступ только на чтение и со своим токеном, отдельным от токена облачных сессий. По умолчанию выключен.

**English.** X-Ray now runs on the iPad, including the iPad mini, with every screen of the Mac app. It reads the logs of your Mac and Windows computers, read-only, through the same tunnel as cloud sessions, and fetches new lines every 3 seconds while open. Turn it on in Settings → iPad on the computer and scan the QR code with the iPad's camera. Install it from Xcode with your Apple ID (`iPad/XRay.xcodeproj`, see the README).

**Deutsch.** X-Ray läuft jetzt auch auf dem iPad, einschließlich iPad mini, mit allen Bildschirmen der Mac-App. Es liest die Logs Ihrer Mac- und Windows-Computer schreibgeschützt über denselben Tunnel wie die Cloud-Sitzungen und holt neue Zeilen alle 3 Sekunden, solange es geöffnet ist. Schalten Sie es auf dem Computer unter „Einstellungen → iPad“ ein und scannen Sie den QR-Code mit der iPad-Kamera. Installation über Xcode mit Ihrer Apple-ID (`iPad/XRay.xcodeproj`, siehe README).

### Из 0.8.1

- **Честный статус на экране «Сейчас» и в Live‑трассе.** Если после промпта или ответа модели три минуты нет новых событий, X‑Ray пишет «Нет новых событий» и сколько прошло, а не «Думает»: модель может ещё отвечать, а лог облачной сессии мог ещё не дойти. Раньше статус «Думает» держался до 10 минут.
- **Ответы облачных сессий доходят без задержек.** Если отправка лога не удалась, хук облачной сессии сам повторяет её через 5, 15, 30 и 60 секунд, а не ждёт следующего шага сессии (после конца хода он может быть через много минут). После конца хода он ещё раз проверяет лог: Claude Code дописывает конец хода сразу после хука. Ошибки отправки пишутся в `/tmp/xray-push/errors.log` облачной сессии. Новый хук облачная среда ставит в новые сессии сама.

### Из 0.8.0

- **Язык интерфейса: русский, English, Deutsch** («Настройки → Язык и оформление»): экраны, подсказки, Live‑трасса, отчёты, меню и строка статуса; даты, единицы и множественное число по правилам языка. «Как в системе» берёт язык macOS или Windows.
- **Облачные сессии на нескольких компьютерах** (Mac и Windows): лог уходит сразу на все, выключенный компьютер не задерживает остальные.

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

Скачайте и запустите [`S2A-Claude-X-Ray-Setup.exe`](https://github.com/x-daemon/claude-x-ray/releases/latest/download/S2A-Claude-X-Ray-Setup.exe) (x64). Для ARM64 — `S2A-Claude-X-Ray-Setup-<версия>-arm64.exe`; без установки — `S2A-Claude-X-Ray-<версия>-win-x64.zip` или `-win-arm64.zip`. Или в PowerShell:

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

Или вручную: откройте `S2A-Claude-X-Ray-<версия>.dmg` и перетащите **S2A Claude X-Ray** в «Программы». Сборка подписана ad‑hoc, без Apple Developer ID, поэтому при первом запуске нажмите «Готово», затем «Системные настройки → Конфиденциальность и безопасность → Всё равно открыть», или снимите карантин:

```bash
xattr -dr com.apple.quarantine "/Applications/S2A Claude X-Ray.app"
```

Приложение читает `~/.claude/projects` (или `$CLAUDE_CONFIG_DIR/projects`) и никуда не отправляет данные. Вне своей папки оно меняет только `statusLine` в `~/.claude/settings.json`, и только после нажатия «Подключить» (копия прежнего файла: `settings.json.xray-backup`). Проверить целостность: `shasum -a 256 -c SHA256SUMS.txt`.

## Установка на iPad

Нужен Mac с Xcode 15 или новее. Скачайте исходники (`git clone https://github.com/x-daemon/claude-x-ray.git` или «Source code (zip)» ниже), откройте `iPad/XRay.xcodeproj`, выберите свой Apple ID в **Signing & Capabilities → Team**, подключите iPad кабелем (на iPad включите «Режим разработчика») и нажмите ▶︎. Затем в X-Ray на Mac или Windows откройте «Настройки → iPad», включите доступ и наведите камеру iPad на QR‑код. Подробно — в README, раздел «X-Ray для iPad».
