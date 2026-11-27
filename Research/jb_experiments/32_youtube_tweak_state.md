# YouTube + YTKACE на iOS: состояние на момент остановки

Дата: 2026-11-26. Тред `thr_ivjv7nmtq5`, родитель — `thr_d657gsww3t` (проект vphone); задание на документирование — `thr_6vcmjuesnu`.

**Задача не выполнена: на телефоны ничего не установлено.** Твик выбран, собран и подготовлен к инъекту, но расшифрованного бандла YouTube нет. Приложение установлено в гостя Basil и там не запускается (см. «Блокер»). YouTube из госта не удалялся. VM Basil и бандлы vphone этим тредом после указания родителя не трогались.

Цели: iPhone 17 Pro Max (iOS 27.2.1, UDID `00008150-001014840138401C`), iPhone 13 (iOS 26.5.2, UDID `00008110-00096C803C31801E`). На момент проверки iPhone 17 Pro Max не был подключён (`CoreDeviceError 1011`); на iPhone 13 YouTube из App Store не установлен.

## Что за твик

**YTKACE 1.1.9** — https://github.com/itzzace/ytkace, MIT, коммит `d53194579f7540df8947cfc2417873f3f0baf31f` (24.11.2026). Поддерживает YouTube **21.47.6** — текущая версия в App Store (проверено через `itunes.apple.com/lookup`; минимум iOS 17).

Что делает (по исходникам):

- реклама: блокировка в ленте, Shorts и плеере (`Tweak/Features/Ads/AdsHooks.mm`, `PromoHooks.mm`); по умолчанию **включено** (`YTKACE.Preference.Ads.Blocking`);
- SponsorBlock и DeArrow;
- фоновое воспроизведение (`BackgroundPlaybackHooks.mm`: `YTIPlayabilityStatus isPlayableInBackground`, `MLVideo playableInBackground`); по умолчанию **включено** (`YTKACE.Preference.Playback.BackgroundAudio`);
- PiP (`YTKACE.Preference.Player.PiP`) и скачивание видео, аудио, Shorts, плейлистов (`YTKACE.Preference.Downloads.Enabled`) — по умолчанию **выключены**, включаются в настройках твика;
- очередь без Premium, OLED, Return YouTube Dislike, Liquid Glass.

Хуки ставятся по имени класса и селектора через `objc/runtime.h` (`Tweak/Runtime/Hooking.mm`): нет класса или селектора — хук молча пропускается. Orion Runtime и джейлбрейк не нужны.

Аудит сети (по строкам dylib и исходникам): наружу ходят только `youtube.com`, `youtubei.googleapis.com`, `i.ytimg.com`, `sponsor.ajay.app`, `dearrow-thumb.ajay.app`, `returnyoutubedislikeapi.com`, `api.aisloplist.com`, `raw.githubusercontent.com` (списки AiSList). Телеметрии и activation-сервиса нет.

Скачивание и HLS-режим работают с подменой клиента: запросы к `/player` идут как TVHTML5 «PS4» (`Streaming/TVClient.mm`) и как visionOS 1.02 (`Downloads/DirectDownloader.mm`, `Streaming/HLSPlayback.mm`). Сервер видит на аккаунте такую активность.

Что не открывается клиентским патчем: официальные оффлайн-скачивания Premium и остальные серверные проверки.

### Что отброшено при разведке

| Твик | Причина |
|---|---|
| YTLite / YouTube Plus (`dayanch96/YTLite`), YouTube 21.43.5 | с 5.2 платный (подписка, аккаунт); исходники в репозитории остановились на 3.0.1, актуальное — закрытые `.deb` |
| uYou, uYouPlus, uYouEnhanced | не поддерживаются; uYou — закрытый твик |
| YouPiP, YTUHD, Return-YouTube-Dislikes (PoomSmart, открытые, Logos) | резерв на случай, если PiP в YTKACE не заработает |
| YouQuality, YTShortsProgress (PoomSmart) | уже покрыты YTKACE |

## Где исходник и как собирался

Клон YTKACE — `/tmp/yt/itzzace_ytkace` (неглубокий, коммит `d531945`). Theos — `/tmp/yt/theos` (клон theos/theos с подмодулями, в `sdks/` — `iPhoneOS16.5.sdk` из theos/sdks). Оба каталога в `/tmp`, в репозиторий не переносятся.

Сборка — как в `.github/workflows/build-deb.yml` самого YTKACE:

```sh
export THEOS=/tmp/yt/theos PATH=/tmp/yt/theos/bin:$PATH
cd /tmp/yt/itzzace_ytkace && make clean all      # → dist/YTKACE.dylib
```

Результат: `dist/YTKACE.dylib`, Mach-O arm64, `LC_BUILD_VERSION minos 15.0 sdk 26.5`, 9 886 800 байт, sha256 `cfd86e3bbe89c81762c8739a5fd6186515a5ec44c5c9ade153d64c5a7376e441`. Внутри статический FFmpeg 8.1.2 (LGPL, `Vendor/FFmpeg/lib/*.a`). Зависимости — только системные фреймворки, `/usr/lib/libz`, `libicucore`, `libc++`. Safari-extension из YTKACE не собиралась.

## Что установлено в гостя и куда

Одно действие в госте — установка YouTube через `guest push` + `apps.install`:

| Что | Где |
|---|---|
| Оригинальный App Store IPA 21.47.6 (зашифрован, 279 429 560 байт) | `/var/tmp/youtube.ipa` в госте; копия на хосте `/tmp/yt/orig/com.google.ios.youtube_21.47.6.ipa` |
| Бандл YouTube 21.47.6 | `/private/var/containers/Bundle/Application/48B63B60-41DD-4EC6-8C04-4350722F6185/YouTube.app` |
| Контейнер данных | `/private/var/mobile/Containers/Data/Application/B3CE17E2-1FD0-4F50-B243-BAA0D10FBF40` |

`apps.info` после установки: `signer = Apple iPhone OS Application Signing`, `encrypted = true`, `minimum_os = 17.0`, `sdk = iphoneos27.1`, 5 плагинов (Intents, NotificationContent, NotificationService, ExternalShare, WidgetKit). Групповые контейнеры: `group.com.google.YouTube`, `group.com.google.common`, `group.com.google.cy`.

## Что сделано

1. Разведка (таблица выше), выбор YTKACE, сборка dylib из исходников.
2. Оригинальный IPA скачан `ipatool download -b com.google.ios.youtube --purchase`. В `Frameworks/` только `widevine_cdm_secured_ios.framework` и `libswiftCompatibilitySpan.dylib` — остальное монолит; в бинарнике `LC_ENCRYPTION_INFO_64 cryptid 1`.
3. Подготовлен репак под подпись владельца: dry-run на копии зашифрованного бандла. Итог dry-run: `codesign -v --deep --strict` чистый; `LC_LOAD_DYLIB @rpath/YTKACE.dylib` в бинарнике; каждый из 5 appex подписан со своим `application-identifier` (`25U9HN34VM.com.google.ios.youtube.<Appex>`); `UIBackgroundModes` содержит `audio`; `embedded.mobileprovision` на месте. Этот IPA (`/tmp/yt/dry/YouTube-ytkace-DRYRUN.ipa`) — только механика, ставить его нельзя.
4. Установка в гостя (таблица выше).

## Блокер

- `apps.launch` → `launch refused: com.google.ios.youtube`. Причина не сообщается. Это не `IcliLaunchLocked`: `guest unlock` вернул `was_locked: false`, `was_screen_off: false`.
- Файл бинарника на диске в госте остался зашифрованным: скачан `pull` (`/tmp/yt/dec/YouTube.full`, 231 840 112 байт), `otool -l` на хосте → `cryptid 1`, `cryptoff 16384`, `cryptsize 195756032`. На диске бандл остался зашифрованным; расшифрованного образа этого приложения у меня нет.
- Spotify в той же VM запускается (`apps.launch` → `pid 336`, `frontmost_verified: true`), в `apps.info` у него `encrypted = false`; расшифрованный файл родительского треда `/tmp/spt/dec/Spotify` — `cryptid 0`. Как Spotify был установлен и почему оказался расшифрован на диске, не выяснено.
- Это известная граница vphone: в `Skills/vphone-guest-control/references/install-faq.md` приложения, блокируемые FairPlay (`CODESIGNING Invalid Page`), названы неподдерживаемыми (issues #212, #220, #356), и там прямо сказано не патчить вокруг.

## Что проверено и что нет

Проверено: сборка dylib и её зависимости; установка в гостя и факт отказа запуска и шифрования файла; механика репака на зашифрованном бандле.

Не проверено:

- работа твика на реальном YouTube: совпадение имён классов с 21.47.6 взято из README YTKACE, по class-dump нашего бинарника не сверялось;
- установка и запуск на iPhone 17 Pro Max и iPhone 13;
- логин Google, реклама, фоновое воспроизведение, PiP, скачивание, SponsorBlock — ничего из этого вживую не видено.

## Что осталось недоделанным

- Расшифрованный YouTube 21.47.6: нужен дамп с настоящего джейлбрейка. Готовые чужие расшифрованные IPA не скачивались — по правилам задачи требуется решение пользователя.
- Инъект в расшифрованный бандл, подпись, установка на 17 Pro Max, проверка функций.
- Если на телефоне стоит App Store-версия YouTube — перед удалением спросить пользователя (удаляются локальные данные).
- Ветка `docs/youtube-ios-ytkace` репозитория `freehire-ops` (worktree `~/Projects/freehire/freehire-ops-wt/youtube`, 3 коммита: `12defad`, `4b63a53`, `1031463`) — **не запушена**. Там `docs/2026-11-26-youtube-ios-ytkace.md` и `scripts/youtube-ytkace/` (`build_dylib.sh`, `repack.sh`, `macho_inject.py`, `sanitize_plist.py`, `list_macho.py`).
- Ошибки, чтобы не повторять: `plutil -extract <key> json <file>` без `-o` перезаписывает сам файл (испортил `Info.plist` в распакованной копии; IPA цел, копия восстановлена и сверена по размерам 7905 файлов); все appex нельзя подписывать с `application-identifier` основного приложения — у каждого свой.

## Хронология сбоя VM (не действие этого треда)

В начале работы Basil была привязана к local-сборке `2.18.0-local.ba7a6fef`, AMFI блокировал её `vphone-vm`, а старт на релизном бандле `2.18.0` давал `Could not install update` от `vphoned`. Родительский тред переключил VM на согласованную пару (`vm set-bundle --update-environment`), после этого сокет отвечает. В этой сборке `vphoned` параметр называется `bundle_id` (snake_case), иначе `Unknown param`.
