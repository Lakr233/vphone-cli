# tools/dylib_load_fs_diag

Исходники из треда `thr_itairhc6yq`, заметка `../../18_dylib_load_fs_diag.md`.

| Файл | Откуда | Статус |
|---|---|---|
| `fs_diag.m` | дословно два фрагмента из чата треда | не собирался, не запускался; в `ScanInodePaths` есть ошибки (раздел 2 заметки) |
| `libprobe.c` | копия `/tmp/jbresearch/wq/libprobe.c` (26.11, 14:26) — фрагмент 3 из того же чата, перенесён родительским тредом | исходник рабочий: его сборка загрузилась и напечатала строку (см. `run1_parent_LIBLOADED.log`) |
| `run1_parent_LIBLOADED.log` | копия `/tmp/jbresearch/run1.log` | вывод прогона, выполненного в родительском треде, не в `thr_itairhc6yq`; на каком устройстве — в этом треде неизвестно |

Сборка `libprobe.dylib` (не выполнялась в этом треде):

```bash
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=15.0 -dynamiclib -o libprobe.dylib libprobe.c
codesign -s "Apple Development: <имя>" libprobe.dylib
```
