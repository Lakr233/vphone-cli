### 1. Trust cache (загрузка, дубликаты, entitlement, REM)
| строка | смещ. x13 / x17 | # | xref x13 | xref x17 | пролог x13 | пролог x17 | xref совп. |
|---|---|---|---|---|---|---|---|
| `static IOReturn AppleMobileFileIntegrityUserClient::copyTrustCacheFromInputArguments(IOExternalMethodArguments *, void **, IOByteCount *)` | `+0xd07` (только x13) | — | `+0x165c850` `+0x165c8f8` `+0x165c91c` | — | `+0x165c7f8` | — | — |
| `copyTrustCacheAndManifestFromInputArgument` | `+0xdc7` / `+0xd81` (Δ-0x46) | 1 | `+0x165ca08` | `+0x1c07efc` | `+0x165c984` | `+0x1c07e78` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 2 | `+0x165ca34` | `+0x1c07f28` | `+0x165c984` | `+0x1c07e78` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 3 | `+0x165caac` | `+0x1c07fa0` | `+0x165c984` | `+0x1c07e78` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 4 | `+0x165cb2c` | `+0x1c08020` | `+0x165c984` | `+0x1c07e78` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 5 | `+0x165cb54` | `+0x1c08048` | `+0x165c984` | `+0x1c07e78` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 6 | `+0x165cb78` | `+0x1c0806c` | `+0x165c984` | `+0x1c07e78` | нет |
| `copyTrustCacheAndManifestFromInputArgument` |  | 7 | `+0x165cb9c` | `+0x1c08090` | `+0x165c984` | `+0x1c07e78` | нет |
| `%s: PID %d is requesting a trust cache load\n` | `+0xed7` / `+0xe91` (Δ-0x46) | 1 | `+0x165be8c` | `+0x1c072a0` | `+0x165be58` | `+0x1c0726c` | нет |
| `static IOReturn AppleMobileFileIntegrityUserClient::loadTrustCache(OSObject *, void *, IOExternalMethodArguments *)` | `+0xf04` / `+0xebe` (Δ-0x46) | 1 | `+0x165be80` | `+0x1c07294` | `+0x165be58` | `+0x1c0726c` | нет |
| `com.apple.private.amfi.can-load-trust-cache` | `+0xf78` / `+0xf32` (Δ-0x46) | 1 | `+0x165bec4` | `+0x1c072d8` | `+0x165be58` | `+0x1c0726c` | нет |
| `%s: failure getting load trust cache entitlement for process %d\n` | `+0xfa4` / `+0xf5e` (Δ-0x46) | 1 | `+0x165beec` | `+0x1c07300` | `+0x165be58` | `+0x1c0726c` | нет |
| `%s: process %d not allowed to load trust cache\n` | `+0xfe5` / `+0xf9f` (Δ-0x46) | 1 | `+0x165bf98` | `+0x1c073ac` | `+0x165be58` | `+0x1c0726c` | нет |
| `%s: copyTrustCacheFromInputArguments failed: %d\n` | `+0x1015` (только x13) | — | `+0x165bf84` | — | `+0x165be58` | — | — |
| `%s: copyTrustCacheAndManifestFromInputArgument failed: %d\n` | `+0x1046` / `+0xffb` (Δ-0x4b) | 1 | `+0x165c000` | `+0x1c07414` | `+0x165be58` | `+0x1c0726c` | нет |
| `%s: invalid load trust cache selector %d\n` | `+0x1081` / `+0x1036` (Δ-0x4b) | 1 | `+0x165c014` | `+0x1c07428` | `+0x165be58` | `+0x1c0726c` | нет |
| `%s: only allowed process can modify the compilation service trust cache\n` | `+0x117f` / `+0x1134` (Δ-0x4b) | 1 | `+0x165c218` | `+0x1c07618` | `+0x165c0c0` | `+0x1c074dc` | нет |
| `static IOReturn AppleMobileFileIntegrityUserClient::isCdhashInTrustCache(OSObject *, void *, IOExternalMethodArguments *)` | `+0x11c8` / `+0x117d` (Δ-0x4b) | 1 | `+0x165c270` | `+0x1c076a0` | `+0x165c238` | `+0x1c07664` | нет |
| `static IOReturn AppleMobileFileIntegrityUserClient::isCdhashInTrustCache(OSObject *, void *, IOExternalMethodArguments *)` |  | 2 | `+0x165c2c4` | `+0x1c076f4` | `+0x165c238` | `+0x1c07664` | нет |
| `static IOReturn AppleMobileFileIntegrityUserClient::isCdhashInTrustCache(OSObject *, void *, IOExternalMethodArguments *)` |  | 3 | `+0x165c2e4` | `+0x1c07714` | `+0x165c238` | `+0x1c07664` | нет |
| `%s: Process %d is checking if a cdhash is in the trust cache\n` | `+0x1242` / `+0x11f7` (Δ-0x4b) | 1 | `+0x165c27c` | `+0x1c076ac` | `+0x165c238` | `+0x1c07664` | нет |
| `com.apple.private.amfi.can-check-trust-cache` | `+0x1f33` / `+0x1ee6` (Δ-0x4d) | — | — | — | — | — | — |
| `AMFI: research variant relaxes lock-state for trust caches: %u\n` | `+0x3009` / `+0x3023` (Δ+0x1a) | 1 | `+0x1660bf0` | `+0x1c0c4a4` | `+0x1660bac` | `+0x1c0c460` | нет |
| `amfi-allows-trust-cache-load` | `+0x3049` / `+0x3063` (Δ+0x1a) | 1 | `+0x1660c64` | `+0x1c0c518` | `+0x1660bac` | `+0x1c0c460` | нет |
| `AMFI: amfi-allows-trust-cache-load has unexpected size (%u).\n` | `+0x3066` / `+0x3080` (Δ+0x1a) | 1 | `+0x1660d10` | `+0x1c0c5c4` | `+0x1660bac` | `+0x1c0c460` | нет |
| `%s: loading duplicate trust cache (success)\n` | `+0x30a4` / `+0x30be` (Δ+0x1a) | 1 | `+0x1660d88` | `+0x1c0c640` | `+0x1660d48` | `+0x1c0c600` | нет |
| `%s: loading duplicate trust cache (success)\n` |  | 2 | `+0x166100c` | `+0x1c0c8cc` | `+0x1660fb4` | `+0x1c0c874` | нет |
| `loadTrustCacheWithExternalManifest` | `+0x30d1` / `+0x30eb` (Δ+0x1a) | 1 | `+0x1660d7c` | `+0x1c0c634` | `+0x1660d48` | `+0x1c0c600` | нет |
| `loadTrustCacheWithExternalManifest` |  | 2 | `+0x1660e6c` | `+0x1c0c724` | `+0x1660d48` | `+0x1c0c600` | нет |
| `loadTrustCacheWithExternalManifest` |  | 3 | `+0x1660e98` | `+0x1c0c750` | `+0x1660d48` | `+0x1c0c600` | нет |
| `loadTrustCacheWithExternalManifest` |  | 4 | `+0x1660ebc` | `+0x1c0c774` | `+0x1660d48` | `+0x1c0c600` | нет |
| `%s: loading trust caches disallowed by system state\n` | `+0x30f4` / `+0x310e` (Δ+0x1a) | 1 | `+0x1660e78` | `+0x1c0c730` | `+0x1660d48` | `+0x1c0c600` | нет |
| `%s: loading trust caches disallowed by system state\n` |  | 2 | `+0x16610d8` | `+0x1c0c998` | `+0x1660fb4` | `+0x1c0c874` | нет |
| `%s: attempted to load duplicate trust cache -- switching to success\n` | `+0x3129` / `+0x3143` (Δ+0x1a) | 1 | `+0x1660ea4` | `+0x1c0c75c` | `+0x1660d48` | `+0x1c0c600` | нет |
| `%s: attempted to load duplicate trust cache -- switching to success\n` |  | 2 | `+0x1661088` | `+0x1c0c948` | `+0x1660fb4` | `+0x1c0c874` | нет |
| `%s: unable to load trust cache: %d\n` | `+0x316e` / `+0x3188` (Δ+0x1a) | 1 | `+0x1660ec8` | `+0x1c0c780` | `+0x1660d48` | `+0x1c0c600` | нет |
| `%s: unable to load trust cache: %d\n` |  | 2 | `+0x16610bc` | `+0x1c0c97c` | `+0x1660fb4` | `+0x1c0c874` | нет |
| `loadTrustCacheWithType` | `+0x3192` / `+0x31ac` (Δ+0x1a) | 1 | `+0x1661000` | `+0x1c0c8c0` | `+0x1660fb4` | `+0x1c0c874` | нет |
| `loadTrustCacheWithType` |  | 2 | `+0x1661074` | `+0x1c0c934` | `+0x1660fb4` | `+0x1c0c874` | нет |
| `loadTrustCacheWithType` |  | 3 | `+0x16610cc` | `+0x1c0c98c` | `+0x1660fb4` | `+0x1c0c874` | нет |
| `trustCacheIsDuplicateImg4` | `+0x31e2` / `+0x31fc` (Δ+0x1a) | 1 | `+0x1660f38` | `+0x1c0c7f4` | `+0x1660ef0` | `+0x1c0c7ac` | нет |
| `AMFI: Failed to get trust cache UUID for %s (TCReturn: 0x%02X \| 0x%02X \| %u)\n` | `+0x3305` / `+0x332b` (Δ+0x26) | 1 | `+0x1661888` | `+0x1c0d1cc` | `+0x16617a4` | `+0x1c0d0d8` | нет |
| `AMFI: Failed to get trust cache type for %s: (TCReturn: 0x%02X \| 0x%02X \| %u)` | `+0x3353` / `+0x3379` (Δ+0x26) | 1 | `+0x16618cc` | `+0x1c0d210` | `+0x16617a4` | `+0x1c0d0d8` | нет |
| `Couldn't find trust cache UUID for process when mapping library from SMAC` | `+0x43b7` / `+0x441a` (Δ+0x63) | 1 | `+0x1664b1c` | `+0x1c1054c` | `+0x16645d0` | `+0x1c0fff8` | нет |
| `Couldn't find trust cache UUID for library from SMAC` | `+0x4401` / `+0x4464` (Δ+0x63) | 1 | `+0x1664930` | `+0x1c10360` | `+0x16645d0` | `+0x1c0fff8` | нет |
| `AMFI Trust Cache Interface` | `+0x4978` / `+0x4a6c` (Δ+0xf4) | — | — | — | — | — | — |
| `%s (pid %u) not allowed for Restricted Execution Mode state (%s): code is not present in any trustcache\n` | `+0x5ee2` / `+0x5fed` (Δ+0x10b) | 1 | `+0x1668a3c` | `+0x1c14754` | `+0x16688b0` | `+0x1c145b4` | нет |
| `%s not allowed for Restricted Execution Mode state (%s): code is not present in any trustcache` | `+0x6ab0` / `+0x6bbb` (Δ+0x10b) | 1 | `+0x166a77c` | `+0x1c16538` | `+0x166a3e0` | `+0x1c1615c` | нет |
| `trust-cache` | `+0x6bb2` / `+0x6cbd` (Δ+0x10b) | 1 | `+0x166a880` | `+0x1c1683c` | `+0x166a3e0` | `+0x1c1615c` | нет |
| `personalized.trust-cache` | `+0x9ead` (только x13) | — | — (нет xref) | — | — | — | — |