# 사용자 지정 CA 인증서

`vm ca` 명령은 실행 중인 게스트의 TrustStore에서 신뢰할 수 있는 루트 CA 인증서를 설치, 나열, 제거합니다. 시스템에 기본 포함되지 않은 인증서, 예를 들어 HTTPS 트래픽을 가로채는 프록시의 루트 인증서를 게스트가 신뢰하도록 하려는 경우에 사용합니다.

세 명령 모두 실행 중인 가상 머신과 통신하므로, 먼저 `vm launch`로 머신을 시작하세요. 가상 머신 이름은 아래 예시처럼 명시적으로 지정합니다. 필수 인수가 먼저, 가상 머신 이름이 뒤에 옵니다. 이름을 생략하면 라이브러리의 모든 가상 머신을(실행 중이든 아니든, 하나뿐이더라도) 나열하는 대화형 선택기가 나타나 선택하도록 요청합니다. 터미널이 없는 환경(스크립트, CI)에서는 명령이 `No VM name given, and this is not an interactive terminal` 오류로 실패하므로, 자동화에서는 항상 이름을 지정하세요.

## 설치

```sh
vphone-cli vm ca install <pem-file> <vm-name> [--admin] [--json]
```

단일 인증서가 담긴 PEM 파일(최대 64 KiB)을 신뢰할 수 있는 루트 CA로 게스트에 설치합니다. 다음 한 줄을 출력합니다.

```text
sha256<TAB>subject
```

| 옵션 | 의미 |
| --- | --- |
| `--admin` | 기본 사용자 도메인 대신 관리자(admin) 트러스트 도메인에 설치합니다. |
| `--json` | 한 줄 출력 대신 키를 정렬해 보기 좋게 정리한 JSON으로 `{sha256, subject, domain}`을 출력합니다. |

## 나열

```sh
vphone-cli vm ca list <vm-name>
```

설치된 앵커를 한 줄에 하나씩 `sha256<TAB>subject` 형식으로, sha256 순으로 정렬하여 나열합니다.

## 제거

```sh
vphone-cli vm ca remove <sha256> <vm-name>
```

`list`에 표시되는 64자리 16진수 sha256을 지정하여 해당 앵커를 제거합니다.

## 예시

HTTPS 트래픽을 가로채는 프록시의 루트 인증서를 게스트가 신뢰하도록 설치하고, 반영되었는지 확인한 뒤, 작업이 끝나면 제거합니다.

```sh
vphone-cli vm ca install proxy-ca.pem my-vm
vphone-cli vm ca list my-vm
vphone-cli vm ca remove 9f2b8c1d4e6a0f3b5c7d9e1a2b4c6d8e0f1a2b3c4d5e6f708192a3b4c5d6e7f8 my-vm
```

## 함께 보기

- [네트워크](overview.md)
- [터널 모드](tunnel.md)
