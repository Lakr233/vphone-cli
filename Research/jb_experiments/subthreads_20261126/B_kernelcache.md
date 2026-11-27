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
