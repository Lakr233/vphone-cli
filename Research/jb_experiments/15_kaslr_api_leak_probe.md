# 15. Пробник утечки раскладки ядра через неинициализированные поля структур (host_info / proc_info / task_info / …)

Дата: 2026-11-26. Объекты: iPhone 13 (A15, 26.5.2 / 23F84) и iPhone 17 Pro Max (A19, 27.2.1 / 24B156) — железо; Basil VM (27.2 / 24B119) — для сравнения, тут метод не нужен.

Эта заметка — про **инструмент** и границы его применимости. Результаты прогона на железе — в `06_kaslr_probe_23F84.md` (сырой вывод `kprobe_13.txt`, `kprobe_17.txt`).

## 0. VM и железо — два разных случая

| | Basil (24B119) | Железо (23F84 / 24B156) |
|---|---|---|
| GDB-stub vphone | есть | нет |
| Слайд | **утечка не нужна**: `slide = (VBAR_EL1 & 0xffffffff) - 0x8cab000` (`13_kaslr_slide_and_kread.md`) | нужен свой источник |
| Чтение памяти ядра | `kcall10` + гаджет `ldr x0,[x0]; ret` | нужен примитив чтения |

На Basil слайд снимается через отладчик без всякой утечки. Пробник ниже имеет смысл только для железа: там GDB-stub нет, и слайд надо получать изнутри пользовательского процесса.

Диапазоны указателей ядра: A15 — `0xfffffff000000000…0xfffffff0ffffffff`; A19 — `0xfffffe0000000000…0xfffffe00ffffffff` (база ядра `0xfffffe00…`, та же, что в VBAR на Basil, `0xfffffe004c5d7000` и т. п.).

## 1. Методика

Источник: `HiItsMe2117/ios26-kernel-research`, `kaslr-bypass-research.md` (выгрузка в `ios26-kernel-research/`). Суть: некоторые flavors возвращают структуры, часть полей которых ядро не заполняет; если буфер не обнулён, в нём остаются старые данные — в том числе указатели.

Двухпроходный метод, как в исследовании:

1. Выделить буфер, заполнить `0xAA`.
2. Вызвать API, записать `rc` и реальный размер (`count * 4`).
3. Тот же вызов — во второй буфер.
4. Все 8-байтовые слова, попадающие в диапазон ядра, печатать со смещением; слово, которое отличается между буферами, — кандидат (`vary=1`).

| API | Flavors | Примечание |
|---|---|---|
| `host_info(mach_host_self(), …)` | 1–20 | |
| `host_statistics(…)` | 1–20 | |
| `host_statistics64(…)` | 1–20 | |
| `task_info(mach_task_self(), …)` | 1–20 | |
| `proc_info` | callnum 2 с flavors 1–20; callnum 2/3/4 с flavor 1 | `syscall(SYS_proc_info, …)` напрямую: в iOS SDK нет ни `libproc.h`, ни `sys/proc_info.h` |
| `host_processor_info(…)` | 1–20 | массив выделяет ядро → сравнение двух возвращённых массивов, `vm_deallocate` |
| `processor_info(PROCESSOR_NULL, flavor, …)` | 1–20 | в SDK нет объявления в `processor_info.h`, прототип берётся из `mach/processor.h`: порядок `(processor, flavor, host*, out, cnt)` |
| `mach_port_kernel_object` | task / host / свой receive-порт | `object_type` и `object_addr` — по `unsigned` (4 байта), влезает только половина адреса |
| `mach_vm_region_recurse` | своя задача | контроль, не утечка |

Формат вывода: `HIT <api> flavor=<n> rc=<r1>/<r2> size=<s> off=+<N> value=0x… other=0x… vary=<0|1>` и итог `SUMMARY <n> kernel-range hits, <m> varying`. Всё пишется в stdout и в `tmp/out.txt`, в конце `exit(0)`, чтобы `devicectl … --console` не ждал.

## 2. Инструмент

`tools/kprobe.m` — один файл, Objective-C (не Objective-C++: `extern "C"` не нужен), командная строка без UIKit.

`tools/kaslr_probe/` — обвязка для сборки: `project.yml` (xcodegen: iOS app, `me.strelov.kprobe`, deployment target 17.0, Automatic signing, team `25U9HN34VM`), `kprobe.entitlements` (`get-task-allow`), `LaunchScreen.storyboard` (ключ `UILaunchStoryboardName`, без него приложение не ставится). `project.yml` ссылается на `../kprobe.m`, копии исходника нет.

```sh
cd Research/jb_experiments/tools/kaslr_probe
xcodegen generate
xcodebuild -project kprobe.xcodeproj -scheme kprobe -sdk iphoneos -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/jbresearch/dd-kprobe \
  -allowProvisioningUpdates build
# .app: /tmp/jbresearch/dd-kprobe/Build/Products/Release-iphoneos/kprobe.app
```

`-allowProvisioningUpdates` обязателен: без него Xcode не создаёт профиль для нового bundle id (`No profiles for 'me.strelov.kprobe' were found`). Release, а не Debug: в Debug Xcode 26 кладёт код в `kprobe.debug.dylib`, а не в основной бинарер.

Сгенерированный `kprobe.xcodeproj` в репозиторий не кладём — он пересобирается из `project.yml`.

## 3. Что проверено

- Компиляция `arm64-apple-ios17.0` (SDK iPhoneOS 26.5, Xcode 26.6), линковка, codesign: `Apple Development: Ilya Strelov (SK48H7Y4X4)`, профиль `iOS Team Provisioning Profile: *`. Все нужные символы в `nm -u`: `_host_info`, `_host_statistics64`, `_host_processor_info`, `_task_info`, `_processor_info`, `_mach_port_kernel_object`, `_mach_vm_region_recurse`, `_syscall`.
- Info.plist: `CFBundleIdentifier=me.strelov.kprobe`, `MinimumOSVersion=17.0`, `UILaunchStoryboardName=LaunchScreen`; entitlements: `get-task-allow=true`, `application-identifier=25U9HN34VM.me.strelov.kprobe`.
- Сборка из репозитория (после переноса в `tools/kaslr_probe/`) — `BUILD SUCCEEDED`.
- Локальный контроль исполнения: тот же файл, скомпилированный под macOS, проходит все циклы, `SUMMARY 0 kernel-range hits, 0 varying` (на macOS адреса ядра скрываются — ожидаемо).
- Прогон на железе (не этим тредом): `06_kaslr_probe_23F84.md` — на обоих устройствах `SUMMARY 0 kernel-range hits, 0 varying`, неинициализированных хвостов за размером нет.

## 4. Что НЕ проверено

- **Установка и запуск на устройствах этим тредом** — не делались (по условию задачи). Прогоны в заметке 06 выполнены другим тредом; здесь они только процитированы.
- **Регистрация устройств в профиле** — wildcard-профиль команды `25U9HN34VM`; что оба UDID есть в его device list, этим тредом не проверялось.
- **`processor_info` с валидным `processor_t`** — не проверено и этим пробником недостижимо: `PROCESSOR_NULL` даёт `KERN_INVALID_ARGUMENT` (268435459), а `host_processors()` — приватный MIG. Все 20 flavors этого API — `rc≠0`, то есть **не результат**.
- **`proc_info` flavors 2–10, 12–20 по callnum 2** — `EPERM` (sandbox), а не чистый результат; на 17 Pro Max блокируется шире (54 `EPERM` против 6 на iPhone 13). Повторять после sandbox escape.
- **Flavors выше 20 и другие размеры буфера** — не перебирались. CVE-2026-65405 описан Apple как «определение раскладки памяти ядра», публичного PoC и точной точки входа нет.
- **Диапазон A19** взят из методики и VBAR Basil без отдельной проверки на железе.
- **`mach_port_kernel_object`** как источник — исключён самим прототипом: 4-байтовый `object_addr`, на macOS и в контроле — `0x0` (`VM_KERNEL_ADDRHIDE`). На iOS результат тот же (`obj_addr=0x0`, см. `kprobe_13.txt`).

## 5. Вывод: годится ли метод как источник слайда

- **Basil (24B119): метод не нужен.** Слайд снимается по `VBAR_EL1` через GDB-stub, чтение ядра — через `kcall10` (`13_kaslr_slide_and_kread.md`).
- **Железо 23F84 / 24B156: методом в том виде, как он перебирает flavors 1–20, слайд не получен.** Все вызовы, до которых добрался пробник, возвращают полностью заполненные структуры: ни одного слова в диапазоне ядра, ни одного меняющегося значения, хвост за размером — сплошной `0xAA`. Это не доказательство отсутствия утечки: `proc_info` (наиболее вероятный кандидат по CVE-2026-65405) закрыт sandbox, `processor_info` без валидного `processor_t` не вызывается, flavors > 20 не смотрели.
- Практическое следствие: для железа слайд надо искать либо после sandbox escape (повторить `proc_info`), либо в другой точке входа (описание CVE у STAR Labs; у автора `ios26-kernel-research` на момент выгрузки «probe pending»). Как самостоятельный первый шаг цепочки пробник не годится, но как быстрая проверка после escape — да: один запуск, `SUMMARY` сразу видно.

## 6. Файлы

| Файл | Что внутри |
|---|---|
| `tools/kprobe.m` | исходник пробника (тот же, что в `06_kaslr_probe_23F84.md`) |
| `tools/kaslr_probe/project.yml` | xcodegen-проект, ссылается на `../kprobe.m` |
| `tools/kaslr_probe/kprobe.entitlements` | `get-task-allow`, team `25U9HN34VM` |
| `tools/kaslr_probe/LaunchScreen.storyboard` | пустой launch screen |
| `06_kaslr_probe_23F84.md`, `kprobe_13.txt`, `kprobe_17.txt` | прогон на железе (другой тред) |
| `ios26-kernel-research/kaslr-bypass-research.md` | методика (чужое исследование, 26.6.1/A18) |
