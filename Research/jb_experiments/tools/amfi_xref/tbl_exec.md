### 2. Exec-политика (entitlement-ключи, developer mode, cs_enforcement, task ports)
| строка | смещ. x13 / x17 | # | xref x13 | xref x17 | пролог x13 | пролог x17 | xref совп. |
|---|---|---|---|---|---|---|---|
| `com.apple.private.security.no-container` | `+0x2237` / `+0x21ea` (Δ-0x4d) | — | — | — | — | — | — |
| `com.apple.system-task-ports` | `+0x2374` / `+0x2327` (Δ-0x4d) | — | — | — | — | — | — |
| `com.apple.system-task-ports.control` | `+0x2390` / `+0x2343` (Δ-0x4d) | 1 | `+0x166a2b4` | `+0x1c1602c` | `+0x166a06c` | `+0x1c15de4` | нет |
| `com.apple.system-task-ports.control` |  | 2 | `+0x166c94c` | `+0x1c189cc` | `+0x166c874` | `+0x1c188f4` | нет |
| `dynamic-codesigning` | `+0x240f` / `+0x23c2` (Δ-0x4d) | 1 | `+0x166acdc` | `+0x1c165a4` | `+0x166a3e0` | `+0x1c1615c` | нет |
| `dynamic-codesigning` |  | 2 | `+0x166c794` | `+0x1c18810` | `+0x166c6dc` | `+0x1c18758` | нет |
| `get-task-allow` | `+0x2423` / `+0x23d6` (Δ-0x4d) | 1 | `+0x16647f0` | `+0x1c10218` | `+0x16645d0` | `+0x1c0fff8` | нет |
| `get-task-allow` |  | 2 | `+0x1668e68` | `+0x1c14b80` | `+0x16688b0` | `+0x1c145b4` | нет |
| `get-task-allow` |  | 3 | `+0x166c8b4` | `+0x1c18934` | `+0x166c874` | `+0x1c188f4` | нет |
| `get-task-allow` |  | 4 | `+0x166ca14` | `+0x1c18a98` | `+0x166c9f0` | `+0x1c18a74` | нет |
| `get-task-allow` |  | 5 | `+0x166cfbc` | `+0x1c190e8` | `+0x166cf20` | `+0x1c1904c` | нет |
| `task_for_pid-allow` | `+0x244d` / `+0x2400` (Δ-0x4d) | 1 | `+0x166a2a0` | `+0x1c16018` | `+0x166a06c` | `+0x1c15de4` | нет |
| `task_for_pid-allow` |  | 2 | `+0x166c970` | `+0x1c189f0` | `+0x166c874` | `+0x1c188f4` | нет |
| `run-unsigned-code` | `+0x2676` / `+0x2629` (Δ-0x4d) | — | — | — | — | — | — |
| `developer mode status` | `+0x3937` / `+0x395d` (Δ+0x26) | — | — | — | — | — | — |
| `developer mode status has been resolved` | `+0x3965` / `+0x398b` (Δ+0x26) | — | — | — | — | — | — |
| `AMFI: delaying developer mode latching...\n` | `+0x3b3b` / `+0x3b9e` (Δ+0x63) | 1 | `+0x1663348` | `+0x1c0ed34` | `+0x1663040` | `+0x1c0ea20` | нет |
| `AMFI: [2] informing daemon of developer mode state change` | `+0x3bb6` / `+0x3c19` (Δ+0x63) | 1 | `+0x1663810` | `+0x1c0f208` | `+0x16637c8` | `+0x1c0f1c0` | нет |
| `AMFI: Developer Mode is off (%i)\n` | `+0x3d4a` / `+0x3dad` (Δ+0x63) | 1 | `+0x1663b3c` | `+0x1c0f544` | `+0x1663b0c` | `+0x1c0f514` | нет |
| `AMFI: Enabling developer mode since we are restoring....\n` | `+0x3e00` / `+0x3e63` (Δ+0x63) | 1 | `+0x16635c8` | `+0x1c0efb8` | `+0x16633a4` | `+0x1c0ed94` | нет |
| `AMFI: Enabling developer mode since protected data is not available\n` | `+0x3e3a` / `+0x3e9d` (Δ+0x63) | 1 | `+0x1663628` | `+0x1c0f018` | `+0x16633a4` | `+0x1c0ed94` | нет |
| `AMFI: Disable developer mode since we couldn't get mobile obliteration status\n` | `+0x3e7f` / `+0x3ee2` (Δ+0x63) | 1 | `+0x16635fc` | `+0x1c0efec` | `+0x16633a4` | `+0x1c0ed94` | нет |
| `AMFI: Enabling developer mode since we are in mobile obliteration\n` | `+0x3ece` / `+0x3f31` (Δ+0x63) | 1 | `+0x1663654` | `+0x1c0f044` | `+0x16633a4` | `+0x1c0ed94` | нет |
| `AMFI: developer mode is enabled in the trusted darwinos research variant\n` | `+0x3f11` / `+0x3f74` (Δ+0x63) | 1 | `+0x1663678` | `+0x1c0f068` | `+0x16633a4` | `+0x1c0ed94` | нет |
| `AMFI: developer mode is force enabled\n` | `+0x3f5b` / `+0x3fbe` (Δ+0x63) | 1 | `+0x1663698` | `+0x1c0f088` | `+0x16633a4` | `+0x1c0ed94` | нет |
| `AMFI: trying to get developer mode status from ACM\n` | `+0x3f82` / `+0x3fe5` (Δ+0x63) | 1 | `+0x16636c4` | `+0x1c0f0b4` | `+0x16633a4` | `+0x1c0ed94` | нет |
| `AMFI: Developer Mode Is On\n` | `+0x3fe6` / `+0x4049` (Δ+0x63) | 1 | `+0x1663718` | `+0x1c0f108` | `+0x16633a4` | `+0x1c0ed94` | нет |
| `AMFI: Developer Mode can not be enabled on trusted darwinOS.\n` | `+0x4002` / `+0x4065` (Δ+0x63) | 1 | `+0x16636ac` | `+0x1c0f09c` | `+0x16633a4` | `+0x1c0ed94` | нет |
| `AMFI: [1] informing daemon of developer mode state change` | `+0x4198` / `+0x41fb` (Δ+0x63) | 1 | `+0x1663d68` | `+0x1c0f778` | `+0x1663d14` | `+0x1c0f724` | нет |
| `com.apple.security.get-task-allow` | `+0x469e` / `+0x4701` (Δ+0x63) | 1 | `+0x1664808` | `+0x1c10230` | `+0x16645d0` | `+0x1c0fff8` | нет |
| `com.apple.system-task-ports.token.control` | `+0x4935` / `+0x4a29` (Δ+0xf4) | 1 | `+0x166c5d0` | `+0x1c18648` | `+0x166c4f4` | `+0x1c1856c` | нет |
| `AMFI: profile disallowed due to developer mode\n` | `+0x5849` / `+0x593d` (Δ+0xf4) | 1 | `+0x1667f68` | `+0x1c13be0` | `+0x1667c94` | `+0x1c1390c` | нет |
| `cs_enforcement_disable` | `+0x6545` / `+0x6650` (Δ+0x10b) | 1 | `+0x1669398` | `+0x1c150d4` | `+0x1669300` | `+0x1c1503c` | нет |
| `%s: cs_enforcement disabled by boot-arg\n` | `+0x655c` / `+0x6667` (Δ+0x10b) | 1 | `+0x16693c4` | `+0x1c15100` | `+0x1669300` | `+0x1c1503c` | нет |
| `"can't has cs_enforcement_disable" @%s:%d` | `+0x65b9` / `+0x66c4` (Δ+0x10b) | 1 | `+0x1683654` | `+0x1c30ae8` | `+0x1683634` | `+0x1c30ac8` | нет |
| `AMFI: allowing pid %u to inherit IPC ports (get-task-allow)\n` | `+0x6841` / `+0x694c` (Δ+0x10b) | 1 | `+0x166a16c` | `+0x1c15ee4` | `+0x166a06c` | `+0x1c15de4` | нет |
| `com.apple.system-task-ports.read` | `+0x68b9` / `+0x69c4` (Δ+0x10b) | 1 | `+0x166a2c8` | `+0x1c16040` | `+0x166a06c` | `+0x1c15de4` | нет |
| `com.apple.system-task-ports.read` |  | 2 | `+0x166c91c` | `+0x1c1899c` | `+0x166c874` | `+0x1c188f4` | нет |
| `com.apple.system-task-ports.inspect` | `+0x68da` / `+0x69e5` (Δ+0x10b) | 1 | `+0x166a2dc` | `+0x1c16054` | `+0x166a06c` | `+0x1c15de4` | нет |
| `com.apple.system-task-ports.inspect` |  | 2 | `+0x166c8e4` | `+0x1c18964` | `+0x166c874` | `+0x1c188f4` | нет |
| `The system only allows platform binaries until developer mode status has been resolved, and the code is not a platform binary\n` | `+0x6d72` / `+0x6fa4` (Δ+0x232) | 1 | `+0x166aec0` | `+0x1c1675c` | `+0x166a3e0` | `+0x1c1615c` | нет |
| `Developer mode is disabled, %*.s is disallowed` | `+0x6f74` / `+0x71a6` (Δ+0x232) | 1 | `+0x166cfb0` | `+0x1c190dc` | `+0x166cf20` | `+0x1c1904c` | нет |
| `AMFI: '%s': has developer signature (%#llx) but developer mode is not enabled\n` | `+0x7213` / `+0x7432` (Δ+0x21f) | 1 | `+0x166b08c` | `+0x1c16fd8` | `+0x166a3e0` | `+0x1c1615c` | нет |
| `com.apple.system-task-ports.token.corpse` | `+0x85a4` / `+0x859f` (Δ-0x5) | 1 | `+0x166c580` | `+0x1c185f8` | `+0x166c4f4` | `+0x1c1856c` | нет |
| `com.apple.system-task-ports.token.inspect` | `+0x85cd` / `+0x85c8` (Δ-0x5) | 1 | `+0x166c524` | `+0x1c1859c` | `+0x166c4f4` | `+0x1c1856c` | нет |
| `com.apple.system-task-ports.token.read` | `+0x85f7` / `+0x85f2` (Δ-0x5) | 1 | `+0x166c550` | `+0x1c185c8` | `+0x166c4f4` | `+0x1c1856c` | нет |
| `com.apple.system-task-ports.token.read` |  | 2 | `+0x166c5ac` | `+0x1c18624` | `+0x166c4f4` | `+0x1c1856c` | нет |
| `%s: process %d attempted to use MAP_JIT but developer mode status has not been resolved!\n` | `+0x86cf` / `+0x86ca` (Δ-0x5) | 1 | `+0x166c814` | `+0x1c18890` | `+0x166c6dc` | `+0x1c18758` | нет |
| `AMFI: task_for_pid() not allowed\n` | `+0x8774` / `+0x876f` (Δ-0x5) | 1 | `+0x166c9d0` | `+0x1c18a50` | `+0x166c874` | `+0x1c188f4` | нет |
| `AMFI: developer mode is disabled, processes can not run invalid.` | `+0x8796` / `+0x8791` (Δ-0x5) | 1 | `+0x166ca60` | `+0x1c18ae4` | `+0x166c9f0` | `+0x1c18a74` | нет |