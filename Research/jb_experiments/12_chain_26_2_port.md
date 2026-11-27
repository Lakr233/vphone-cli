# Порт цепочки 26.2 (lightsword, 23C55) на 23F84 / 24B156

Дата: 2026-11-26. Вариант выбран владельцем: «Порт цепочки 26.2».

## Итог

| Компонент 26.2 | 23F84 (iPhone 13) | 24B156 (17 Pro Max) | Статус |
|---|---|---|---|
| AIO-kevent UAF (track B / B12) | закрыт: статика + живой прогон | закрыт: статика | мёртв |
| IOGPU hash OOB (remove, шаг 8/4) | закрыт: статика | закрыт: статика | мёртв |
| IOMFB «CVE-2026-64788» | CVE перепутан: это IOGPUFamily web-content (64788), а OOB IOMFB = CVE-2026-64736 | — | перепроверить |
| WebKit DFG type confusion (W-T0) | не проверялся | не проверялся | отдельная работа |

Примитивов ядра из 26.2 в наших билдах не остаётся. AIO-kevent: knote держит ссылку на entry (`filt_aioattach`, `ldadd +1,[entry+0x2c]`), поэтому запись не освобождается, пока knote жив; `aio_return` на SIGEV_KEVENT-записи отдаёт EINVAL и ничего не освобождает. Живой прогон на iPhone 13: 20/20 событий идентичны контролю, ext1=0x100 (наша же запись A), значения B не всплывают.

## Доказательства

### AIO-kevent (S1: `ios26-kernel-research/evfilt_aio_23F84_24B156.md`, живой лог `/tmp/jbresearch/wq_x13/out_L13-aio.txt`)

- 23F84 `filt_aioattach` `0xfffffff00a2baf38`: `ldadd w9,w9,[entry+0x2c]` на `0x…bafc8` — knote берёт ref; `filt_aiodetach` `0x…badf8` его отпускает (`ldaddl -1` на `0x…baeac`) только из `knote_drop`, уже после `filt_aioprocess`.
- 24B156 то же (`0xfffffe000b1040e4`), плюс `aio_entry_unref` `0x…b103db0` паникует при непустом списке knote (`entry+0xc0`).
- `aio_return` пропускает SIGEV_KEVENT-записи (23F84 `0x…bd780 cmp w8,#4; b.eq`; 24B156 `0x…061b4`) и возвращает EINVAL — шаг «FREE» из PoC lightsword не освобождает запись.
- Живой прогон iPhone 13: `L13-aio RESULT: a (differ=0x0 saw_b_value=0x0)`, 20 повторов + 20 контролей.

### IOGPU hash OOB (S5: `ios26-kernel-research/iogpu_hash_oob.md`)

- Светящийся у lightsword store `str xzr` (23C55 `0x9f518f0`) в 23F84 `0x96111a0` / 24B156 `0xa094288` пишет в массив элементов с шагом 8 (`kalloc_type(cap<<3)`), а не в массив контрольных слов с шагом 4. Каждый доступ идёт с шагом, с которым массив аллоцирован.
- Индекс в remove маскируется `& (cap-1)`; grow даёт только `oldcap*2^k >= w1` при `oldcap >= 64`, поэтому capacity 1 недостижим. Код remove/grow/init одинаков в обоих билдах (нормализованный diff — только релокации и `bti`).
- Живой прогон IOGPU на iPhone 13 (`/tmp/jbresearch/wq_x13/out_L13-iogpu.txt`): клиент открывается (type 1, kr=0), cmd 3 (64) kr=0, cmd 130 kr=0 и повтор kr=0, id+1 → `0xe00002c2`, cmd 0 → `0xe00002be` (не дошёл до чтения: размер выходного дескриптора 0). То есть поверхность та же, что на 23C55, но примитива нет.

### IOMFB (S4: `ios26-kernel-research/iomfb_64788.md`)

- В advisory iOS 26.6.1 CVE-2026-64788 — это **IOGPUFamily** (web content, improved memory handling). OOB в **IOMobileFrameBuffer** — это **CVE-2026-64736** (Ruslan Dautov, hxr1), «app may … corrupt kernel memory». Записи 64/122 в `apple_advisory_entries_26.5.2_to_27.2.1.md` несут ту же путаницу — исправить.
- Селекторы IOMFB не вызывались: публичного PoC нет, а вслепую по неописанным селекторам — путь к панике, а не к данным.

## Что из этого следует

- Трек B12 и IOGPU-OOB больше не рассматривать для 23F84/24B156.
- Из 26.2 остаются только входы: WebKit (W-T0, renderer-примитив) и карта селекторов IOGPU (cmd 3/130/0 принимаются на 23F84).
- IOMFB: переоткрыть как CVE-2026-64736. Нужен дифф не 26.5.2↔27.2.1 (три релиза между ними), а 26.5.2 ↔ 26.6.1 по кексту IOMobileFramebuffer.

## Не сделано

- 17 Pro Max в момент тестов был `unavailable` (с 18:25), живые тесты на нём не шли; статика по 24B156 — есть.
- WebKit-цепочка не исследовалась.
