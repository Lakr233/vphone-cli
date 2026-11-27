# Frida через devicectl + Gadget: состояние на момент остановки

Дата: 2026-11-26. Этап 21, родитель — `thr_6vcmjuesnu` («Создание jailbreak для iPhone 17 Pro»).

**Задача не выполнена.** Этап оборвался на чтении документации и исходников: итогового ответа в чате нет. На устройства ничего не устанавливалось, ничего с них не запускалось, VM Basil не трогалась. Всё сделанное — команды на этом Mac, перечисленные ниже.

## Что было в задаче

1. Приложение (UIKit, Debug, `get-task-allow`, Developer Mode) запускается с Mac командой

   ```sh
   xcrun devicectl device process launch --device <id> --console -e '{"DYLD_INSERT_LIBRARIES":"@executable_path/libgadget.dylib"}' <bundle-id>
   ```

2. Есть ли в `xcrun devicectl` (Xcode 26.6) проброс TCP-порта; если нет — альтернативы (`iproxy`, `pymobiledevice3`, туннель CoreDevice) и команды для USB и сети.
3. Как подключиться клиентом Frida к гаджету после проброса: установка, подключение, строка JS для проверки.

Условие задачи: ничего не устанавливать и не запускать. Устройство, UDID, bundle ID, версия и расположение `libgadget.dylib` в постановке не указаны.

## Что сделано (только на Mac, только чтение)

| Шаг | Команда | Результат |
|---|---|---|
| Версия devicectl, подкоманды | `xcrun devicectl --version`, `devicectl device --help`, `devicectl device process --help`, `devicectl device process launch --help` | `518.33`; подкоманды `device`: `copy`, `info`, `install`, `notification`, `orientation`, `process`, `reboot`, `sysdiagnose`, `uninstall` |
| Что установлено | `which frida frida-ls-devices pymobiledevice3 idevice_id iproxy`; `brew list --versions` | есть: `iproxy` 2.1.1, `idevice_id` (libimobiledevice 1.4.0, libusbmuxd 2.1.1). Нет: `frida`, `pymobiledevice3` |
| Список устройств | `xcrun devicectl list devices`, `idevice_id -l` | таблица ниже |
| Опции `iproxy` | `iproxy --help`, исходник `libusbmuxd/tools/iproxy.c` на GitHub (master) | `-u/--udid`, `-n/--network`, `-l/--local`, `-s/--source`; формат `LOCAL:DEVICE`; `-n` выбирает устройство с `CONNECTION_TYPE_NETWORK` |
| Актуальный Frida | PyPI JSON API, GitHub Releases API | `frida` 17.27.6 (релиз 2026-11-25). Есть `frida-gadget-17.27.6-ios-universal.dylib.xz` и колёса `cp37-abi3` для macOS (arm64) |
| Python API | колесо `frida-17.27.6` скачано в `/tmp` и распаковано, прочитан `frida/__init__.py` | `get_device_manager().add_remote_device(address, **kwargs)`, `Device.attach(target)`, `Session.create_script(source)` — существуют |
| CLI Frida | `frida_tools/application.py` и `frida_tools/repl.py` (main на GitHub) | `-H/--host` → `add_remote_device(host)`; `-e/--eval`, `-q`, `-t/--timeout`, `-l/--load` |
| `pymobiledevice3 usbmux forward` | `pymobiledevice3/cli/usbmux.py` (master) | позиционные `src_port dst_port`; опции `--usbmux`, `--serial/--udid`, `--host` (по умолчанию `127.0.0.1`), `--daemonize` |

## Что найдено по существу

**В `devicectl` 518.33 проброса порта нет**: подкоманды `device` перечислены в таблице, ни одна не открывает TCP-порт. Это вывод из списка подкоманд; скрытые опции не искались.

**Работающая цепочка (по документации, не прогнана):**

1. `iproxy -u <UDID> 27043:27042` — порт гаджета по умолчанию на устройстве `27042`, на Mac слушается `27043` (чтобы не совпасть с локальным `frida-server`, если он когда-нибудь появится).
2. Запуск приложения командой из постановки. `--console` по `--help` «ждёт выхода приложения», значит терминал занят до закрытия приложения.
3. `frida -H 127.0.0.1:27043 -n Gadget`.

По сети: `iproxy -n` выбирает устройство, которое usbmuxd видит с типом соединения «network». Включено ли такое сопряжение на этих iPhone — не проверялось (`idevice_id -n` не выполнялась).

Туннель `pymobiledevice3 remote tunneld` (CoreDevice, iOS 17+): даёт маршрутизируемый адрес устройства и нужен sudo; команды для него в этом этапе не сверялись — в прошлом ответе треда они были написаны по памяти и с ошибками.

## Устройства (вывод `xcrun devicectl list devices` на момент этапа)

| Имя | Identifier (CoreDevice) | UDID | iOS | Подключение |
|---|---|---|---|---|
| Basil | `75DC7316-88D8-5325-BACA-BEE1C1052302` | `0000FE01-040ADA118D900AB2` | 27.2 | wired |
| iPhone (17 Pro Max) | `EB205573-B173-5937-B2B1-031211E2944F` | `00008150-001014840138401C` | 27.2.1 | wired |
| iPhone 13 | `4A8A1186-3B54-5E76-95C0-3E47590416B9` | `00008110-00096C803C31801E` | 26.5.2 | localNetwork |
| iPhone (Евгения) (2) | `1747203B-5F35-5AB9-A0B4-8649A08FC874` | `00008150-00082C693A78401C` | 26.6.2 | localNetwork |
| Avocado | `8F9F654A-C0E6-564F-83DC-2FE5DF9639E2` | `0000FE01-59BBF986E8547148` | 27.2 | unavailable |

`idevice_id -l` на этот момент вернул два UDID: `0000FE01-040ADA118D900AB2` (Basil) и `00008150-001014840138401C` (17 Pro Max). Это usbmuxd, то есть доступ по USB для `iproxy` без `-n`.

## Что НЕ сделано

- **Ничего не установлено**: ни `brew install frida`, ни `pip install frida frida-tools`, ни `pymobiledevice3`.
- **Ничего не загружено ни на одно устройство**: ни `libgadget.dylib` на Basil / 17 Pro Max / iPhone 13, ни приложения. Существует ли уже `libgadget.dylib` в контейнере какого-то приложения — неизвестно, не смотрели.
- Гаджет не скачан даже на Mac (только проверено наличие файла в релизе по API и скачано колесо Python-модуля для чтения исходника).
- `iproxy` не запускался, порт не пробрасывался.
- Приложение с `DYLD_INSERT_LIBRARIES` не запускалось.
- `frida` CLI и Python-модуль не запускались: подключение к гаджету, `Process.id`, `ObjC.available` не проверены.
- Не проверено: работает ли `DYLD_INSERT_LIBRARIES` через `-e` у `devicectl` для этого приложения (по документации должно, для Debug-сборки с `get-task-allow`; на iOS 26/27 не подтверждено).
- Не проверено: режим взаимодействия гаджета (listen по умолчанию, адрес `127.0.0.1:27042`) — взят из документации Frida, исходники `frida-core` в этом этапе не читались (URL `lib/frida-core.vala` дал 404, структура репозитория другая).
- Не проверено: имя процесса для attach. Для remote-устройства у Frida один процесс с именем `Gadget`; по документации attach идёт по этому имени, либо `d.attach(0)`.

## Что осталось недоделанным

1. Сверить версию: какой `libgadget.dylib` лежит в приложении (или какой будем класть) ↔ какую версию ставит brew/pip на Mac. `17.27.6` — версия на 2026-11-26, к моменту повтора может измениться.
2. `iproxy -u <UDID> 27043:27042` (USB), проверить, что `nc -z 127.0.0.1 27043` connect проходит (это подтвердит, что гаджет слушает).
3. Запуск приложения с гаджетом, затем `frida -H 127.0.0.1:27043 -n Gadget -q -e '...'`.
4. Сеть: проверить `idevice_id -n`; если устройство видно — `iproxy -n -u <UDID> 27043:27042`.
5. Если usbmux по сети не видит устройство — разбирать `pymobiledevice3 remote tunneld` по его документации и `--help`, не по памяти.

## Артефакты

- `tools/21_frida_gadget_attach.sh` — последовательность команд с комментариями. **Не запускалась.**
- `/tmp/frida_whl/` (166 МБ, распакованное колесо `frida-17.27.6`), `/tmp/frida.json`, `/tmp/devs.json` — временные, для воспроизведения не нужны, можно удалить.

## Про прошлый ответ треда

Финальный ответ не был сформирован: вывод оборвался серией повреждённых блоков «Подключение: …» с искажёнными командами (в том числе `frida -H 47.0.0.1:27043 -n Gadget` и подобные). Ни одну команду оттуда не использовать. Рабочие команды — в `tools/21_frida_gadget_attach.sh`, и они пока не проверены на устройстве.
