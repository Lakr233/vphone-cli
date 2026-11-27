# Spotify IPA: анализ проверки подписки — состояние

Дата: 2026-11-26. Тред BB «Анализ подписки в Spotify IPA» и его сабтреды.
Смежные заметки: YouTube — `32_youtube_tweak_state.md`, Яндекс Музыка — `28_yandex_music_mod_state.md`
(здесь не дублируются). В `Research/jb_experiments/` каталог не отслеживается
целиком: `git status` показывает `??` на всю папку, номера 27 и 28 у соседних
заметок заняты другими работами — сверяйтесь по имени файла, а не по номеру.

## Что за анализ делался

Цель владельца — собрать сборку Spotify под своим сертификатом разработчика
(wildcard-профиль, идентификаторы сертификата и команды здесь не приводятся):
без рекламы и с признаком Premium в UI.

Хронология по журналу BB (время местное):

| Время | Событие |
| --- | --- |
| 11:56 | На хосте только зашифрованный IPA из App Store (`ipatool`, `cryptid 1`) |
| 14:12 | Установка этого IPA в гостя Basil через `devicectl`: не запускается, FairPlay |
| 15:02 | Установка на iPhone 13: FairPlay проходит, но памяти процесса нет доступа (`get-task-allow=false`, `task_for_pid` закрыт) |
| 15:45 | Irisin (roothide bootstrap) установлен в гостя |
| 15:57 | Установка через `apps.install` падает: signer не парсит зашифрованный Mach-O |
| 15:57–16:13 | Команд от агента нет; владелец работал с экраном гостя вручную |
| 16:13 | В госте другой бандл: другая версия, `encrypted: false`, запущен |

Вывод: расшифрованный бандл появился через **установку из App Store в госте под
Apple ID владельца, сделанную вручную на экране Basil**. Установщик iOS снимает
FairPlay при установке под учётной записью, поэтому на диске `cryptid 0`.
Готовый расшифрованный IPA из сети не использовался.

Дальше по расшифрованному бинарнику (class-dump через `ipsw`, дизассемблер):

- реклама: `-[SPTAdsProductState adsEnabled]`, один байт `eor w0,w0,#1` → `mov w0,#0`;
- Premium в UI: своя dylib `PremiumForce` (чистый `<objc/runtime.h>`, без Orion),
  swizzle геттеров product state по образцу открытого GPL-проекта
  EeveeSpotifyReincarnated; `LC_LOAD_DYLIB` добавляется скриптом;
- переподпись сертификатом разработчика + wildcard-профиль, установка через
  `xcrun devicectl`.

Результат: сборка стоит на iPhone 13 и iPhone 17 Pro Max, процессы запускаются.
Исходники и документация — в отдельном репозитории `freehire-ops`, ветка
`docs/spotify-ios-premium-patches` (не запушена). Серверные функции Premium
(качество, Jam, DJ) клиентским патчем не открываются.

Ошибка, исправленная по ходу: `dylib_command` — заголовок 24 байта (6 полей),
скрипт упаковывал 7 полей, из-за чего имя сдвигалось и `otool` не видел dylib.
Сверено с установленной сборкой: в `__text` единственное отличие — байт патча.

## Что установлено в гостя

- **Spotify** — установлен владельцем из App Store (см. хронологию), на диске
  расшифрованный. Какая именно это копия по размеру/источнику после ручной
  установки — **не проверено**: `apps.info` на момент написания не ответил.
  Зашифрованная копия из `ipatool` (другая версия) была удалена агентом в 15:57.
- **Irisin** (roothide bootstrap), jbroot
  `/var/containers/Bundle/Application/.jbroot-000114514191980C`; `irisin-cli` есть.
- **Procursus 1900 rootless в `/var/jb`** (см. `11_sileo_on_basil.md`): `bash`,
  `dpkg`, `apt`, `grep`, `tail`; Sileo 2.5.1 в `/var/jb/Applications/Sileo.app`.
- Системные `/usr/bin` и `/bin` гостя почти пусты (`/bin`: `df`, `ps`); `curl`,
  `log`, `launchctl` из системы не запускаются. Для Procursus нужен явный путь
  `/var/jb/usr/bin/…`; `proc.run` наследует `PATH` хоста, поэтому в `bash -c`
  сначала `unset PATH`, затем export гостевого.

YouTube и Seven (фитнес, Perigee AB) в гостя ставились агентом через
`guest push` + `apps.install` из зашифрованного IPA: установка проходит, запуск
отклонён, `cryptid 1` остаётся. По журналу агента YouTube и Seven были удалены
(`apps.uninstall {force:true}`) и контейнеры освобождены. **Сверено после
перезапуска**: `apps.info` — app not found для обоих; заметка 32 (`32_youtube_tweak_state.md`), где путь бандла
YouTube приведён как существующий, в этой части устарела: повторная проверка `apps.info`
27.11 — app not found. Это совпадает с
`install-faq.md`: коммерческие приложения, блокируемые FairPlay, не поддерживаются,
обход не предусмотрен.

## Профиль сервисов (проверено, чинить не нужно)

`services.profile {}` → `profile: "none"`, `disabled: []`, `reboot_required: false`.
Store-демоны запущены (`ps` в госте): `appstored`, `itunesstored`,
`appstorecomponentsd`, `akd`, `amsaccountsd`, `appleaccountd`, `storekitd`.
Ремонт по `installd_and_store_download_repair.md` **не применялся** — не требовался.

## Состояние apt/dpkg: ставить пакеты нельзя

`apt-get update` проходит (apt.procurs.us, suite 1900). `apt-get install curl openssh`
не разрешает зависимости:

- `essential` зависит от `org.coolstar.sileo | zebra | installer | cydia | openssh-server`,
  а Sileo установлен в обход dpkg — в базе пакет не записан (`un org.coolstar.sileo`);
- `firmware` — виртуальный пакет, `un`, его требуют `shshd`, `snaputil`;
- `libkrw0` зависит от отсутствующего `libkrw0-plugin`.

`apt-get -f install` начал **удалять** пакеты: упал на pre-removal скрипте `shshd`,
потому что `/var/jb/usr/bin/launchctl` не запускается:

```
dyld: Symbol not found: _launch_active_user_switch
  Referenced from: /private/var/jb/usr/bin/launchctl
  Expected in: /usr/lib/libSystem.B.dylib
Abort trap: 6
dpkg: error processing package shshd (--remove)
```

После этого `dpkg -l` показывает 67 пакетов в состоянии `ii` (столько же было),
Sileo на месте. Состояние стабильное, но **согласованным не является**: повторный
`apt install` / `apt -f install` снова начнёт удалять пакеты.

Что чинится ручной записью: зарегистрировать Sileo в dpkg (установить его `.deb`
через `dpkg -i`, чтобы пакет `org.coolstar.sileo` получил состояние `ii`) и
записать виртуальные `firmware` и `libkrw0-plugin` (`dpkg-record` / `equivs`-подобная
запись). Отдельно — `launchctl` из Procursus несовместим с этой сборкой гостя
(см. `roothide_bootstrap_base.md`); до исправления любые maintainer-скрипты,
вызывающие `launchctl`, будут падать. **Не сделано**: для расшифровки не требуется,
а трогать базу dpkg рискованно.

## На чём остановилось

Страница приложения в App Store гостя отвечает **«Cannot Connect — The page couldn't be loaded. Try again.»**
(`itms-apps://apps.apple.com/app/id544007664`). **Вкладки Today и Apps дают ту же
ошибку**, то есть неработоспособен весь магазин, а не страница приложения.

Что показывает журнал самого App Store (`logs.syslog`, захват 15 с, нажатие Retry):

- `No active store account found` и `Could not provide storeFrontHeader field, no active account`
  — в госте не выполнен вход в Apple ID (лист аккаунта предлагает только Sign In);
- одна сетевая ошибка `Receive failed "Operation timed out"` на QUIC-соединении;
- ни одной ошибки от `appstored` / `itunesstored` (их сообщения скрыты приватностью).

Что проверено и **отброшено** — сеть в порядке, все пробы изнутри гостя:

| Проверка | Инструмент | Результат |
| --- | --- | --- |
| TCP 443 к `apps.apple.com`, `init.itunes.apple.com`, `p25-buy.itunes.apple.com` | `bash /dev/tcp` | open |
| UDP/53 к `1.1.1.1`, `8.8.8.8`, `9.9.9.9` | свой бинарник `udpprobe` | ответ за 10–90 мс — **UDP через NAT работает** |
| QUIC/443 (Version Negotiation) | свой бинарник `quicprobe` | `apps.apple.com`, `www.google.com`, `cloudflare-quic.com` отвечают за 14–15 мс; `p25-buy`, `init.itunes` не отвечают — **то же и с Mac**, эти хосты не говорят по QUIC |
| HTTPS тем же стеком `NSURLSession`, что и App Store | свой бинарник `httpsprobe` | `apps.apple.com` 200 (2.2 МБ), `init.itunes.apple.com/bag.xml` 200, `p25-buy.itunes.apple.com` 200 — **storefront-бэкенд доступен** |

Две мои гипотезы по пути были неверны: «нет входа — единственная причина» и
«NAT не пропускает QUIC/UDP». Обе сняты доказательствами выше.

**Регион — гипотеза проверена и не подтвердилась.** `NSLocale.currentLocale()`
в госте был `en_001` (страна «001»), при `AppleLocale = en_US` в
`.GlobalPreferences.plist`. Сменён на `pt_BR` через `NSUserDefaults` из
`script.eval` (утилит `defaults`/`plutil` в госте нет); системные процессы видят
`pt_BR`, страна `BR`, значение пережило перезагрузку гостя. После перезапуска
App Store и Retry «Cannot Connect» **остался** на всех вкладках. То есть регион
`001` не был причиной (или не единственной).

Basil создан из шаблона с пропущенным Setup Assistant (`setup.skip`,
`--accounts-off`); `setup.status` -> `setup_done: true`.

**Попытка входа в Apple Account (boot Q, вручную на экране гостя).** Basil по
разрешению владельца перезапущен с окном: он был `--headless`, поднят так
джейлбрейк-тредом; команды «прикрепить окно к работающей машине» в
`vphone-launchpad-cli vm` нет, окно даётся только при `vm start`. Владелец
сообщил: «не работает вход». Что видно по фактам:

- `Accounts3.sqlite`: записи `com.apple.account.idms` и `AppleIDAuthentication`
  созданы 26.11 17:54, `active=1`; записи `com.apple.account.iTunesStore` и
  `.sandbox` — только неактивные `local` от 12:51. То есть iCloud-вход записан,
  **аккаунта магазина нет**.
- App Store: `No active store account found`, `Could not provide storeFrontHeader`,
  а также `AMSMescal: Failed to mescal-sign data` (code=301), `Session decoder failed`.
- `amsengagementd`: `Security level check failed to find IDMS account` (сообщение
  соседнего треда, самостоятельно не перепроверял).

Что это значит: магазин не видит аккаунта, хотя запись iCloud есть; подпись
запросов Mescal не формируется. Причина не установлена — либо вход обрывается на
этапе Store, либо устройство (виртуальное, с пропущенной настройкой) не проходит
проверку. Проверка — дойти до конца формы входа и прочитать ошибку на экране;
журнал ошибок формы не отдаёт.

Параллельная проверка той же гипотезы идёт в треде `thr_5jq9qd7hna`: строится
отдельная машина `teststore` (iOS 26.6.2, Setup Assistant не пропущен); сборка
остановлена на нехватке места на диске. Здесь не дублируется.

Профиль сервисов (`none`, ничего не отключено) и Store-демоны (запущены) —
проверено ранее, не причина. TCP 80 — не проверял.

Почему accessibility-дерево пустело до этого: `apps.foreground` после загрузки
гостя отдавал `verified: false`, и `ui.tree` возвращал пусто — даже когда App Store
был запущен. После `apps.launch` с `frontmost_verified: true` дерево читается. Экран
гостя после перезагрузки остаётся запертым: `screen.unlock` его включает, но экран
засыпает за пару минут, и тапы перестают проходить (`Cannot verify the foreground
application for accessibility input`); перед каждой серией тапов нужна разблокировка.

Что пригодилось из скилла репозитория: `ui.describe` (краткое описание экрана
вместе с base64-скриншотом 393×852), `input.type` / `input.paste` (ввод текста),
`ui.tap_element` принимает **плоские** параметры `text` / `identifier` / `role` /
`match` / `index` (объект `selector` не принимается). OCR в госте недоступен; текст
со снимков читается локально Vision на Mac по JPEG из `ui.describe`.

### Падение гостя (не связано с этой работой)

После записи состояния Basil упал в панику ядра: `Kernel instruction fetch abort`,
процесс `pid 966: kx`, примерно 272 секунды после загрузки. Причину назвал и
подтвердил тред, выполнявший пробу `task_for_pid`: адрес вызова в ядре набран
вручную с опечаткой (в журнале VM `pc 0xfffffe003550ea78`, верным был
`0xfffffe0032518a78`). Spotify, YouTube, Seven и Яндекс Музыку в этот момент
никто не запускал и не устанавливал. Перезапуск Basil — решение владельца; до
него работа по расшифровке стоит.

### Вопрос, заданный владельцу

Открыть окно Basil и на экране App Store:

1. если страница приложения видна — установить YouTube и Seven из App Store
   (как был установлен Spotify) и запустить каждое один раз;
2. если пусто или «Cannot Connect» — сообщить, что на экране, и проверить вход
   в Apple ID (Settings → верхняя строка): Basil перезапускался другой работой
   (пересборка бандла vphone), сессия могла сброситься.

После установки — забрать расшифрованные бандлы и продолжить конвейер
(инъект dylib → переподпись → `devicectl install`).

## Что НЕ проверено

- Экран Basil: проверено OCR-ом локально для листа аккаунта и страницы приложения;
  остальные экраны не снимались.
- Какая копия Spotify установлена в госте сейчас и её размер: **проверено после
  перезапуска** — 9.1.28 (912802258), тот же путь бандла, что в 16:13, подписант
  «Apple iPhone OS Application Signing» (`jb.pmap_cs_custom_trust: PMAP_CS_APP_STORE`),
  то есть копия из App Store. Размер не мерил. YouTube, Seven и Яндекс Музыки
  в госте нет (`apps.info`: app not found). Procursus и Sileo уцелели после паники:
  67 пакетов `ii`, jbroot Irisin на месте.
- Состояние после неудачного удаления: `dpkg -l` показывает 67 `ii`, но
  `dpkg --audit` не выполнялся; состояние `shshd` (удаление прервано) не уточнено.
- Вход в Apple ID в госте: **проверено** — вход не выполнен (лист аккаунта предлагает Sign In).
- Работает ли Premium в UI на телефонах: владелец не подтвердил, dylib
  `PremiumForce` загрузка подтверждена только косвенно (процесс жив).
- Отличие по SDK (`iphoneos26.1` у Spotify против `iphoneos27.1` у YouTube и
  Seven) как причина разного поведения FairPlay — корреляция по трём приложениям,
  не доказано; после найденной причины (ручная установка из App Store) гипотеза
  не является объяснением.

## Что осталось в госте и на хосте

В госте (сверено после перезапуска): Spotify 9.1.28 (App Store-копия, расшифрованный),
Irisin, Procursus + Sileo (67 пакетов), Attest Demo, wqprobe. YouTube и Seven
удалены вместе с контейнерами (подтверждено `apps.info`).

На хосте (временное, в репозиторий не переносится): рабочие каталоги в `/tmp`
(бандлы, IPA, dylib, исходник dylib, снимки экрана гостя), профиль сервисов
`services.profile` до изменений. Учётные записи, сертификаты и профили
подписи в госте и в заметке не сохранялись.
