<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <a href="README_ja.md">日本語</a> · <strong>한국어</strong> · <a href="README_ru.md">Русский</a> · <a href="README_pt.md">Português</a></div>

# vphone-cli

Apple Virtualization.framework와 PCC 연구용 VM 기반으로 가상 iPhone을 부팅합니다.

![macOS에서 실행 중인 가상 iPhone](demo.jpeg)

공개 펌웨어 흐름은 **JB 한 가지**입니다. 필요한 시스템 패치와 호스트 제어용 vphoned를 설치합니다. 게스트 사용자 환경은 그대로 두며 패키지 관리자, SSH, VNC 또는 첫 부팅 bootstrap은 설치하지 않습니다.

## 빠른 시작

Apple Silicon Mac, macOS 15 이상, 그리고 PV=3 연구용 VM과 `vphone-vm` 권한을 허용하는 [호스트 설정](guides/host-setup.md)이 필요합니다.

```sh
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw

vphone-cli vm launch myphone
```

`vm create`는 준비, JB 패치, DFU 복원, CFW 설치를 수행하고 첫 부팅에서 vphoned에 실제로 ping합니다. **검증용 부팅은 성공 후 종료됩니다.** 계속 사용하려면 `vm launch`를 실행하세요. 복원에는 네트워크가, CFW 설치에는 관리자 인증이 필요합니다.

cloudOS 26.4(`23E5207q`)와 함께 iPhone17,3 iOS 26.6.2(`23G90`), 27.0(`24A435`)이 잠금 화면에 도달하고 vphoned ping에 응답했습니다. 범위는 [호환성 기록](guides/compatibility.md)을 참고하세요.

## 설치와 빌드

배포된 `.app` 실행에는 Homebrew, Python, Xcode나 별도의 런타임 환경이 필요하지 않습니다. 소스 빌드에는 vphoned용 iPhoneOS SDK가 포함된 Xcode가 필요합니다.

```sh
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
make build
.build/release/vphone-cli host preflight
```

AMFI 허용 목록을 사용하는 호스트에서는 빌드할 때마다 `make amfi_allow`를 다시 실행하세요. 현재 가이드와 연구 자료는 [문서 목차](README.md)에 모았습니다. 상세 가이드는 현재 영어로 제공됩니다.
