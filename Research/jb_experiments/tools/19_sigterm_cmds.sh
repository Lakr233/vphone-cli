#!/bin/sh
# Съём логов для этапа 19_sigterm_app_exit.md. НЕ ЗАПУСКАЛИСЬ: собраны из --help на Mac.
# Вывод — рядом в Research/jb_experiments/, а не в /tmp.
# UDID: idevice_id -l ; BUNDLE: bundle id приложения; PROC: имя процесса.
set -u
UDID="${UDID:?}" BUNDLE="${BUNDLE:?}" PROC="${PROC:?}"
OUT="$(cd "$(dirname "$0")/.." && pwd)"

# 0. Повторный запуск с диагностикой самого devicectl (файл 19_sigterm_launch.log не создан).
xcrun devicectl device process launch --verbose -l "$OUT/19_sigterm_launch.log" \
  --device "$UDID" --terminate-existing --console "$BUNDLE"

# 1. Живой лог с устройства: кто завершает процесс.
idevicesyslog -u "$UDID" -m "$BUNDLE" -o "$OUT/19_syslog_$UDID.txt"
# дополнительно по процессам системы (имена по документации, не сверялись с реальным логом):
idevicesyslog -u "$UDID" -p SpringBoard -p runningboardd -o "$OUT/19_syslog_rb_$UDID.txt"

# 2. То же без --console: сравнить время жизни приложения.
xcrun devicectl device process launch --device "$UDID" --terminate-existing \
  --json-output "$OUT/19_launch_$UDID.json" "$BUNDLE"

# 3. NSLog без --console.
idevicesyslog -u "$UDID" -p "$PROC" -o "$OUT/19_nslog_$UDID.txt"

# 4. Архив системного лога (читать в Console.app), если живого лога не хватило.
log collect --device-udid "$UDID" --last 10m --output "$OUT/19_sys_$UDID.logarchive"

# 5. Отчёты о сбоях и Jetsam (SIGKILL), не удаляя их с устройства.
idevicecrashreport -u "$UDID" -k -e -f "$PROC" "$OUT/19_crash_$UDID"

# Поиск по собранному:
# grep -n -i -E 'signal 15|termination|RBSTerminate|FBSOpenApplication' "$OUT"/19_*
