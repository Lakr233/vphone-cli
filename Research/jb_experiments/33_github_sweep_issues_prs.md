# 33 — Повторный обход GitHub: репозитории, issues, PR

Дата: 2026-11-26. Причина: отсутствие находки в заметках 04/12/16 не доказывает, что
публичного пути нет; issues и PR ранее отдельно не обходились.

Границы: только GitHub (`gh api search/repositories`, `search/issues`, README, комментарии).
Веб, X, форумы не искались. Ничего не собиралось и не запускалось на устройствах.
Статусы «run / experimental» и номера CVE — заявления авторов, с advisory Apple не сверялись.

## 0. Вывод

- **A13** (iPhone 11): есть публичная tethered-цепочка до root + kernel R/W на 27.2 / 27.2.1 —
  `Xplo8E/Liter8` через `usbliter8` (SecureROM). Ближайший аналог метода vphone на железе.
- **A14**: тот же автор не поддерживает, `usbliter8` его не затрагивает.
- **A15, A19** (наши iPhone 13 и 17 Pro Max): публичного kernel exploit + SPTM-обхода
  по-прежнему нет. Новых кандидатов сверх уже проверенных (04, 12) не найдено.
- KRW от Calif/lambda не опубликован на 2026-11-23 (по трекеру, не первоисточнику).

## 1. Что нашлось и чего нет в `04_public_exploit_landscape.md`

| Ресурс | Что даёт по заявлению автора | Отношение к нашим устройствам |
|---|---|---|
| `Xplo8E/Liter8` v0.3.x, 254★, push 2026-11-22 | tethered JB iPhone 11, iOS 27.0–27.3b1; root SSH, apt/Sileo, `tfp0` (`fw get-boot --tfp0`), on-device lldb (`fw setup-debugger`). 24B156 — `run`, 11 Pro/Max — `experimental` | A13 — не наш чип |
| `34306/doublera1n`, 192★ | iPhone 11 / SE 2, 27.0–27.2: второй Data-том при стоковом System | A13; глубоко не читал |
| `Mac-XK/ios27-jb-kit`, 8★ | обёртка над Liter8 + usbliter8 (нужна плата RP2350) | — |
| `ramonburf/Tims-Cooked`, 68★, push 2026-11-26 | iPhone 13 Pro / 27.0.1, IOSurface-пути; сам автор пишет: KRW, кодеген в ядре и jailbreak не показаны | A15, но 27.0.1 и без результата |
| `Mac-XK/iOS27-Kernel-Primitives`, 1★ | AVE2 OOB write, IOSurface UAF, spec_vnops UAF, ANE OOB для 27.0–27.1: скелеты PoC, на железе не запускались, закрыты в 27.2 | 27.2.1 — закрыто; наличие тех же багов в 26.5.2 не проверено |
| `burrejak22/ios-26-jailbreak-research`, 3★ | iPhone 17 Pro (A19) 26.6.2: AVE2 AlphaLayerID=255 → паника (DART fault), KASLR-этап не сработал; MIE на A19 — отдельный барьер | A19, но 26.6.2 и без KRW |
| `iMaxTomas/ios27-jb-tracker`, 83★ | факт-чек по Calif 27.0.1 (Hexacon 2026): lambda отложил KRW без ETA, Dopamine без 27, A14+ без публичного SPTM/PPL/MIE-обхода | сводка, не первоисточник |
| `wiyw/jb-research` | дифф 27.0.1 → 27.2 по `iPhone17,3` (наш PCC-билд) | пригодится для локализации фиксов |
| `Arch087146/iOS-27.0.1-27.2-jailbreak-patch-analysis` | дифф IPSW 27.0.1 → 27.2 (t8160): в SPTM добавлены проверка refcount IOMMU/DART, проверка GMMU TLB-invalidation, bound в hibernation handoff | указывает, какую поверхность чинил Apple |
| `Hetyey/Coruna` | PPL/SPTM-обход, iPhone 13 / 17.0; на устройстве автора GFX firmware job не обработал | 17.0 — не наш билд, и не сработал |

## 2. Issues и PR

| Где | Что | Итог |
|---|---|---|
| `Xplo8E/Liter8#29` | «iPhone 12 Support» (A14, 27.0.1) | закрыт 2026-10-26; автор: «iPhone 12 is not affected by the usbliter8 exploit» |
| `Xplo8E/Liter8#46` | iPhone SE 2 (A13) experimental на 24B156 | открыт с 2026-11-21; тело не читал |
| `Xplo8E/Liter8#37`, `#28`, `#31` | 24B156 reviewed; KRW с 27.0 по 27.2 RC; tfp0 для libkrw | merged — механизм получения kernel R/W у Liter8 |
| `alfiecg24/Titan#1` | порт Titan на A15 / 26.0.1 (Philiphall6): ClearSword KRW работает, блокер — physical write / SPTM | открыт с 2026-10-21, ответа автора нет |
| `opa334/Dopamine` | последний коммит 2026-11-03 (3.0.13) | поддержки 27 нет |
| `34306/doublera1n#8`, `#14`, `#20` | boot fails / iBoot rejects firmware / root pivot на 27.0.1 | открыты — цепочка на A13 тоже не безотказна |
| `Ping-2o/CVE-2026-112611-cg-shading#1` | применим ли фикс CoreGraphics Type5 к 24A446 | вопрос без ответа; 112611 — userland (WebKit/CoreGraphics), по трекеру подписан Anna Groza |
| `clearbluejar/ghidriff#172`, `ghidriff-test-data#2` | IOSurface-фиксы как gold cases | подтверждает, что CVE-2026-112477 чинился, детали не читал |
| `ioezgamer/IOSurfaceSafeProbe#91/#170/#180/#135` | пробники IOSurface UAF и CVE-2026-112611 | закрыты, содержимое не читал |
| `HiItsMe2117/ios26-kernel-research` | push 2026-11-16: AVE2 OOB read (112466) как KASLR признан мёртвым; ICMP6_FILTER write подтверждён на A18 / 26.6.1 | на 23F84 не проверялся (см. 04) |

## 3. Что это значит для задачи

1. Цикл «выполнить код → логи ядра → повторить» на железе закрыт только на A13, и только
   потому, что SecureROM-эксплойт позволяет загрузить уже пропатченное ядро — как в vphone.
   Для A15 и A19 такого входа нет: нужен kernel exploit под точный билд плюс SPTM-обход
   (на A19 ещё MIE).
2. Из непроверенного остаётся то же, что в `05`: ICMP6_FILTER-запись на 23F84, CVE-2026-86916
   (сайт неизвестен), живой тест MPTCP.
3. «Любое устройство» по-прежнему не подтверждается: A14 уже выпадает, A15/A19 — без публичного пути.

## 4. Не проверено

- Тела PR Liter8 #46 и Titan #1; репозитории `kspyn/c0nqueror` (пустой README),
  `s24416230-byte/crystal1xx`, `rett1sm/PhoenixJB` и прочие «sim / prank» — не читал.
- Advisory Apple по CVE не сверялись.
- Веб, X, форумы, Telegram — вне этого прохода.
