# Задача B: где Apple починила баг MPTCP — найти фикс между 23F84 и 24B156 на kernelcache 26.6.x

## Цель
По бинарному сравнению трёх билдов определить, в каком релизе и в каком именно месте `mptcp_subflow_soreceive` появился фикс описанного ниже дефекта, и закрывает ли этот фикс вариант **без DATA_FIN**. Это решает, остаётся ли путь уязвимым на 27.2.1 / 24B156.

## Входы
- Первоисточник: `/tmp/jbresearch/pubsrc/mptcp_report.md` (разделы 1–3, 9) и PoC `/tmp/jbresearch/pubsrc/mptcp_dfin_reach.py`.
- 23F84 (iOS 26.5.2): `/tmp/jbresearch/ipsw/x13/kc.decomp/kernelcache.release.iphone14.decompressed`.
- 24B156 (iOS 27.2.1): `/tmp/jbresearch/ipsw/x17/kc.decomp/kernelcache.release.v54.decompressed`.
- Нужно скачать: kernelcache iOS **26.6** и **26.6.1** для iPhone 14 (`iPhone14,5`; подойдёт и `iPhone14,2`/`iPhone14,4` — то же семейство A15, ядро одно и то же: `kernelcache.release.iphone14`). Утилита `ipsw` (`/opt/homebrew/bin/ipsw`, v3.1.752) умеет качать только ядро: `ipsw download ipsw --device iPhone14,5 --version 26.6.1 --kernel --confirm` (флаги смотри в `--help`; сначала выведи список подходящих билдов и убедись, что выбирается именно 26.6 / 26.6.1). Место на диске ограничено: свободно ~25 ГБ, ядро ~20 МБ — нормально; **полные IPSW не скачивать**. Сложность: по отчёту билд 26.5 beta был «AEA-encrypted»; если 26.6/26.6.1 не распакуются стандартным `ipsw kernel dec` — зафиксируй это и попробуй `ipsw kernel dec --km`/другие флаги по `--help`; не выйдет — вернись с этим результатом, не обходными путями.
- Открытый исходник XNU (три локальных дерева): `/tmp/jbresearch/igmp/xnu/full/xnu-11417.101.15`, `…/xnu-11417.140.69`, `…/xnu-12377.121.6` (`bsd/netinet/mptcp_subr.c`, `mptcp.c`). Обрати внимание: по прежнему анализу OSS-дерево 27.0 (`xnu-12377.121.6`) **всё ещё содержит** уязвимую форму кода, т.е. фикс в OSS не попал.

## Что уже сделано (перепроверь)
- Листинги `mptcp_subflow_soreceive` двух билдов: `/tmp/jbresearch/mptcp_chk/x13_soreceive.dis` (23F84) и `x17_soreceive.dis` (24B156), начало `0xfffffff00a20c3e4` / `0xfffffe000b0505c8`.
- В 24B156 есть блок, которого нет в 23F84: `0xfffffe000b0508fc..0xb050998`, условие `DATA_FIN ∧ dlen==0 ∧ dsn==1` → отключение mbuf от `so_rcv` перед проверкой суммы.
- Не установлено: судьба mbuf при `DATA_FIN=0 ∧ dlen==0`.

## Метод
1. Скачай и распакуй ядра 26.6 и 26.6.1. Сложи в `/tmp/jbresearch/ipsw/266/` и `/tmp/jbresearch/ipsw/2661/` (или аналогично). Зафиксируй версии (строка `Darwin Kernel Version` в образе: `strings … | grep -m1 'Darwin Kernel Version'`).
2. Для каждого из четырёх билдов найди функцию по строкам-якорам (как делает `/tmp/jbresearch/mptcp_loc.py`: `mptcp_subflow_soreceive`, `m->m_nextpkt == NULL`, `No DSS on secondary subflow`) и скинь листинг диапазоном через `/tmp/jbresearch/mptcp_chk/dump.py`.
3. Сравни четыре листинга вокруг: (a) вычисление `dlen`, (b) ветку `dlen==0`, (c) вызов `mptcp_validate_csum`, (d) обработчик неудачной проверки. Найди первый билд, где появляется блок отключения, и опиши его условие.
4. Главный вопрос: при `DATA_FIN=0` и `dlen==0` (данные `data_len=1`, плохая сумма, без FIN) доходит ли выполнение до validate с mbuf, ещё связанным с `so_rcv` — в 26.6.1 и в 24B156? Для этого проследи по листингу, где снимается голова очереди (`so->so_rcv.sb_mb`), что пишется в `sb_lastrecord`, и что остаётся в `m_nextpkt`. Дай ответ отдельно для каждого билда со ссылками на адреса.
5. Там, где исходник и бинарник расходятся, отмечай это — не подгоняй.
6. Если время остаётся: проверь по `mptcp_usrreq.c`, нужна ли для `socket(AF_MULTIPATH)` + `connectx` entitlement, и есть ли в 23F84 бинарное подтверждение (`mptcp_entitlement_check`).

## Результат
Заметка `Research/jb_experiments/ios26-kernel-research/mptcp_fix_localization.md`: таблица «билд → версия ядра → адреса (a)–(d) → есть ли блок отключения и его условие → судьба mbuf при DFIN=0». Вердикт: в каком релизе фикс, полным ли он является (закрывает ли вариант без DATA_FIN), и что это значит для 27.2.1. Родителю — кратко.


---

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
