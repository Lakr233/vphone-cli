## Общие правила (обязательны)

- Отвечай по-русски. Это исследование на устройствах владельца; всё, что не подтверждено первоисточником, помечай `ГИПОТЕЗА`.
- **Не бери ничего из этой инструкции на веру как «факт о билде»**: адреса и смещения ниже — результаты чужого анализа. Перед использованием в живом тесте перепроверь сам по файлу (дизассемблер ниже) и записывай в лог то, что видишь ты.
- **Устройства определяются ТОЛЬКО по devicectl ID.** Разрешены: iPhone 13 `4A8A1186-3B54-5E76-95C0-3E47590416B9` (26.5.2 / 23F84) и iPhone 17 Pro Max `EB205573-B173-5937-B2B1-031211E2944F` (27.2.1 / 24B156). **Запрещено касаться**: `1747203B-5F35-5AB9-A0B4-8649A08FC874` (iPhone-Evgenia-2, чужой), `8F9F654A-C0E6-564F-83DC-2FE5DF9639E2` (Avocado), `75DC7316-88D8-5325-BACA-BEE1C1052302` (Basil — кроме треда C), Apple Watch `14F6CAFF-538C-529F-B891-783450377147`.
- Если нужное устройство `unavailable` — жди не более 15 минут (опрос раз в минуту), затем вернись с `НЕ ВЫПОЛНЕНО` и причиной. **Никогда не подменяй устройство.**
- Рабочие файлы — только в своей папке `/tmp/jbresearch/<своя>/` и в заметках `Research/jb_experiments/` репо `/Users/i_strelov/Projects/vphone/vphone-cli/`. Папку `/tmp/jbresearch/wq2/` не менять (эталон). Чужие папки `/tmp/jbresearch/wq_x13`, `/tmp/jbresearch/wq_x17` — только чтение, кроме треда A (ему выделена `wq_x13` на время работы).
- `support.apple.com` отдаёт 429 после нескольких запросов — не ходить туда; локальные копии адвизори в `/tmp/jbresearch/advisories/` (разобранные по `<h3>`: `cve_index.json`, `entries_by_heading.json`; читаемая версия — `/Users/i_strelov/Projects/vphone/vphone-cli/Research/jb_experiments/ios26-kernel-research/apple_advisory_entries_26.5.2_to_27.2.1.md`).
- Ничего не устанавливать на серверы freehire, кроме явно разрешённого в твоей задаче. Ничего не удалять чужого. Никаких изменений в конфигурацию серверов (ufw, ssh, nginx, systemd) без явного разрешения в задаче.
- В конце: итоговый ответ родителю — кратко: что сделано, вердикт (`подтверждено | опровергнуто | не определено | не выполнено`), пути к артефактам, что осталось открытым. Подробности — в файле заметки.

## Инструменты дизассемблирования (проверено работает)

- `/tmp/jbresearch/mptcp_chk/dump.py <kernelcache> <start_va_hex> <n_ins>` — capstone-листинг диапазона (останавливается на `ret`). venv: `/tmp/jbresearch/venv/bin/python`.
- `llvm-objdump` из Xcode на этих kernelcache дизассемблирует пусто — не трать время.
- `/tmp/jbresearch/igmp/kdiff.py <kc> "<cstring>"` — поиск функции по строке и её xref'ам (`load`, `find_str`, `xrefs`, `func_start`, `dis` — импортируется).
- Kernelcache (несдвинутые статические VA): 23F84 — `/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed`; 24B156 — `/tmp/jbresearch/ipsw/x17/kc.decomp/kernelcache.release.v54.decompressed`.
- Прежние листинги (чужой анализ, перепроверять): `/tmp/jbresearch/mptcp_chk/x13_soreceive.dis`, `/tmp/jbresearch/mptcp_chk/x17_soreceive.dis`.

## Процедура сборки/подписи/установки пробы на iPhone 13 (проверено в предыдущих прогонах)

Папка проекта `/tmp/jbresearch/wq_x13/` (bundle id `me.strelov.wqprobe`, менять нельзя — профиль только на него). `build.sh` там собирает без подписи (`CODE_SIGNING_ALLOWED=NO`) и подписывает вручную (`sign.entitlements`, сертификат Apple Development, профиль `660687d1-e008-48eb-95d4-739ef6b1f931.mobileprovision`, действует до 2027-11-26). Новый исходник регистрируется в `wqprobe.xcodeproj/project.pbxproj` в четырёх местах (образец — `aio_probe.m`). Установка: `xcrun devicectl device install app --device 4A8A1186-3B54-5E76-95C0-3E47590416B9 <dir>/dd/Build/Products/Debug-iphoneos/wqprobe.app`. Запуск **без** `--console` (с ним виснет на минуты): `xcrun devicectl device process launch --device <ID> me.strelov.wqprobe`; лог забирать: `xcrun devicectl device copy from --device <ID> --domain-type appDataContainer --domain-identifier me.strelov.wqprobe --source tmp/out.txt --destination <свой путь>`. Крэш-логи: `--domain-type systemCrashLogs`. Пример пробы и записи лога: `/tmp/jbresearch/wq_x13/iogpu_l13_probe.m`, `wqprobe.m`.

## Вызовы в ядро на Basil (правило появилось после инцидента 2026-11-26 21:52)

- Инцидент: сабтред C вручную набрал готовый адрес для `kx` (kcall10) с опечаткой — `0xfffffe003550ea78` вместо `0xfffffe0032518a78` (link `0x8cd8a78` + slide `0x29840000`). Результат — Kernel instruction fetch abort, VM в панике. Boot M потерян.
- Адреса ядра **не набирать и не считать руками**. Считать только скриптом из link-адреса по файлу kernelcache и слайда, прочитанного заново после каждой загрузки VM (`tools/basil_kcall/kslide.py --call LINK` / `--read LINK`). Перед вызовом вывести скриптом: link, slide, сумму — и вызвать ровно то, что вывел скрипт.
- Строка `Kernel text exec slide` в panic-логе выражена от другой link-базы; к link-адресам её не прибавлять. Слайд один для всех сегментов.
- Если Basil одновременно используется другим тредом (GDB-stub, shell-сокет) — никаких вызовов через kcall10 без явного предупреждения того треда.
- Если Basil в панике — не перезапускать. Сохранить лог (`~/Library/Logs/vphone-launchpad/Basil.log` перезаписывается при следующем запуске), сообщить родителю; перезапуск — только по решению владельца.
