# 여러 머신 만들기

`vm create-bulk`는 plist에 기술된 모든 머신을 순서대로 만듭니다. 파일 하나로 실험실이나 CI용 머신 여러 대를 준비할 때 사용하세요.

## 실행하기

```sh
vphone-cli vm create-bulk list.plist --dry-run   # print each machine's vm create command
vphone-cli vm create-bulk list.plist
```

`vm create`와 마찬가지로, 빌드가 필요한 머신이 있으면 `sudo`로 실행하세요.

## 목록 작성하기

```xml
<dict>
	<key>version</key>        <integer>1</integer>
	<key>defaults</key>
	<dict>
		<key>library-root</key>   <string>~/vphone-lab</string>
		<key>iphone-version</key> <string>26.1</string>
		<key>preset</key>         <string>presets/lab.plist</string>
		<key>cpu</key>            <integer>4</integer>
	</dict>
	<key>machines</key>
	<array>
		<dict><key>name</key> <string>ci-1</string></dict>
		<dict><key>name</key> <string>ci-2</string></dict>
		<dict>
			<key>name</key>         <string>fuzz</string>
			<key>iphone-build</key> <string>23F77</string>
			<key>iphone-version</key> <false/>
			<key>no-template</key>  <true/>
		</dict>
	</array>
</dict>
```

- 각 키는 `vm create` 옵션의 긴 이름이며, 값은 문자열이나 정수, 플래그는 `true`, `keep-apps`는 배열입니다.
- `defaults`는 모든 머신에 적용됩니다. 머신 자체의 키가 우선하며, `false`는 기본값을 지웁니다.
- 상대 경로는 plist가 있는 폴더를 기준으로 해석됩니다.
- `library-root`는 머신을 다른 보관함에 둡니다. 명령줄의 `-l`이 이 값보다 우선합니다.
- 입력을 묻는 일이 없도록, 모든 머신은 펌웨어(`iphone-version`, `iphone-build`, 또는 `iphone-source`와 `cloudos-source`)나 `template`을 지정해야 합니다.

## 실행 방식

첫 머신을 만들기 전에 모든 머신을 `vm create`와 같은 방식으로 검사합니다. 머신은 순서대로 만들어지므로, 템플릿 키가 같은 머신들은 첫 번째 머신이 만든 템플릿에서 복제됩니다. 처음 실패하는 지점에서 실행이 중단됩니다.

이미 있는 이름은 오류입니다. 두 플래그로 이를 바꿀 수 있으며, 함께 사용할 수는 없습니다.

| 플래그 | 효과 |
| --- | --- |
| `--skip-existing` | 이름이 이미 있는 머신을 건너뛰므로, 중단된 실행을 다시 실행해 나머지를 만들 수 있습니다. 실패한 머신은 멈춘 상태 그대로 남으므로, 먼저 삭제하지 않으면 그 머신도 건너뜁니다. |
| `--force-override` | 해당 머신을 만들기 직전에 기존 가상 머신을 삭제합니다. 실행 중인 가상 머신이나 가상 머신이 아닌 폴더는 거부합니다. |

## 함께 보기

- [템플릿](templates.md)
- [템플릿 만들기와 찾기](template-building.md)
- [머신 생성 및 실행](../machines/create-and-run.md)
