# Завершение пробника по SIGTERM через `devicectl … --console`: состояние на момент остановки

Дата: 2026-11-26. Тред `thr_gtdeneyvue` («Устранение завершения iOS-приложения по SIGTERM»), родитель — `thr_thsmcm7sgi`.

**Причина не найдена.** Этап оборвался после одного ответа: на устройствах ничего не запускалось, логи с них не снимались. Всё ниже — либо результаты команд `--help` на этом Mac, либо непроверенные предположения.

## Что было в задаче

Диагностическое приложение (UIKit, Objective-C, Debug-сборка, development-подпись с `get-task-allow`, Developer Mode включён) запускается командой

```sh
xcrun devicectl device process launch --device <id> --terminate-existing --console <bundle-id>
```

Оно печатает строки через NSLog и завершается примерно через 1 секунду; devicectl печатает `App terminated due to signal 15`. Экран разблокирован, приложение на переднем плане. Устройства: iPhone 13 (26.5.2), iPhone 17 Pro Max (27.2.1); Xcode 26.6.

Какое именно приложение и что оно делало в момент завершения — в постановке не указано. Исходник к нам не прилагался. Bundle ID, имя процесса и вывод запуска (`--verbose`) не сохранились.

## Что проверено (только на Mac, к устройствам не обращались)

| Что | Команда | Результат |
|---|---|---|
| Версия devicectl | `xcrun devicectl --version` | `518.33`; `xcodebuild -version` — Xcode 26.6 (17F113) |
| Опции запуска | `xcrun devicectl device process launch --help` | текст `--help` сохранён в `tools/19_devicectl_launch_help.txt` |
| Подкоманды process | `xcrun devicectl device process --help` | `launch`, `resume`, `sendMemoryWarning`, `signal`, `suspend`, `terminate` |
| Инструменты чтения логов | `which`, `--version` | `idevicesyslog` 1.4.0 и `idevicecrashreport` установлены (`/opt/homebrew/bin`), `pymobiledevice3` — нет |
| Опции `idevicesyslog` | `idevicesyslog --help` | `-u`, `-p`, `-m`, `-e`, `-o`, `--syslog-relay`; список в `tools/19_sigterm_cmds.sh` |
| Опции `idevicecrashreport` | `idevicecrashreport --help` | `-u`, `-k` (не удалять с устройства), `-e` (распаковать `.crash`), `-f` |
| Опции `log collect` | `log collect --help` | `--device-udid`, `--device-name`, `--last`, `--output` |
| Подключённые устройства | `idevice_id -l` | два UDID (вывод в файл не переносился) |
| Опция `log stream` | `log stream --help` | строк `--device*` в `--help` не найдено; стримить с устройства через `log` не проверено |

Формулировка про `--console` (дословно из `--help`): «Attaches the application to the console and waits for it to exit. devicectl will wait for the app to terminate. Catchable signals sent to devicectl are forwarded to the app. If the app is not already running, its standard streams will be connected to devicectl's standard streams.»

## Причины по сигналам: что отсечено, а что нет

| Кандидат | Состояние |
|---|---|
|Jetsam (память) | отсечён по типу сигнала: kill по памяти даёт SIGKILL (9), не 15. Отчёт Jetsam не снимался. |
| Watchdog | аналогично: обычно SIGKILL (9), плюс отчёт `watchdog`/`.ips`. Отчёт не снимался. |
| Явный `devicectl device process terminate` / `signal` | отсечён: такие команды в этом этапе не выполнялись. |
| Сам devicectl или `--console`-сессия как источник SIGTERM | **не отсечён и не подтверждён**. В `--help` описана только пересылка сигналов, полученных devicectl, приложению. Кто реально послал сигнал — не установлено. |
| FrontBoard / RunningBoard (сбой запуска, уход в фон) | **не отсечён и не подтверждён**. |
| Завершение самим приложением (`exit()`, `abort()`) | не проверялось: исходник к нам не попал. |

«FrontBoard — наиболее вероятный отправитель» в прошлом ответе — предположение без доказательств, не переносить как факт.

## Что не проверено

- Любой запуск на iPhone 13 / 17 Pro Max, любое чтение логов с устройств: ни `idevicesyslog`, ни `log collect`, ни `idevicecrashreport` не выполнялись.
- Повторный запуск с `--verbose -l <файл>`: не выполнялся.
- Запуск без `--console`: не выполнялся, эффект неизвестен.
- `log stream --device` с Mac: поддержка в этой версии `log` не подтверждена.
- Код из прошлого ответа (`beginBackgroundTaskWithExpirationHandler:`, `idleTimerDisabled`) не компилировался и на устройстве не запускался. На переднем плане он срок жизни не продлевает — это утверждение по документации Apple, не по измерению.

## Что осталось недоделанным

1. Запустить с `--verbose -l Research/jb_experiments/19_sigterm_launch.log` и сохранить полный вывод.
2. Снять лог на момент завершения (`tools/19_sigterm_cmds.sh`, шаги 1–2) и найти отправителя и причину: строки с bundle ID, `signal 15`, `termination`, `RBSTerminate` / `FBSOpenApplication`.
3. Сравнить время жизни с `--console` и без него.
4. Прочитать исходник самого приложения (не было в постановке): что происходит через ~1 с после запуска и есть ли `exit()`/`abort()`.
5. Если причина не найдётся по логу — снять архив (`log collect --device-udid`) и отчёты Jetsam/watchdog (`idevicecrashreport -k -e`).

Файлы: `tools/19_devicectl_launch_help.txt` (дословный `--help`), `tools/19_sigterm_cmds.sh` (команды съёма логов, не запускались), `tools/19_bgtask_snippet.m` (фрагмент Objective-C из прошлого ответа, не компилировался).

## Про прошлый ответ треда

Финальный ответ содержал вставки постороннего текста и ссылки на сторонние сайты в последнем абзаце. Считать его ненадёжным: всё, что здесь отмечено как непроверенное, взято из него и не подтверждено.
