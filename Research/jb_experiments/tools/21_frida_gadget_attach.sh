#!/bin/sh
# Frida Gadget: проброс порта и подключение (этап 21). НЕ ЗАПУСКАЛИСЬ.
# Замените <UDID> и <bundle-id>. Терминал 1 — проброс, терминал 2 — запуск приложения,
# терминал 3 — клиент Frida. Останавливать в обратном порядке (Ctrl+C в 3, 2, 1).

# 0. Версии на этом Mac (Xcode 26.6, devicectl 518.33): iproxy 2.1.1 есть, frida нет.
#    Версия гаджета на устройстве должна совпадать с версией клиента, иначе клиент не подключится.
#    brew install frida            # CLI (или: pipx install frida-tools)
#    pip install 'frida==<версия гаджета>'   # Python-модуль, в свой venv
#    https://github.com/frida/frida/releases/tag/<версия>  -> frida-gadget-<версия>-ios-universal.dylib.xz

# 1. Идентификаторы (эти две команды выполнялись, вывод в 21_frida_devicectl_state.md)
xcrun devicectl list devices
idevice_id -l

# 2. Проброс 27042 на устройстве -> 27043 на Mac. Держать открытым.
#    USB:
iproxy -u '<UDID>' 27043:27042
#    Сеть (устройство и Mac в одной Wi-Fi сети, сопряжение по сети включено):
#    iproxy -n -u <UDID> 27043:27042
#    Эквивалент через pymobiledevice3 (не установлен):
#    pymobiledevice3 usbmux forward --udid <UDID> 27043 27042

# 3. Запуск приложения с гаджетом. Держать открытым: --console ждёт выхода приложения.
xcrun devicectl device process launch --device '<id>' --console \
  -e '{"DYLD_INSERT_LIBRARIES":"@executable_path/libgadget.dylib"}' '<bundle-id>'

# 4. Клиент. -q: выполнить и выйти; -t 5: дать 5 секунд на вывод.
frida -H 127.0.0.1:27043 -n Gadget -q -t 5 -e 'console.log(JSON.stringify({pid: Process.id, objc: ObjC.available, arch: Process.arch}));'
#    То же из Python:
#    import frida
#    d = frida.get_device_manager().add_remote_device("127.0.0.1:27043")
#    s = d.attach("Gadget")
#    s.create_script('send({pid: Process.id, objc: ObjC.available});').load()
