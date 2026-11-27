# 17 — Как устроен vphone-cli: корень доверия, boot chain, SEP, запуск гостя

Дата: 2026-11-26. Только чтение кода и файлов машины `~/.vphone/machines/Basil`;
ничего не собиралось, не патчилось и не запускалось. Коммит `b37d196`.

Границы с соседними отчётами (здесь не повторяются):

- `V1_result.md` — поимённый разбор патчей ядра/TXM (§3–4) и идентичность
  `vresearch101` (§5).
- `V2_result.md` — доступ к госту Basil с хоста.

Вопрос файла: какие механизмы vphone существуют только потому, что гость —
VM под Virtualization.framework, а что переносится на физическое устройство.

---

## 0. Кратко

| Уровень | Кто проверяет подпись в VM | Чем подменено | На железе |
|---|---|---|---|
| BootROM (AP) | **никто** | OpenAVB не проверяет digest; Apple ROM — патч DGST | ROM в кремнии, ключ в OTP |
| SEP ROM | проверяет, **не enforcing** | OpenSEP без `OPEN_SECURE_ROM_ENFORCE_IMAGE_TRUST` | ROM в кремнии |
| iBSS / iBEC / LLB | сам iBoot | `image4_validate_property_callback` → 0 | LLB должен быть подписан Apple |
| iBoot, SPTM | LLB | **не патчатся** | подписаны Apple |
| TXM, kernelcache, DT | LLB | патчатся на диске | тот же барьер, что строка 1 |
| System, dyld cache | ядро (AMFI/Sandbox) | перезапись на диске (`cfw install`) | нужен работающий JB |

Главный факт: **в vphone нет эксплойта и нет эмуляции SPTM/TXM/PPL.** Всё, что
выглядит как обход, — байтовые патчи образов *до загрузки*. Они принимаются
потому, что корень доверия подменён на хосте.

---

## 1. Корень доверия: два подменённых ROM

### 1.1 BootROM: OpenAVB

`config.plist` машины задаёт `romImages.avpBooter` (у Basil — `OpenAVB.bin`) и
передаётся загрузчику через приватный сеттер:

```swift
// VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/VPhoneVirtualMachine.swift
186  let bootloader = VZMacOSBootLoader()
187  if let romURL = options.romURL {
188      Dynamic(bootloader)._setROMURL(romURL)
```

OpenAVB не проверяет digest образа, поэтому патч `avpbooter-boot-dgst_bypass` для
него не нужен (`Research/Firmware/openavb_boot_rom.md:32-36`). Что он делает:
читает LLB, проверяет формат IMG4 и наличие манифеста, публикует SHA-384 LLB
для LocalPolicy iBoot'а (`:40-43`).

На старых машинах с Apple `AVPBooter.vresearch1.bin` — DGST-патч: `mov x0,#0`
в эпилоге функции проверки (`FirmwarePatcher/AVPBooter/AVPBooterPatcher.swift:5-12`).

### 1.2 SEP ROM: OpenSEP

`romImages.avpSEPBooter = OpenSEP.bin`; подключается как coprocessor с подменённым
ROM и GDB-стабом (`VPhoneVirtualMachine.swift:341-347`).

- OpenSEP проверяет цепочку сертификатов SEP-прошивки, **логирует и грузит
  дальше**: сборка без `OPEN_SECURE_ROM_ENFORCE_IMAGE_TRUST`
  (`Research/Firmware/opensep_sep_rom.md:72-76`).
- На seed-запросы отвечает константой `0xdeadbeef` (`:68`) — секрет SEP не
  привязан к машине.
- `SEPStorage` — файл: секрет, A/B-записи с ECID и boot-manifest hash,
  anti-replay (`Research/Host/machine_identity_and_clone.md`, «Where identity lives»).

---

## 2. Chain of trust в госте: что и где патчится

### 2.1 Откуда компоненты

Гибрид трёх IPSW (`Research/Firmware/firmware_manifest_and_origins.md:70-116`):

| Компонент | Источник | Патчится |
|---|---|---|
| iBSS, iBEC, LLB | PCC `vresearch101ap`, RELEASE | да |
| iBoot | PCC `vresearch101ap`, RESEARCH_RELEASE | **нет** |
| SPTM | PCC, PROD | нет |
| TXM | PCC, research (`txm.iphoneos.research.im4p`) | да |
| DeviceTree, SEP fw | PCC `vphone600ap` | DT — да, SEP fw — нет |
| kernelcache | `kernelcache.research.vphone600` | да |
| ОС, trust cache | iPhone17,3 | пересобирается |

Идентичность для TSS — `vresearch101ap` (BDID 0x90); `vphone600ap` (BDID 0x91)
TSS не подписывает (`firmware_manifest_and_origins.md:140-144`).

### 2.2 Патчи — на диске, до загрузки

`FirmwarePipeline` (`FirmwarePatcher/Pipeline/FirmwarePipeline.swift`): порядок
AVPBooter → iBSS → iBEC → LLB → TXM → Kernel → DeviceTree (`:5`); `load` —
распаковка IM4P, `save` — обратная упаковка в исходный контейнер (`:57-63`).
Основной цикл — `:367-432`: оригинал из `FirmwareOriginals/`, патч в буфере,
запись в тот же файл. Ни одного изменения в памяти гостя.

### 2.3 Что патчится в iBoot-стадиях

`IBootPatcher.swift:23-25` (режимы ibss/ibec/llb), `:31` boot-args
`serial=3 -v debug=0x2014e %s`, `apply()` — `:100`. Состав —
`Research/Firmware/iboot_patches.md:48-67`: serial, image4 callback, boot-args,
rootfs bypass, panic bypass, skip generate_nonce.

Ключевой — `IBootPatchImage4Callback.swift:11-12`: `b.ne → NOP`,
`mov x0,x22 → mov x0,#0`. LLB теперь принимает любой payload под любым IM4M.

### 2.4 Почему TSS/SHSH не мешает

Restore идёт через настоящий idevicerestore с настоящим TSS для личности
`vresearch101ap` (`Research/Restore/native_restore_architecture.md:13, 151-152`).
IM4M подписывает digest'ы, а проверяют digest'ы подменённый ROM и пропатченный
LLB. `ManifestHashPatcher` пересчитывает digest в `BuildManifest.plist`
(`FirmwarePatcher/Manifest/ManifestHashPatcher.swift:32-43`). Альтернативный
путь — `cfw update-kernel` меняет kernelcache в Preboot, сохраняя исходный
подписанный IM4M (`Research/0_binary_patch_comparison.md:4494-4511`).

---

## 3. Что на железе этим НЕ снимается

Условие всех пунктов: vphone снимает проверки **только внутри VM с подменённым
BootROM/SEP ROM и пропатченным LLB**.

| # | Проверка на физическом iPhone | Почему патч vphone её не снимает |
|---|---|---|
| 1 | BootROM → LLB (и iBSS в DFU): подпись по корню в OTP | ROM в кремнии; DGST-патч и OpenAVB неприменимы. Нужен эксплойт *до* LLB |
| 2 | DFU: подпись iBSS, привязка APTicket к ECID/nonce | nonce контролирует BootROM; `skip_generate_nonce` меняет только iBSS |
| 3 | SEP ROM → SEPOS | OpenSEP не enforcing; SEP ROM в кремнии |
| 4 | LLB → iBoot/SPTM/TXM/kernel/DT (Image4) | подлинный LLB проверяет; callback → 0 неприменим без п.1 |
| 5 | Sealed root volume | на железе проверяется до ядра; `llb-boot-rootfs` неприменим |
| 6 | SPTM/PPL | в VM **работает**, охраняя уже пропатченный код; эмуляции нет |
| 7 | TXM: trust cache, dev mode, get-task-allow, launch constraints | `TXMDevPatcher.swift:303-802` пишет в файл; на железе нужен п.4 |
| 8 | AMFI в ядре, Sandbox MACF | то же: `kernel-boot-*` — патчи файла |
| 9 | `kcall10` (`sysent[439]`, `0_binary_patch_comparison.md:2105`) | этой syscall в железном ядре нет; добавить = писать в ядро = п.6 |
| 10 | Baseband signing при restore | «A virtual iPhone has no baseband» (`native_restore_architecture.md:97-98`) |

Первый эшелон — BootROM и SEP ROM. Второй (п.4–9) снимается только после первого.

Упоминаний о переносе на железо в репозитории нет: поиск `checkm8`, `checkm30`,
`blackbird`, `SSHRD`, `port-to-hardware` в `Research/`, `README`, `AGENTS.md`
даёт только совпадения о поведении гостевых сервисов на «real device».

---

## 4. `vresearch101`: что это и что снимает

Идентичность (BDID 0x90, CPID FE01, research-entitlement на хосте) разобрана в
`V1_result.md` §5.1–5.2; здесь только связь с корнем доверия.

- `platformType` в `config.plist` имеет единственное значение `vresearch101`
  (`VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneVirtualMachineManifest.swift:78-79, 176`).
- Аппаратная модель — приватный `_VZMacHardwareModelDescriptor` PV=3, boardID 0x90
  (`VPhoneVirtualMachineHardwareModel.swift:19-24`); PV=3 требует
  `com.apple.private.virtualization.security-research` (`:5-13`).
- Это даёт research-сборки **внутри цепочки**: research-TXM и research-ядро,
  которые подписывает Apple и под чью личность TSS выдаёт APTicket.

Иными словами: vresearch101 — не «ослабленный iPhone», а платформа, чей BootROM
на хосте заменён, а research-TXM/kernelcache для неё подписаны Apple.

---

## 5. Запуск гостя

`VPhoneVirtualMachine.init` (`VPhoneVirtualMachine.swift:95-355`):

- `machineIdentifier` (= ECID) загружается или создаётся и сохраняется в
  `config.plist` (`:95-111`).
- `VZMacPlatformConfiguration`: hardwareModel PV=3, auxiliaryStorage = `nvram.bin`
  (`:130-177`).
- Boot-args гость берёт из iBEC/LLB-патча, а не из NVRAM-стора хоста (`:179-184`).
- Загрузчик `VZMacOSBootLoader` + `_setROMURL` (`:186-189`); SEP-coprocessor с
  OpenSEP (`:341-347`); GDB-стаб ядра — опционально (`:322-337`).
- `VPhoneBootCommand+VirtualMachine.swift:12-40`: manifest → `Options` (disk,
  ROM, SEP storage/ROM, screen, kernel debug port, семейство гостя).

Поток: OpenAVB → LLB (`nvram.bin`) → iBoot (не патчится) → SPTM → TXM → patched
kernel → OS.

---

## 6. Что подтверждено и что нет

### Подтверждено кодом

- ROM задаётся файлом: `_setROMURL` (`VPhoneVirtualMachine.swift:186-189`) и
  `setRomBinaryURL` для SEP (`:341-343`).
- OpenAVB не проверяет digest (`openavb_boot_rom.md:32-36`); OpenSEP не
  enforcing (`opensep_sep_rom.md:72-76`).
- Все патчи — в файлы на диске до загрузки (`FirmwarePipeline.swift:5, 57-63,
  367-432`).
- iBoot и SPTM не патчатся (`firmware_manifest_and_origins.md:72-90`).
- Эмуляции SPTM/TXM/PPL в коде нет: компоненты пайплайна —
  `AVPBooter, iBSS, iBEC, LLB, TXM, KernelCache, DeviceTree`
  (`FirmwarePipelineComponents.swift:181-453`); TXM — настоящий бинарник Apple,
  патченный на диске.

### НЕ подтверждено

- **Содержимое `OpenAVB.bin` / `OpenSEP.bin`**: я не читал бинарники и не сверял
  с исходниками owngoal-dev; вывод о «не проверяет подпись» взят из документа
  `openavb_boot_rom.md` и `opensep_sep_rom.md`, а не из кода ROM.
- **«Entropy = `0xdeadbeef`»** — только по `opensep_sep_rom.md:68`; поведение SEPOS
  при этом не проверялось.
- **Утверждение `machine_identity_and_clone.md`**, что ECID в ticket игнорируется
  цепочкой, — по документу, не по serial-логу.
- **Значения `CPFM`/`SDOM`** не сверялись с документацией Apple (как и в `V1_result.md`).
- **Нюанс `kernel-boot-amfi_execve`**: в `PatchReceipt` Basil он есть, но
  `patchAmfiExecveKillPath` нигде не вызывается; работает
  `patchExecSecurityPolicyKill` (`KernelCustomFirmwarePatcher.swift:216`). Для
  железа это ничего не меняет — оба патча файловые.

### Переносимость (при наличии внешнего JB)

| Что | Условие |
|---|---|
| Карта патчей ядра/TXM: какие функции и инструкции менять | уже имеющиеся kernel r/w и обход SPTM |
| Гостевые dylib, `vphoned`, инструменты гостя | работающий `task_for_pid` / порт→map |
| Подмена ROM, `image4 callback`, `skip_generate_nonce`, `llb-boot-rootfs` | только research-устройство или эксплойт BootROM — в vphone ни того, ни другого нет |
