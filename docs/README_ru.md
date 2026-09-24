<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <a href="README_ja.md">日本語</a> · <a href="README_ko.md">한국어</a> · <strong>Русский</strong> · <a href="README_pt.md">Português</a></div>

# vphone-cli

Запускает виртуальный iPhone через Apple Virtualization.framework и исследовательскую инфраструктуру PCC VM.

![Виртуальный iPhone на macOS](demo.jpeg)

Публичный режим прошивки теперь **только JB**. Он применяет необходимые системные патчи и устанавливает vphoned для управления с хоста. Пользовательское окружение гостя остаётся пустым: менеджер пакетов, SSH, VNC и bootstrap при первом запуске не устанавливаются.

## Быстрый старт

Нужен Mac с Apple Silicon и macOS 15 или новее. Хост должен разрешать исследовательские PV=3 VM и приватные разрешения `vphone-vm`; см. [настройку хоста](guides/host-setup.md).

```sh
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw

vphone-cli vm launch myphone
```

`vm create` подготавливает и патчит прошивку, выполняет DFU-восстановление, устанавливает CFW и проверяет настоящий ping к vphoned при первом запуске. **После успешной проверки VM останавливается.** Для дальнейшей работы выполните `vm launch`. Восстановлению нужен доступ к сети, установке CFW — права администратора.

С cloudOS 26.4 (`23E5207q`) проверены iPhone17,3 iOS 26.6.2 (`23G90`) и 27.0 (`24A435`): обе VM дошли до экрана блокировки и ответили на ping vphoned. Границы проверки описаны в [таблице совместимости](guides/compatibility.md).

## Установка и сборка

Готовому `.app` для запуска не нужны Homebrew, Python, Xcode или отдельное окружение. Для сборки из исходников требуется Xcode с iPhoneOS SDK для vphoned.

```sh
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
zsh scripts/build.sh
.build/release/vphone-cli host preflight
```

Если хост использует список разрешений AMFI, после каждой сборки заново разрешайте подписанные бинарные файлы VM по [инструкции по настройке хоста](guides/host-setup.md). Актуальные руководства и исследовательские заметки собраны в [оглавлении](README.md). Подробные руководства пока доступны на английском.
