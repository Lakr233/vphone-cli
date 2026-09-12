<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong>🇷🇺Русский</strong> | <strong><a href="./README_pt.md">🇧🇷Português</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

Запуск виртуального iPhone через Apple Virtualization.framework с использованием инфраструктуры исследовательской ВМ PCC.

![poc](docs/demo.jpeg)

## Предварительные требования

**Хост:**

- Apple Silicon
- macOS 15+ (Sequoia)
- Xcode + iOS SDK (кросс-компиляция гостевого демона)
- Ослабление SIP/AMFI для разрешения приватных прав PV=3 с неподписанным бинарником

**Зависимости:**

```
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd
```

## Установка

```
brew install zqxwce/tap/vphone-cli
```

## Сборка

```
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # установка зависимостей, сборка сабмодулей тулчейна, создание Python venv
./scripts/build.sh            # сборка + подпись vphone-cli, сборка .app, кросс-компиляция vphoned

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

## Быстрый старт

Одна команда создаёт ВМ от начала до конца (загрузка → патчинг → DFU-восстановление → установка CFW → первая загрузка):

```
vphone-cli vm create myphone -V jb        # -V / --variant

vphone-cli vm launch myphone
```

## Команды

`vphone-cli vm create` выполняет весь конвейер; отдельные шаги ниже позволяют запускать его вручную или повторять отдельные стадии.

### Управление

```
vphone-cli vm list                         # список ВМ (--json для скриптов)
vphone-cli vm info myphone                  # показать одну ВМ
vphone-cli vm new myphone                   # создать пустой бандл (опции cpu/mem/disk)
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # быстрый APFS-клон, новая идентичность устройства
vphone-cli vm export myphone --out myphone.tzst   # по умолчанию быстрый zstd (--max = xz -9); --out может быть директорией (автоимена <vm>.tzst/.txz); пропускает restore-директорию + staging-файлы
vphone-cli vm import myphone.tzst --name restored
vphone-cli vm rename myphone iphone16
vphone-cli vm delete iphone16
```

### Ручная сборка ВМ (то, что автоматизирует `vm create`)

```
vphone-cli vm new myphone                              # 1. пустой бандл
vphone-cli fw prepare myphone --iphone-version 26.1     # 2. загрузка + объединение IPSW
vphone-cli fw patch myphone --variant jb                # 3. патчинг цепочки загрузки

vphone-cli vm launch myphone --dfu &                    # 4. загрузка в DFU (в фоне)
vphone-cli restore myphone --get-shsh                   #    получить SHSH
vphone-cli restore myphone                              #    DFU-восстановление
vphone-cli vm stop myphone                              #    остановить DFU-загрузку

vphone-cli cfw install myphone --variant jb             # 5. установка CFW (host-mount; запросит sudo)
vphone-cli vm launch myphone                            # 6. первая загрузка
```

Обновление до более новой iOS: укажите `fw prepare` на IPSW: `--iphone-source /path/to.ipsw --cloudos-source /path/to.ipsw`.

## Варианты прошивки

Пять вариантов патчей с нарастающим обходом безопасности — передайте один в `--variant`:

| Вариант | Цепочка загрузки | CFW | Примечания |
|---|---|---|---|
| `less` | 4 патча | 2 фазы | Без патчей — сохраняет включённые митигации iOS |
| `regular` | 42 патча | 10 фаз | Обход AMFI/SSV/Img4/TXM |
| `dev` | 53 патча | 12 фаз | + обход TXM entitlement/debug |
| `jb` | 113 патчей | 14 фаз | + полный jailbreak (Sileo, TrollStore автоустанавливаются при первой загрузке) |
| `exp` | 141 патч | 18 фаз | Надмножество JB + исследовательские патчи anti-VM-detection |

См. [`research/0_binary_patch_comparison.md`](https://./research/0_binary_patch_comparison.md) для разбивки по компонентам.

## Запуск и подключение

- **SSH (jailbreak):** `ssh -p 22222 mobile@<vm-ip>` (пароль `alpine`)
- **SSH (regular/dev):** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

## Расположения

Всё, что создаёт vphone-cli, находится в `~/.vphone/` — вне репозитория и `.app`, чтобы подписанный бандл оставался портативным. Перенаправьте всё дерево через `$VPHONE_ROOT`:

| Путь ↕▾ | Содержимое ↕▾ |
|---|---|
| −`~/.vphone/` | Корень пользовательских данных — переопределите всё расположение через `$VPHONE_ROOT`. |
| −`~/.vphone/VMs/` | Бандлы ВМ — одна директория на ВМ. Это библиотека; переопределяется через `$VPHONE_LIBRARY_ROOT`. |
| −`~/.vphone/ipsws/` | Загруженные IPSW iPhone + cloudOS, кэшируются и переиспользуются между ВМ. |
| −`~/.vphone/tools/` | Кэшированные артефакты APFS seal-volume (`apfs_sealvolume_<version>`), получаемые при `fw prepare`. |
| −`~/.vphone/debs/` | Кэшированные `.deb`-пакеты, которые установка CFW `jb`/`exp` кладёт в гостя (Sileo, apt, …). |
| −`~/.vphone/venv/` | Автоматически созданное окружение Python (см. Python runtime; переопределяется через `$VPHONE_VENV_DIR`). |
⚙

Приоритет: переопределения по элементам (`$VPHONE_LIBRARY_ROOT`, `$VPHONE_VENV_DIR`) имеют больший вес, чем `$VPHONE_ROOT`, который имеет больший вес, чем значение по умолчанию `~/.vphone`. Кэши `ipsws/`, `tools/` и `debs/` всегда располагаются непосредственно под активным корнем.

## Ослабление SIP/AMFI

**Вариант A — полностью отключить SIP, затем отключить AMFI через boot-arg (наиболее разрешительно).**

В Recovery (долгое нажатие питания → Terminal):

```
csrutil disable
csrutil allow-research-guests enable
```

Затем перезагрузитесь в macOS и установите boot-arg AMFI (требует полностью отключённого SIP, чтобы вступить в силу):

```
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # перезагрузка после
```

**Вариант B — оставить SIP включённым (ослабленным только для отладки), затем добавить бинарник в allowlist через amfidont** (оставляет AMFI включённым на уровне системы).

В Recovery:

```
csrutil enable --without debug
csrutil allow-research-guests enable
```

Затем перезагрузитесь в macOS и выполните:

```
vphone-amfidont         # .build/vphone-cli.app/Contents/Resources/vphone-amfidont для локальных сборок
```

## Протестированные окружения

| Хост ↕▾ | iPhone ↕▾ | CloudOS ↕▾ |
|---|---|---|
| −Mac16,11 27.0b2 | `17,3_18.6.2_22G100` | `26.1-23B85` |
| −Mac16,8 26.5.1 | `17,3_26.0_23A341` | `26.1-23B85` |
| −Mac16,8 26.5.1 | `17,3_26.0.1_23A355` | `26.1-23B85` |
| −Mac16,12 26.3 | `17,3_26.1_23B85` | `26.1-23B85` |
| −Mac16,12 26.3 | `17,3_26.3_23D127` | `26.1-23B85` |
| −Mac16,12 26.3 | `17,3_26.3_23D127` | `26.3-23D128` |
| −Mac16,12 26.3 | `17,3_26.3.1_23D8133` | `26.3-23D128` |
| −Mac16,11 26.2 | `17,3_26.4_23E246` | `26.4-23E5207q` |
| −Mac16,11 26.2 | `17,3_26.5_23F77` | `26.4-23E5207q` |
| −Mac16,11 27.0b2 | `17,3_26.5.2_23F84` | `26.4-23E5207q` |
| −Mac16,6 26.4.1 | `17,3_26.6_23G71` | `26.4-23E5207q` |
| −Mac16,11 27.0b2 | `17,3_26.6.1_23G83` | `26.4-23E5207q` |
| −Mac16,11 27.0b2 | `17,3_27.0_24A5380h` | `26.4-23E5207q` |
| −Mac16,6 26.4.1 | `17,3_27.0_24A5390f` | `26.4-23E5207q` |
| −Mac16,6 26.6.1 | `17,3_27.0_24A5408d` | `26.4-23E5207q` |
| −Mac16,11 27.0b2 | `17,3_27.0_24A5418b` | `26.4-23E5207q` |
| −Mac16,11 27.0b2 | `17,3_27.0_24A5424a` | `26.4-23E5207q` |
| −Mac16,11 27.0b2 | `17,3_27.0_24A5430a` | `26.4-23E5207q` |
⚙

## FAQ

**`zsh: killed ./vphone-cli`** — ограничения AMFI/debug не обойдены; см. Предварительные требования (`amfi_get_out_of_my_way=1` или `amfidont`).

**`Virtualization is not available on this hardware`** — ваш Mac сам является ВМ; загрузка гостя PV=3 не может быть вложенной. Используйте невложенный хост macOS 15+.

**Застряли на "Press home to continue"** — подключитесь через VNC и щёлкните правой кнопкой (клик двумя пальцами), чтобы смоделировать кнопку Home.

**Системные приложения не устанавливаются** — при настройке iOS не выбирайте Японию или ЕС в качестве региона (дополнительные регуляторные проверки, которые ВМ не может пройти); выберите, например, США.

**Приложение падает при запуске с `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`** — перепатчите с `vphone-cli fw patch <name> --variant <v> --force-exc-guard`, затем переустановите/восстановите ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). Всегда включено для баз iOS 18.

**Установка `.ipa`/`.tipa`** — используйте меню Install работающей ВМ (drag-drop или выбор файла).

**`cfw install` зависает при переподписи системного бинарника (например, `Campo`), память растёт бесконтрольно** — известный баг в `ldid-procursus` вплоть до `2.1.5-procursus7` (текущий Homebrew `stable`): `bytes(uint64_t)` вызывает `__builtin_clzll(0)` без защиты от нуля, что является неопределённым поведением, и в этой сборке приводит к длине `0`, которая вызывает underflow счётчика цикла без знака — `ldid` крутится, записывая по одному байту в растущий буфер, вместо завершения. Срабатывает на *любом* plist прав, содержащем целочисленное значение ровно `0` (некоторые реальные системные бинарники Apple имеют такие). Исправлено в upstream, но ещё не в тегированном релизе; пересоберите из исходников: `brew install --HEAD ldid-procursus && brew link --overwrite ldid-procursus`. Сначала убейте зависший процесс `ldid` (`sudo kill -9 <pid>`), если уже столкнулись с этим.

## Автоматизация

`vphone-cli` предоставляет сокет управления хостом (`<bundle>/vphone.sock`) для программного управления — скриншоты, касания, свайпы, аппаратные кнопки, буфер обмена — каждое действие возвращает встроенный скриншот для AI-driven E2E-тестирования. См. [vphone-mcp](https://github.com/pluginslab/vphone-mcp) для MCP-сервера, оборачивающего его.

## Благодарности

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
