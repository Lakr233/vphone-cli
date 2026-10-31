#!/bin/zsh
# orient.zsh <UIDeviceOrientation 1-4>: BKSHIDServicesSetDeviceOrientationForAutomation from inside SpringBoard, then wait.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
$root/tools/probe.zsh duo-baseline-display SpringBoard - <<EOT >/dev/null 2>&1
expr -l objc -O -- ((void (*)(long long))dlsym(RTLD_DEFAULT, "BKSHIDServicesSetDeviceOrientationForAutomation"))($1); @"called"
EOT
sleep ${ORIENT_SETTLE:-4}
