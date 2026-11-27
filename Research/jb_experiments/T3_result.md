# T3 — AMFI: xref-анализ строк trust cache и exec-политики (iPhone 13 / iPhone 17 Pro Max)

Дата: локальный разбор распакованных kernelcache, без установки ПО, без записи в kernelcache.
Кекст: `com.apple.driver.AppleMobileFileIntegrity` (LC_FILESET_ENTRY).

| устройство | файл | база кекста (vmaddr) | `__cstring` | `__text` (`__TEXT_EXEC`) |
|---|---|---|---|---|---|---|---|---|
| x13 — iPhone 13, A15, iOS 26.5.2 | `x13/kc.decomp/kernelcache.release.iphone14.decompressed` | `0xfffffff007546c20` | `+0x7b8`…`+0xc256` | `+0x165bb10`, размер `0x283c8` |
| x17 — iPhone 17 Pro Max, A19 Pro, iOS 27.2.1 | `x17/kc.decomp/kernelcache.release.v54.decompressed` | `0xfffffe0007665c40` | `+0x7b8`…`+0xc544` | `+0x1c00fa0`, размер `0x2a7ac` |

Все адреса ниже — **смещения от базы кекста** (VA = база + смещение), `+0x…`.
Каждый xref — это пара `adrp xN, <страница>` (инструкция перед xref'ом) + `add xN, xN, #lo12` (адрес xref'а — адрес `add`). Ни одного `adrp+ldr` через указатель в `__DATA*` не найдено, указателей на эти строки в `__DATA*` нет.

Метод: `patchfind.py` (исходный) + собственные скрипты `xrefs.py` (все `adrp+add` из `__text` к каждой строке), `prologue.py` (ближайший `pacibsp`/`pacibz`/`sub sp,sp` перед xref'ом). `dis.py` использован для контроля. Замечание по `dis.py`: он декодирует `adrp` неверно для x17 (печатает страницу с `+0x200000000`, напр. `0xfffffe0207666000` вместо `0xfffffe0007666000`); в x13 наоборот слайд `+0x200000000` реально присутствует в adrp-целях fileset-кекса, и это учтено при сопоставлении.

## 0. Итог в цифрах

| | x13 | x17 |
|---|---|---|---|---|---|---|---|---|
| строк по маске trust cache в `__cstring` | 33 | 35 |
| строк по маске exec-политики | 40 | 40 |
| xref'ов `adrp+add` (trust cache) | 49 | 49 |
| xref'ов `adrp+add` (exec) | 45 | 45 |
| различных функций (прологов) среди xref'ов | 26 | 26 |

- Строки без единого xref'а (на обоих): `com.apple.private.security.no-container`, `com.apple.system-task-ports`, `com.apple.private.amfi.can-check-trust-cache`, `run-unsigned-code`, `developer mode status`, `developer mode status has been resolved`, `AMFI Trust Cache Interface`, `personalized.trust-cache` (x13).
- Запрошенных строк **нет ни в `__cstring` AMFI, ни во всём kernelcache**: `dyld_policy`, `AMFI: policy`, `AMFI: out of memory`. (`out of memory` встречается в файле, но в `com.apple.security.sandbox`, `com.apple.filesystems.hfs.kext`, `com.apple.driver.AppleConvergedPCI` — к AMFI отношения не имеет.) `loadTrustCache` и `trustcache` присутствуют только как подстроки в приведённых ниже строках.
- **Ни один xref и ни один пролог не совпадает по смещению от базы** между x13 и x17 (0 из 90 / 0 из 26). Совпадает лишь **расстояние пролог→xref внутри функции**: 73 из 90 (81%).
- Ни одна строка не совпадает по смещению в `__cstring` (0 из 70 общих; в начале `__cstring` Δ ≈ −0x4d, дальше расходится).

### 1. Trust cache (загрузка, дубликаты, entitlement, REM)
| строка | смещ. x13 / x17 | # | xref x13 | xref x17 | пролог x13 | пролог x17 | пролог→xref x13 / x17 | xref совп. по смещ. |
|---|---|---|---|---|---|---|---|---|
| `static IOReturn AppleMobileFileIntegrityUserClient::copyTrustCacheFromInputArguments(IOExternalMethodArguments *, void **, IOByteCount *)` | `+0xd07` (только x13) | — | `+0x165c850` `+0x165c8f8` `+0x165c91c` | — | `+0x165c7f8` | — | — / — | — |
| `copyTrustCacheAndManifestFromInputArgument` | `+0xdc7` / `+0xd81` (Δ-0x46) | 1 | `+0x165ca08` | `+0x1c07efc` | `+0x165c984` | `+0x1c07e78` | `0x80` / `0x80` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 2 | `+0x165ca34` | `+0x1c07f28` | `+0x165c984` | `+0x1c07e78` | `0xac` / `0xac` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 3 | `+0x165caac` | `+0x1c07fa0` | `+0x165c984` | `+0x1c07e78` | `0x124` / `0x124` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 4 | `+0x165cb2c` | `+0x1c08020` | `+0x165c984` | `+0x1c07e78` | `0x1a4` / `0x1a4` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 5 | `+0x165cb54` | `+0x1c08048` | `+0x165c984` | `+0x1c07e78` | `0x1cc` / `0x1cc` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 6 | `+0x165cb78` | `+0x1c0806c` | `+0x165c984` | `+0x1c07e78` | `0x1f0` / `0x1f0` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 7 | `+0x165cb9c` | `+0x1c08090` | `+0x165c984` | `+0x1c07e78` | `0x214` / `0x214` | нет |
| `%s: PID %d is requesting a trust cache load\n` | `+0xed7` / `+0xe91` (Δ-0x46) | 1 | `+0x165be8c` | `+0x1c072a0` | `+0x165be58` | `+0x1c0726c` | `0x30` / `0x30` | нет |
| `static IOReturn AppleMobileFileIntegrityUserClient::loadTrustCache(OSObject *, void *, IOExternalMethodArguments *)` | `+0xf04` / `+0xebe` (Δ-0x46) | 1 | `+0x165be80` | `+0x1c07294` | `+0x165be58` | `+0x1c0726c` | `0x24` / `0x24` | нет |
| `com.apple.private.amfi.can-load-trust-cache` | `+0xf78` / `+0xf32` (Δ-0x46) | 1 | `+0x165bec4` | `+0x1c072d8` | `+0x165be58` | `+0x1c0726c` | `0x68` / `0x68` | нет |
| `%s: failure getting load trust cache entitlement for process %d\n` | `+0xfa4` / `+0xf5e` (Δ-0x46) | 1 | `+0x165beec` | `+0x1c07300` | `+0x165be58` | `+0x1c0726c` | `0x90` / `0x90` | нет |
| `%s: process %d not allowed to load trust cache\n` | `+0xfe5` / `+0xf9f` (Δ-0x46) | 1 | `+0x165bf98` | `+0x1c073ac` | `+0x165be58` | `+0x1c0726c` | `0x13c` / `0x13c` | нет |
| `%s: copyTrustCacheFromInputArguments failed: %d\n` | `+0x1015` (только x13) | — | `+0x165bf84` | — | `+0x165be58` | — | — / — | — |
| `%s: copyTrustCacheAndManifestFromInputArgument failed: %d\n` | `+0x1046` / `+0xffb` (Δ-0x4b) | 1 | `+0x165c000` | `+0x1c07414` | `+0x165be58` | `+0x1c0726c` | `0x1a4` / `0x1a4` | нет |
| `%s: invalid load trust cache selector %d\n` | `+0x1081` / `+0x1036` (Δ-0x4b) | 1 | `+0x165c014` | `+0x1c07428` | `+0x165be58` | `+0x1c0726c` | `0x1b8` / `0x1b8` | нет |
| `%s: only allowed process can modify the compilation service trust cache\n` | `+0x117f` / `+0x1134` (Δ-0x4b) | 1 | `+0x165c218` | `+0x1c07618` | `+0x165c0c0` | `+0x1c074dc` | `0x154` / `0x138` | нет |
| `static IOReturn AppleMobileFileIntegrityUserClient::isCdhashInTrustCache(OSObject *, void *, IOExternalMethodArguments *)` | `+0x11c8` / `+0x117d` (Δ-0x4b) | 1 | `+0x165c270` | `+0x1c076a0` | `+0x165c238` | `+0x1c07664` | `0x34` / `0x38` | нет |
| `static IOReturn AppleMobileFileIntegrityUserClient::isCdhashInTrustCache(OSObject *, void *, IOExternalMethodArguments *)` |  | 2 | `+0x165c2c4` | `+0x1c076f4` | `+0x165c238` | `+0x1c07664` | `0x88` / `0x8c` | нет |
| `static IOReturn AppleMobileFileIntegrityUserClient::isCdhashInTrustCache(OSObject *, void *, IOExternalMethodArguments *)` |  | 3 | `+0x165c2e4` | `+0x1c07714` | `+0x165c238` | `+0x1c07664` | `0xa8` / `0xac` | нет |
| `%s: Process %d is checking if a cdhash is in the trust cache\n` | `+0x1242` / `+0x11f7` (Δ-0x4b) | 1 | `+0x165c27c` | `+0x1c076ac` | `+0x165c238` | `+0x1c07664` | `0x40` / `0x44` | нет |
| `com.apple.private.amfi.can-check-trust-cache` | `+0x1f33` / `+0x1ee6` (Δ-0x4d) | — | — | — | — | — | — / — | — |
| `AMFI: research variant relaxes lock-state for trust caches: %u\n` | `+0x3009` / `+0x3023` (Δ+0x1a) | 1 | `+0x1660bf0` | `+0x1c0c4a4` | `+0x1660bac` | `+0x1c0c460` | `0x40` / `0x40` | нет |
| `amfi-allows-trust-cache-load` | `+0x3049` / `+0x3063` (Δ+0x1a) | 1 | `+0x1660c64` | `+0x1c0c518` | `+0x1660bac` | `+0x1c0c460` | `0xb4` / `0xb4` | нет |
| `AMFI: amfi-allows-trust-cache-load has unexpected size (%u).\n` | `+0x3066` / `+0x3080` (Δ+0x1a) | 1 | `+0x1660d10` | `+0x1c0c5c4` | `+0x1660bac` | `+0x1c0c460` | `0x160` / `0x160` | нет |
| `%s: loading duplicate trust cache (success)\n` | `+0x30a4` / `+0x30be` (Δ+0x1a) | 1 | `+0x1660d88` | `+0x1c0c640` | `+0x1660d48` | `+0x1c0c600` | `0x3c` / `0x3c` | нет |
| `%s: loading duplicate trust cache (success)\n` |  | 2 | `+0x166100c` | `+0x1c0c8cc` | `+0x1660fb4` | `+0x1c0c874` | `0x54` / `0x54` | нет |
| `loadTrustCacheWithExternalManifest` | `+0x30d1` / `+0x30eb` (Δ+0x1a) | 1 | `+0x1660d7c` | `+0x1c0c634` | `+0x1660d48` | `+0x1c0c600` | `0x30` / `0x30` | нет |
| `loadTrustCacheWithExternalManifest` |  | 2 | `+0x1660e6c` | `+0x1c0c724` | `+0x1660d48` | `+0x1c0c600` | `0x120` / `0x120` | нет |
| `loadTrustCacheWithExternalManifest` |  | 3 | `+0x1660e98` | `+0x1c0c750` | `+0x1660d48` | `+0x1c0c600` | `0x14c` / `0x14c` | нет |
| `loadTrustCacheWithExternalManifest` |  | 4 | `+0x1660ebc` | `+0x1c0c774` | `+0x1660d48` | `+0x1c0c600` | `0x170` / `0x170` | нет |
| `%s: loading trust caches disallowed by system state\n` | `+0x30f4` / `+0x310e` (Δ+0x1a) | 1 | `+0x1660e78` | `+0x1c0c730` | `+0x1660d48` | `+0x1c0c600` | `0x12c` / `0x12c` | нет |
| `%s: loading trust caches disallowed by system state\n` |  | 2 | `+0x16610d8` | `+0x1c0c998` | `+0x1660fb4` | `+0x1c0c874` | `0x120` / `0x120` | нет |
| `%s: attempted to load duplicate trust cache -- switching to success\n` | `+0x3129` / `+0x3143` (Δ+0x1a) | 1 | `+0x1660ea4` | `+0x1c0c75c` | `+0x1660d48` | `+0x1c0c600` | `0x158` / `0x158` | нет |
| `%s: attempted to load duplicate trust cache -- switching to success\n` |  | 2 | `+0x1661088` | `+0x1c0c948` | `+0x1660fb4` | `+0x1c0c874` | `0xd0` / `0xd0` | нет |
| `%s: unable to load trust cache: %d\n` | `+0x316e` / `+0x3188` (Δ+0x1a) | 1 | `+0x1660ec8` | `+0x1c0c780` | `+0x1660d48` | `+0x1c0c600` | `0x17c` / `0x17c` | нет |
| `%s: unable to load trust cache: %d\n` |  | 2 | `+0x16610bc` | `+0x1c0c97c` | `+0x1660fb4` | `+0x1c0c874` | `0x104` / `0x104` | нет |
| `loadTrustCacheWithType` | `+0x3192` / `+0x31ac` (Δ+0x1a) | 1 | `+0x1661000` | `+0x1c0c8c0` | `+0x1660fb4` | `+0x1c0c874` | `0x48` / `0x48` | нет |
| `loadTrustCacheWithType` |  | 2 | `+0x1661074` | `+0x1c0c934` | `+0x1660fb4` | `+0x1c0c874` | `0xbc` / `0xbc` | нет |
| `loadTrustCacheWithType` |  | 3 | `+0x16610cc` | `+0x1c0c98c` | `+0x1660fb4` | `+0x1c0c874` | `0x114` / `0x114` | нет |
| `trustCacheIsDuplicateImg4` | `+0x31e2` / `+0x31fc` (Δ+0x1a) | 1 | `+0x1660f38` | `+0x1c0c7f4` | `+0x1660ef0` | `+0x1c0c7ac` | `0x44` / `0x44` | нет |
| `AMFI: Failed to get trust cache UUID for %s (TCReturn: 0x%02X \| 0x%02X \| %u)\n` | `+0x3305` / `+0x332b` (Δ+0x26) | 1 | `+0x1661888` | `+0x1c0d1cc` | `+0x16617a4` | `+0x1c0d0d8` | `0xe0` / `0xf0` | нет |
| `AMFI: Failed to get trust cache type for %s: (TCReturn: 0x%02X \| 0x%02X \| %u)` | `+0x3353` / `+0x3379` (Δ+0x26) | 1 | `+0x16618cc` | `+0x1c0d210` | `+0x16617a4` | `+0x1c0d0d8` | `0x124` / `0x134` | нет |
| `Couldn't find trust cache UUID for process when mapping library from SMAC` | `+0x43b7` / `+0x441a` (Δ+0x63) | 1 | `+0x1664b1c` | `+0x1c1054c` | `+0x16645d0` | `+0x1c0fff8` | `0x54c` / `0x554` | нет |
| `Couldn't find trust cache UUID for library from SMAC` | `+0x4401` / `+0x4464` (Δ+0x63) | 1 | `+0x1664930` | `+0x1c10360` | `+0x16645d0` | `+0x1c0fff8` | `0x360` / `0x368` | нет |
| `AMFI Trust Cache Interface` | `+0x4978` / `+0x4a6c` (Δ+0xf4) | — | — | — | — | — | — / — | — |
| `%s (pid %u) not allowed for Restricted Execution Mode state (%s): code is not present in any trustcache\n` | `+0x5ee2` / `+0x5fed` (Δ+0x10b) | 1 | `+0x1668a3c` | `+0x1c14754` | `+0x16688b0` | `+0x1c145b4` | `0x188` / `0x19c` | нет |
| `%s not allowed for Restricted Execution Mode state (%s): code is not present in any trustcache` | `+0x6ab0` / `+0x6bbb` (Δ+0x10b) | 1 | `+0x166a77c` | `+0x1c16538` | `+0x166a3e0` | `+0x1c1615c` | `0x39c` / `0x3dc` | нет |
| `trust-cache` | `+0x6bb2` / `+0x6cbd` (Δ+0x10b) | 1 | `+0x166a880` | `+0x1c1683c` | `+0x166a3e0` | `+0x1c1615c` | `0x4a0` / `0x6e0` | нет |
| `personalized.trust-cache` | `+0x9ead` (только x13) | — | — (нет xref) | — | — | — | — / — | — |

Пояснения к п.1:
- xref на `com.apple.private.amfi.can-load-trust-cache` (x13 `+0x165bec4`, x17 `+0x1c072d8`) — функция `AppleMobileFileIntegrityUserClient::loadTrustCache` (пролог `+0x165be58` / `+0x1c0726c`); за `add` идёт загрузка аргументов и `bl` (entitlement-check, через `__auth_stubs`), при нуле — ветка на `%s: failure getting load trust cache entitlement for process %d`.
- `amfi-allows-trust-cache-load` — чтение device-tree свойства (`ldr x8,[x8,#0]` после `add`, затем `bl` к DT-парсеру) в функции с прологом `+0x1660bac` / `+0x1c0c460` (там же `AMFI: research variant relaxes lock-state for trust caches`).
- `loadTrustCacheWithExternalManifest` / `loadTrustCacheWithType` — строки-имена функций для `os_log`/assert (4 и 3 xref'а в одной и той же функции `+0x1660d48`/`+0x1c0c600` и `+0x1660fb4`/`+0x1c0c874`), это основная функция загрузки trust cache, где же `%s: loading trust caches disallowed by system state`, `%s: unable to load trust cache: %d`, обработка дубликатов.
- `trustCacheIsDuplicateImg4` — отдельная функция `+0x1660ef0` / `+0x1c0c7ac`.
- `%s: only allowed process can modify the compilation service trust cache` — функция `+0x165c0c0` / `+0x1c074dc` (userclient-селектор compilation-service trust cache).

### 2. Exec-политика (entitlement-ключи, developer mode, cs_enforcement, task ports)
| строка | смещ. x13 / x17 | # | xref x13 | xref x17 | пролог x13 | пролог x17 | пролог→xref x13 / x17 | xref совп. по смещ. |
|---|---|---|---|---|---|---|---|---|
| `com.apple.private.security.no-container` | `+0x2237` / `+0x21ea` (Δ-0x4d) | — | — | — | — | — | — / — | — |
| `com.apple.system-task-ports` | `+0x2374` / `+0x2327` (Δ-0x4d) | — | — | — | — | — | — / — | — |
| `com.apple.system-task-ports.control` | `+0x2390` / `+0x2343` (Δ-0x4d) | 1 | `+0x166a2b4` | `+0x1c1602c` | `+0x166a06c` | `+0x1c15de4` | `0x244` / `0x244` | нет |
| `com.apple.system-task-ports.control` |  | 2 | `+0x166c94c` | `+0x1c189cc` | `+0x166c874` | `+0x1c188f4` | `0xd4` / `0xd4` | нет |
| `dynamic-codesigning` | `+0x240f` / `+0x23c2` (Δ-0x4d) | 1 | `+0x166acdc` | `+0x1c165a4` | `+0x166a3e0` | `+0x1c1615c` | `0x8fc` / `0x448` | нет |
| `dynamic-codesigning` |  | 2 | `+0x166c794` | `+0x1c18810` | `+0x166c6dc` | `+0x1c18758` | `0xb4` / `0xb4` | нет |
| `get-task-allow` | `+0x2423` / `+0x23d6` (Δ-0x4d) | 1 | `+0x16647f0` | `+0x1c10218` | `+0x16645d0` | `+0x1c0fff8` | `0x220` / `0x220` | нет |
| `get-task-allow` |  | 2 | `+0x1668e68` | `+0x1c14b80` | `+0x16688b0` | `+0x1c145b4` | `0x5b4` / `0x5c8` | нет |
| `get-task-allow` |  | 3 | `+0x166c8b4` | `+0x1c18934` | `+0x166c874` | `+0x1c188f4` | `0x3c` / `0x3c` | нет |
| `get-task-allow` |  | 4 | `+0x166ca14` | `+0x1c18a98` | `+0x166c9f0` | `+0x1c18a74` | `0x20` / `0x20` | нет |
| `get-task-allow` |  | 5 | `+0x166cfbc` | `+0x1c190e8` | `+0x166cf20` | `+0x1c1904c` | `0x98` / `0x98` | нет |
| `task_for_pid-allow` | `+0x244d` / `+0x2400` (Δ-0x4d) | 1 | `+0x166a2a0` | `+0x1c16018` | `+0x166a06c` | `+0x1c15de4` | `0x230` / `0x230` | нет |
| `task_for_pid-allow` |  | 2 | `+0x166c970` | `+0x1c189f0` | `+0x166c874` | `+0x1c188f4` | `0xf8` / `0xf8` | нет |
| `run-unsigned-code` | `+0x2676` / `+0x2629` (Δ-0x4d) | — | — | — | — | — | — / — | — |
| `developer mode status` | `+0x3937` / `+0x395d` (Δ+0x26) | — | — | — | — | — | — / — | — |
| `developer mode status has been resolved` | `+0x3965` / `+0x398b` (Δ+0x26) | — | — | — | — | — | — / — | — |
| `AMFI: delaying developer mode latching...\n` | `+0x3b3b` / `+0x3b9e` (Δ+0x63) | 1 | `+0x1663348` | `+0x1c0ed34` | `+0x1663040` | `+0x1c0ea20` | `0x304` / `0x310` | нет |
| `AMFI: [2] informing daemon of developer mode state change` | `+0x3bb6` / `+0x3c19` (Δ+0x63) | 1 | `+0x1663810` | `+0x1c0f208` | `+0x16637c8` | `+0x1c0f1c0` | `0x44` / `0x44` | нет |
| `AMFI: Developer Mode is off (%i)\n` | `+0x3d4a` / `+0x3dad` (Δ+0x63) | 1 | `+0x1663b3c` | `+0x1c0f544` | `+0x1663b0c` | `+0x1c0f514` | `0x2c` / `0x2c` | нет |
| `AMFI: Enabling developer mode since we are restoring....\n` | `+0x3e00` / `+0x3e63` (Δ+0x63) | 1 | `+0x16635c8` | `+0x1c0efb8` | `+0x16633a4` | `+0x1c0ed94` | `0x220` / `0x220` | нет |
| `AMFI: Enabling developer mode since protected data is not available\n` | `+0x3e3a` / `+0x3e9d` (Δ+0x63) | 1 | `+0x1663628` | `+0x1c0f018` | `+0x16633a4` | `+0x1c0ed94` | `0x280` / `0x280` | нет |
| `AMFI: Disable developer mode since we couldn't get mobile obliteration status\n` | `+0x3e7f` / `+0x3ee2` (Δ+0x63) | 1 | `+0x16635fc` | `+0x1c0efec` | `+0x16633a4` | `+0x1c0ed94` | `0x254` / `0x254` | нет |
| `AMFI: Enabling developer mode since we are in mobile obliteration\n` | `+0x3ece` / `+0x3f31` (Δ+0x63) | 1 | `+0x1663654` | `+0x1c0f044` | `+0x16633a4` | `+0x1c0ed94` | `0x2ac` / `0x2ac` | нет |
| `AMFI: developer mode is enabled in the trusted darwinos research variant\n` | `+0x3f11` / `+0x3f74` (Δ+0x63) | 1 | `+0x1663678` | `+0x1c0f068` | `+0x16633a4` | `+0x1c0ed94` | `0x2d0` / `0x2d0` | нет |
| `AMFI: developer mode is force enabled\n` | `+0x3f5b` / `+0x3fbe` (Δ+0x63) | 1 | `+0x1663698` | `+0x1c0f088` | `+0x16633a4` | `+0x1c0ed94` | `0x2f0` / `0x2f0` | нет |
| `AMFI: trying to get developer mode status from ACM\n` | `+0x3f82` / `+0x3fe5` (Δ+0x63) | 1 | `+0x16636c4` | `+0x1c0f0b4` | `+0x16633a4` | `+0x1c0ed94` | `0x31c` / `0x31c` | нет |
| `AMFI: Developer Mode Is On\n` | `+0x3fe6` / `+0x4049` (Δ+0x63) | 1 | `+0x1663718` | `+0x1c0f108` | `+0x16633a4` | `+0x1c0ed94` | `0x370` / `0x370` | нет |
| `AMFI: Developer Mode can not be enabled on trusted darwinOS.\n` | `+0x4002` / `+0x4065` (Δ+0x63) | 1 | `+0x16636ac` | `+0x1c0f09c` | `+0x16633a4` | `+0x1c0ed94` | `0x304` / `0x304` | нет |
| `AMFI: [1] informing daemon of developer mode state change` | `+0x4198` / `+0x41fb` (Δ+0x63) | 1 | `+0x1663d68` | `+0x1c0f778` | `+0x1663d14` | `+0x1c0f724` | `0x50` / `0x50` | нет |
| `com.apple.security.get-task-allow` | `+0x469e` / `+0x4701` (Δ+0x63) | 1 | `+0x1664808` | `+0x1c10230` | `+0x16645d0` | `+0x1c0fff8` | `0x238` / `0x238` | нет |
| `com.apple.system-task-ports.token.control` | `+0x4935` / `+0x4a29` (Δ+0xf4) | 1 | `+0x166c5d0` | `+0x1c18648` | `+0x166c4f4` | `+0x1c1856c` | `0xd8` / `0xd8` | нет |
| `AMFI: profile disallowed due to developer mode\n` | `+0x5849` / `+0x593d` (Δ+0xf4) | 1 | `+0x1667f68` | `+0x1c13be0` | `+0x1667c94` | `+0x1c1390c` | `0x2d0` / `0x2d0` | нет |
| `cs_enforcement_disable` | `+0x6545` / `+0x6650` (Δ+0x10b) | 1 | `+0x1669398` | `+0x1c150d4` | `+0x1669300` | `+0x1c1503c` | `0x94` / `0x94` | нет |
| `%s: cs_enforcement disabled by boot-arg\n` | `+0x655c` / `+0x6667` (Δ+0x10b) | 1 | `+0x16693c4` | `+0x1c15100` | `+0x1669300` | `+0x1c1503c` | `0xc0` / `0xc0` | нет |
| `"can't has cs_enforcement_disable" @%s:%d` | `+0x65b9` / `+0x66c4` (Δ+0x10b) | 1 | `+0x1683654` | `+0x1c30ae8` | `+0x1683634` | `+0x1c30ac8` | `0x1c` / `0x1c` | нет |
| `AMFI: allowing pid %u to inherit IPC ports (get-task-allow)\n` | `+0x6841` / `+0x694c` (Δ+0x10b) | 1 | `+0x166a16c` | `+0x1c15ee4` | `+0x166a06c` | `+0x1c15de4` | `0xfc` / `0xfc` | нет |
| `com.apple.system-task-ports.read` | `+0x68b9` / `+0x69c4` (Δ+0x10b) | 1 | `+0x166a2c8` | `+0x1c16040` | `+0x166a06c` | `+0x1c15de4` | `0x258` / `0x258` | нет |
| `com.apple.system-task-ports.read` |  | 2 | `+0x166c91c` | `+0x1c1899c` | `+0x166c874` | `+0x1c188f4` | `0xa4` / `0xa4` | нет |
| `com.apple.system-task-ports.inspect` | `+0x68da` / `+0x69e5` (Δ+0x10b) | 1 | `+0x166a2dc` | `+0x1c16054` | `+0x166a06c` | `+0x1c15de4` | `0x26c` / `0x26c` | нет |
| `com.apple.system-task-ports.inspect` |  | 2 | `+0x166c8e4` | `+0x1c18964` | `+0x166c874` | `+0x1c188f4` | `0x6c` / `0x6c` | нет |
| `The system only allows platform binaries until developer mode status has been resolved, and the code is not a platform binary\n` | `+0x6d72` / `+0x6fa4` (Δ+0x232) | 1 | `+0x166aec0` | `+0x1c1675c` | `+0x166a3e0` | `+0x1c1615c` | `0xae0` / `0x600` | нет |
| `Developer mode is disabled, %*.s is disallowed` | `+0x6f74` / `+0x71a6` (Δ+0x232) | 1 | `+0x166cfb0` | `+0x1c190dc` | `+0x166cf20` | `+0x1c1904c` | `0x8c` / `0x8c` | нет |
| `AMFI: '%s': has developer signature (%#llx) but developer mode is not enabled\n` | `+0x7213` / `+0x7432` (Δ+0x21f) | 1 | `+0x166b08c` | `+0x1c16fd8` | `+0x166a3e0` | `+0x1c1615c` | `0xcac` / `0xe7c` | нет |
| `com.apple.system-task-ports.token.corpse` | `+0x85a4` / `+0x859f` (Δ-0x5) | 1 | `+0x166c580` | `+0x1c185f8` | `+0x166c4f4` | `+0x1c1856c` | `0x88` / `0x88` | нет |
| `com.apple.system-task-ports.token.inspect` | `+0x85cd` / `+0x85c8` (Δ-0x5) | 1 | `+0x166c524` | `+0x1c1859c` | `+0x166c4f4` | `+0x1c1856c` | `0x2c` / `0x2c` | нет |
| `com.apple.system-task-ports.token.read` | `+0x85f7` / `+0x85f2` (Δ-0x5) | 1 | `+0x166c550` | `+0x1c185c8` | `+0x166c4f4` | `+0x1c1856c` | `0x58` / `0x58` | нет |
| `com.apple.system-task-ports.token.read` |  | 2 | `+0x166c5ac` | `+0x1c18624` | `+0x166c4f4` | `+0x1c1856c` | `0xb4` / `0xb4` | нет |
| `%s: process %d attempted to use MAP_JIT but developer mode status has not been resolved!\n` | `+0x86cf` / `+0x86ca` (Δ-0x5) | 1 | `+0x166c814` | `+0x1c18890` | `+0x166c6dc` | `+0x1c18758` | `0x134` / `0x134` | нет |
| `AMFI: task_for_pid() not allowed\n` | `+0x8774` / `+0x876f` (Δ-0x5) | 1 | `+0x166c9d0` | `+0x1c18a50` | `+0x166c874` | `+0x1c188f4` | `0x158` / `0x158` | нет |
| `AMFI: developer mode is disabled, processes can not run invalid.` | `+0x8796` / `+0x8791` (Δ-0x5) | 1 | `+0x166ca60` | `+0x1c18ae4` | `+0x166c9f0` | `+0x1c18a74` | `0x6c` / `0x6c` | нет |

Пояснения к п.2:
- `cs_enforcement_disable`, `%s: cs_enforcement disabled by boot-arg` — одна функция `+0x1669300` / `+0x1c1503c` (это функция инициализации при старте: читает boot-arg `cs_enforcement_disable` (после `add` следует вызов парсера boot-arg'ов), при наличии — лог `%s: cs_enforcement disabled by boot-arg`). `"can't has cs_enforcement_disable" @%s:%d` — assert-строка в другой функции `+0x1683634` / `+0x1c30ac8` (переинициализация структуры при повторном вызове).
- `dynamic-codesigning`, `task_for_pid-allow`, `com.apple.system-task-ports.control`, `.read`, `.inspect` — по 2 xref'а в двух функциях: `+0x166a06c`/`+0x1c15de4` (проверка restricted entitlement'ов процесса — `AMFI: allowing pid %u to inherit IPC ports …`) и `+0x166c874`/`+0x1c188f4` (`_proc_check_inherit_ipc_ports` / `AMFI: task_for_pid() not allowed`).
- `get-task-allow` — 5 xref'ов в пяти функциях: `+0x16645d0`/`+0x1c0fff8` (SMAP/SNFC-проверка библиотек, рядом `Couldn't find trust cache UUID …`), `+0x16688b0`/`+0x1c145b4` (REM-проверка), `+0x166c874`/`+0x1c188f4` (`_proc_check_inherit_ipc_ports`), `+0x166c9f0`/`+0x1c18a74` (`Developer mode is disabled, %*.s is disallowed`), `+0x166cf20`/`+0x1c1904c` (финальная проверка exec-политики), функция `AMFI: '%s': has developer signature … developer mode is not enabled`, `Developer mode is disabled, %*.s is disallowed`.
- `AMFI: developer mode …` — блок функций latching'а developer mode: `+0x1663040`/`+0x1c0ea20` (`AMFI: delaying developer mode latching...`), `+0x16633a4`/`+0x1c0ed94` (7 строк `Enabling developer mode since …`, `Developer Mode Is On`, `trying to get developer mode status from ACM`), `+0x16637c8`/`+0x1c0f1c0` (`[2] informing daemon …`), `+0x1663b0c`/`+0x1c0f514` (`Developer Mode is off (%i)`), `+0x1663d14`/`+0x1c0f724` (`[1] informing daemon …`).

### Строки, присутствующие только в x17 (iOS 27.2.1)
| строка | смещ. x13 / x17 | # | xref x13 | xref x17 | пролог x13 | пролог x17 | пролог→xref x13 / x17 | xref совп. по смещ. |
|---|---|---|---|---|---|---|---|---|
| `AMFI: Platform binary with platform identifier not in trust cache\n` | — / `+0x6dd1` | 1 | — | `+0x1c17878` | — | `+0x1c1615c` | — / `0x70c` | нет (нет пары) |
| `platform binary with platform identifier not in trust cache\n` | — / `+0x6e14` | 1 | — | `+0x1c17884` | — | `+0x1c1615c` | — / `0x718` | нет (нет пары) |
| `int _check_cdhash_in_trustcache(struct proc *, user_addr_t)` | — / `+0x7f37` | 1 | — | `+0x1c17bfc` | — | `+0x1c17af0` | — / `0x70c` | нет (нет пары) |
| `int _check_cdhash_in_trustcache(struct proc *, user_addr_t)` |  | 2 | — | `+0x1c180cc` | — | `+0x1c17af0` | — / `0x5dc` | нет (нет пары) |

## 4. Что важно для дальнейшей работы

1. **Смещения между iOS 26.5.2 и 27.2.1 полностью другие** — ни строки, ни xref'ы, ни прологи не переносимы. Переносимы только: (а) семантика (какая строка в какой функции) и (б) расстояние пролог→xref (в 81% случаев).
2. Entitlement-ключи `no-container`, `com.apple.system-task-ports`, `can-check-trust-cache`, `run-unsigned-code` **не сравниваются по строке** — на их адреса нет ни одного `adrp` из `__text` (хотя соседние `get-task-allow`/`dynamic-codesigning` на той же странице имеют 5/2 xref'а). Они попадают в `__cstring` как элемент отсортированного справочника (окно `+0x2057…+0x26d2` x13 / `+0x200a…+0x2664` x17), а проверка идёт через `__os_log`-путь либо по хэшу/идентификатору — нужен отдельный разбор (например, через `__os_log`-таблицу или `OSMetaClass`-строки).
3. Новый функционал в iOS 27 в AMFI (по строкам и xref'ам): `AMFI: Platform binary with platform identifier not in trust cache` (+`platform binary …`, xref `+0x1c17878`/`+0x1c17884`, функция `+0x1c1615c`), `_check_cdhash_in_trustcache(struct proc *, user_addr_t)` (xref `+0x1c17bfc`/`+0x1c180cc`, функция `+0x1c17af0`), DER-entitlements (`DER entitlement extraction failure …`, `unable to obtain legacy CE context …`), `cmsBlob*`-диагностика (`'%s' couldn't fetch certs`, `cmsBlobVerify …`), `AMFI: bailing out because of restricted entitlements.`, `AMFI: using cached detached cert data for %s`.
4. В x13 вместо этого есть `copyTrustCacheFromInputArguments` (3 xref'а, `+0x165c850/8f8/91c`) и `personalized.trust-cache` — в x17 они исчезли; `copyTrustCacheAndManifestFromInputArgument` осталась (7 xref'ов с обеих сторон).

## 5. Ограничения

- Пролог ищется как ближайший `pacibsp`/`pacibz`/`sub sp,sp` до xref'а в пределах `0x4000`; для хвостовых вызовов/функций без выделения стека пролог может быть определён как чужой. У всех 188 xref'ов пролог найден (26 различных функций на устройство).
- `bl`-цели не разрешались в имена (импорты через `__auth_stubs`/chained-fixups); тип вызова определён по контексту строк.
- Запрошенные `dyld_policy`, `AMFI: policy`, `AMFI: out of memory` отсутствуют в обоих kernelcache — возможно, относятся к другому кексту (например, `com.apple.security.sandbox` или ядру) либо переименованы.

## Приложения (файлы в `/tmp/jbresearch/research/`)

- `xrefs.py`, `prologue.py`, `strs.py`, `wide.py`, `noxref.py`, `build_table.py` — скрипты; `q1_x13.txt`, `q1_x17.txt`, `q2_x13.txt`, `q2_x17.txt` — сырые списки xref'ов; `ctx.txt` — контекст (xref → пролог → следующий `bl`); `xref_table.json`, `prologues.json` — машинные данные; `entries_x13.txt`, `entries_x17.txt` — таблица fileset-записей.
## Артефакты

Каталог: `Research/jb_experiments/tools/amfi_xref/` (18 файлов, перенесены из `/tmp/jbresearch/research/`). Проверено: ECID, UDID и серийников устройств внутри нет — «serial» встречается только в именах кекстов (`AppleSamsungSerial`, `IOSerialFamily`), длинные десятичные числа в `ctx.txt`/`prologues.json` — это адреса `0xfffffff0…`/`0xfffffe0…` в десятичной записи.

Скрипты (Python 3, только stdlib + `otool` из Xcode CLT):

| файл | назначение |
|---|---|
| `strs.py <kc> <kext> <substr>…` | список секций кекта и всех строк `__cstring`, содержащих подстроку (адрес и смещение от базы) |
| `xrefs.py <kc> <kext> <substr>…` | все `adrp+add` xref'ы из `__text` к каждой подходящей строке; учитывает слайд `+0x200000000` в adrp-целях fileset-кекста (x13) |
| `prologue.py <kc> <kext> <va>…` | ближайший `pacibsp`/`pacibz`/`sub sp,sp` перед адресом (до `0x4000` назад) |
| `wide.py <kc> <kbase_hex> <name>…` | все `adrp` из `__text` на страницу строки и следующая инструкция (`add`/`ldr`) — показывает, что на точные адреса части entitlement-ключей xref'ов нет |
| `noxref.py <name>…` | проверка указателей на строку в `__DATA*` и `adrp+ldr` через них (для обеих сборок) |
| `build_table.py` | сборка `xref_table.json` + `prologues.json` из `q*_x*.txt`; пути — `JB_RESEARCH` (каталог скрипта) и `JB_IPSW` (каталог с `x13/`, `x17/`), по умолчанию `/tmp/jbresearch/…` |

Данные:

| файл | содержимое |
|---|---|
| `q1_x13.txt`, `q1_x17.txt` | сырые xref'ы по маскам `trustcache` / `trust cache` / `trust-cache` |
| `q2_x13.txt`, `q2_x17.txt` | сырые xref'ы по exec-политике (`cs_enforcement`, `developer mode`, `AMFI: policy`, `dyld_policy`, `dynamic-codesigning`, `no-container`, `run-unsigned-code`, `task_for_pid`, `get-task-allow`, `system-task-ports`) |
| `xref_table.json` | `{x13|x17: [[смещение строки, VA строки, текст, [[смещение xref, VA xref, kind], …]], …]}` |
| `prologues.json` | `{"тег|VA xref": [VA пролога, тип, расстояние]}` |
| `ctx.txt` | контекст: строка → xref → пролог → адрес ближайшего `bl` |
| `tbl_trust.md`, `tbl_exec.md`, `tbl_x17only.md` | промежуточные таблицы разделов 1–3 в том виде, в каком их сгенерировал `build_table.py`; колонка «пролог→xref x13 / x17» и правки «только x17»-строк добавлены в отчёт уже поверх них, генератором не воспроизводятся |
| `entries_x13.txt`, `entries_x17.txt` | `LC_FILESET_ENTRY` обоих kernelcache: `fileoff vmaddr entry_id` |

Как получить заново (нужны распакованные kernelcache и `otool`; ничего не ставится):

```sh
cd Research/jb_experiments/tools/amfi_xref
export JB_IPSW=/tmp/jbresearch/ipsw JB_RESEARCH="$PWD"
A=$JB_IPSW/x13/kc.decomp/kernelcache.release.iphone14.decompressed
B=$JB_IPSW/x17/kc.decomp/kernelcache.release.v54.decompressed
K=com.apple.driver.AppleMobileFileIntegrity
python3 xrefs.py $A $K trustcache "trust cache" "trust-cache" > q1_x13.txt
python3 xrefs.py $B $K trustcache "trust cache" "trust-cache" > q1_x17.txt
python3 xrefs.py $A $K cs_enforcement "developer mode" "out of memory" "AMFI: policy" dyld_policy dynamic-codesigning no-container run-unsigned-code task_for_pid get-task-allow system-task-ports > q2_x13.txt
python3 xrefs.py $B $K cs_enforcement "developer mode" "out of memory" "AMFI: policy" dyld_policy dynamic-codesigning no-container run-unsigned-code task_for_pid get-task-allow system-task-ports > q2_x17.txt
python3 build_table.py        # → xref_table.json, prologues.json
```

Проверено: пересборка из этого каталога даёт `xref_table.json` и `prologues.json`, побайтно совпадающие с исходными. Вывод `q*.txt` и `xref_table.json` содержит только смещения/VA внутри kernelcache и текст строк — идентификаторов устройства там нет по построению.
