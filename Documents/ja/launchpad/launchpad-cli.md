# Launchpad コマンドライン

`vphone-launchpad-cli` は、実行中の Launchpad をターミナルやスクリプトから操作します。バンドルのインストール、マシンの作成、起動、停止、ゲストとのやり取りができます。ウィンドウをクリックして回らずに Launchpad の機能を使いたい場合に使います。

## 準備する

CLI は `vphone-launchpad.app/Contents/MacOS` に同梱されています。`PATH` にリンクを作成します。

```sh
ln -s /Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli /usr/local/bin/
vphone-launchpad-cli help
```

Launchpad が実行されていない場合は、CLI が Launchpad を起動します。CLI が起動した Launchpad は非表示で開き、前面のアプリからフォーカスを奪いません。ウィンドウを表示するには、Dock アイコンをクリックするか、メニューバーの Open Launchpad を選びます。代わりにウィンドウを前面にして起動するには、`--foreground` を指定します（コマンドの前、または `exec` 以外の任意のコマンドのオプションの中に置きます）。どちらも、すでに実行中の Launchpad には影響しません。

## 出力と終了ステータス

- 進行状況の行は、発生するたびに stderr に出力されます。
- 結果は 1 つの JSON ドキュメントとして stdout に出力されます。
- 終了ステータスは成功時に 0、失敗時に 1 で、理由は stderr に出力されます。
- CLI を中断すると、取り消せるコマンド（`exec`、待機、CFW のインストール）は取り消されます。バンドルのインストールとマシンの作成はウィンドウに属するため、実行が続きます。

すべてのコマンドは、Launchpad のウィンドウとコマンド履歴にも表示されます。

## コマンド

2 つのライブラリに同じ名前のマシンがある場合、マシンのコマンドには `--root <library>` を指定します。

### 状態とバンドル

| コマンド | 内容 |
| --- | --- |
| `status` | ホストのチェック、ヘルパー、標準のバンドル、マシンの数 |
| `bundle list` | インストール済みのバージョン、レシート、cdhash、チェック結果、紐付いたマシン |
| `bundle install-local <path> [--keep-default]` | ローカルの `VPhone.bundle` フォルダまたは `.zip` をインストールします |
| `bundle install-release <version\|latest> [--keep-default]` | GitHub のリリースをダウンロードしてインストールします |
| `bundle set-default <version>` | バージョンを標準にします。`bundle use` は以前の名前です |
| `bundle verify <version>` | バージョンを再チェックします |
| `bundle accept <version> [--off]` | 失敗したチェックを無視します。`--off` で無視をやめます |
| `bundle remove <version>` | どのマシンも紐付いていないバージョンを削除します |

ローカルビルドのインストール、マシンのローカルビルドへの移行、2 つのビルドの比較については、[Core Bundle とローカルビルド](core-bundles.md)をご覧ください。

### マシン

| コマンド | 内容 |
| --- | --- |
| `vm list` | すべてのライブラリのマシンと、その実行状態、Core Bundle、ログのパス |
| `vm start <name> [--headless] [--wait]` | マシンのバンドルで起動します。`--wait` で vphoned を待ちます |
| `vm stop <name>` | ゲストにシステム終了を求め（vphoned の `system.shutdown`）、最大 30 秒待ちます。ゲストに求められない場合や停止しない場合は、仮想マシンを終了します |
| `vm wait <name>` | vphoned を待ちます |
| `vm log <name> [--lines <n>] [--kind create\|dfu\|patch]` | コンソールログを読み取ります |
| `vm create <name> [options]` | New Machine の処理です。下記の「マシンを作成する」をご覧ください |
| `vm set-bundle <name> <version> [--update-environment]` | マシンを別のインストール済みバージョンに紐付けます |
| `vm leases [--release]` | 共有 NAT ネットワーク上の DHCP リースと、それぞれを所有するマシン。`--release` は、どのライブラリのどのマシンも使っていないリースをヘルパーを通じて解放します（[MAC アドレスと IP アドレス](../networking/addresses.md)の「古い MAC が保持しているアドレス」をご覧ください） |

注意：

- `vm list` でマシンが `running` になるのは、ディスクを保持しているのが仮想マシンのプロセス（`vphone-vm`、または Virtualization の仮想マシンサービス）の場合だけです。ディスクを開いているほかのプロセス（`tail`、Spotlight、バックアップツール）は `diskOpenIn` に表示され（例：`12925 tail`）、マシンは `stopped` のままです。
- `vm start` は、`vphone-cli vm launch` と同じく、ディスクを開いているだけのプロセスがあっても拒否されません。そのプロセスの名前を示すメモが表示されます。
- `vm start --wait` と `vm wait` は `--timeout` も受け付けます。
- `vm set-bundle --update-environment` は、そのバージョンのゲスト環境も配置し直すため、マシンを停止しておく必要があります。ほかのプロセスがディスクを開いている場合は、紐付けを変更する前に、そのプロセスの名前を示して拒否されます。更新自体が失敗した場合、マシンは新しいバージョンに紐付いたままで、`vm list` には古い `guestEnvironmentBundle` が表示されたままになります。`cfw update-environment` を実行して完了させてください。

### CFW

これらは停止中のマシンに対し、マシン自身のバンドルを使って Launchpad のヘルパーを通じて実行されます。ほかのプロセスがディスクを開いている場合は、そのプロセスの名前（`12925 tail`）を示してそれぞれ拒否されます。

| コマンド | 内容 |
| --- | --- |
| `cfw install <name>` | CFW をインストールします。該当する場合、ヘルパーは一時的な作業ファイルを仮想マシンのライブラリの外部ボリュームに置きます |
| `cfw update-environment <name>` | バンドルのゲストリソース（vphoned、フック用の dylib）を配置し直します。ほかには何も変わりません |
| `cfw update-kernel <name>` | マシンの現在のパッチの選択で kernelcache にパッチを適用し直し、データを保持したまま Preboot の kernelcache と入れ替えます。インストール済みの仮想マシンでデータを保持したままカーネルパッチを変更する方法です。復元ツリーは必要ありません |

### ゲスト

`guest` コマンドと `--wait` は、マシンの `vphone.sock` を通じて動作します。このソケットはすべての起動で提供されます。2.0.9 までのバンドルでは、ウィンドウ付きで起動したマシンでのみ提供されます。

| コマンド | 内容 |
| --- | --- |
| `guest send <name> <json>` | `vphone.sock` への生のリクエストを 1 つ送ります（tap、swipe、key、screenshot） |
| `guest rpc <name> <method> [params]` | 任意の vphoned メソッドを呼び出します。[`Research/vphoned_http_api.md`](../../../Research/vphoned_http_api.md) をご覧ください。vphoned が拒否した場合、stderr の最後の行がそのエラーオブジェクトの JSON（`code`、`message`、`results`、`reason` …）になります |
| `guest push <name> <local> <guest-path> [--mode <octal>]` | Mac のファイルをゲストにコピーします。vphoned を通じてストリーミングするため、サイズは `guest rpc` の 1 MiB の JSON 行に制限されません。バイナリや IPA に使います。ゲストのパスが `/` で終わる場合はファイル名がそのまま使われます。モードの標準は Mac のファイルのアクセス権です |
| `guest pull <name> <guest-path> <local>` | ゲストのファイルを Mac にストリーミングでコピーします。`local` にはフォルダも指定できます。ファイルが `local` を置き換えるのは、コピーが完了してからです |
| `guest unlock <name> [--passcode <code>] [--timeout <seconds>]` | ゲストがどの状態でも、画面をオンにしてロックを解除します（vphoned の `screen.unlock`）。`--passcode` は、ゲストにパスコードが設定されている場合にのみ必要です |

### vphone-cli を実行する

| コマンド | 内容 |
| --- | --- |
| `exec [--bundle <version>] <vphone-cli arguments>` | 標準のバンドル、または指定したバージョンの `vphone-cli` を実行し、その出力をストリーミングします。`--bundle` は最初に置く必要があります |

## マシンを作成する

`vm create` は、`--bundle <version>` または標準のバンドルに紐付けて New Machine の処理を実行します。マシンはテンプレートから複製され、テンプレートがない場合は先に作成されます（2.9）。`--no-template` を指定すると単独で復元されます。

```sh
vphone-launchpad-cli vm create rt-e --block system-debugserver-cfw-install
```

| オプション | 内容 |
| --- | --- |
| `--bundle <version>` | 標準のバンドルの代わりに、このインストール済みバージョンにマシンを紐付けます |
| `--device <product-type>` | 別のデバイスを作成します。下記の「その他のデバイス」をご覧ください |
| `--preset <preset>` | プリセットの名前、またはプリセットの plist のパス（2.14）。マシンはそのコピーを保持します |
| `--block <patch>`、`--allow <patch>` | プリセットのパッチを 1 つオフまたはオンにします。繰り返し指定できます。下記の「パッチの上書き設定」をご覧ください |
| `--no-template` | テンプレートを複製せず、マシンを単独で復元します。軽量化のスイッチのうち `--slim` だけが使えます。`on`（標準）ではマシン自身が初回セットアップ起動を行い、設定アシスタントを省略します。`off` では設定アシスタントから始まります |
| `--slim on\|off`、`--trim …`、`--keep-languages …`、`--service-profile …`、`--remove-apps …`、`--keep-apps …` | `vphone-cli vm create` の軽量化のスイッチ。New Machine と同じく、Apple アカウントは trimmed のサービスプロファイルに従います |
| `--accounts-off` | 受け付けますが、何も変わりません |
| `--ipsw <path>` | 省略可能。2.12.0 のバンドルにだけ渡され、New Machine の ipsw 欄と同じく、kernelcache ミックスの準備に使われます。2.12.1 のバンドルはネイティブで展開します |
| `--kmutil-ssh <user@host>` | New Machine の macOS ビルダー欄と同じく、iOS 18 ゲスト（`--device iPhone11,6`）の kernel-first のミックスを ssh 経由でリンクする Mac。そこでの ssh と sudo のパスワードは、引数ではなく、クライアントの `VPHONE_KMUTIL_SSH_PASSWORD` から取得します |
| `--from <step>` | 作成開始時のオプションで、ある手順（`findTemplate` … `firstBoot`）からやり直します |

パーサは `--iphone-source`、`--cloudos-source`、`--cpu`、`--memory`、`--disk-size`、`--network`、`--keep-artifacts`、`--no-wait` も受け付けます。`vphone-launchpad-cli help` をご覧ください。

結果には、テンプレート、この作成処理がそのテンプレートを作ったかどうか、使用したパッチが表示されます。

### その他のデバイス

| `--device` | ゲスト | 備考 |
| --- | --- | --- |
| iPad の製品タイプ | iPadOS | [iPadOS ゲスト](../firmware/ipados.md)をご覧ください |
| `AppleTV5,3` | Apple TV HD | 常に軽量化なしで単独で復元されます。`--preset` で別のプリセットを指定しない限り、`tvos` プリセットを使います |
| `AppleTV14,1` | Apple TV 4K（第 3 世代） | 同様で、`tvos-4k` プリセットを使い、ユーザランドはカタログの OTA から取得します |
| `AppleTV18,1` | Apple TV 4K（第 4 世代） | Launchpad と Core Bundle 2.13 が必要です。`tvos-4k` を選び、軽量化なしで単独で復元し、Apple TV HD のベースに重ねたフル OTA から tvOS 27.2 ベータ（`24K120`）を取得します。作成には macOS 27 が必要です。実際の起動はまだ確認されていません。[立ち上げの記録](../../../Research/Firmware/tvos_support.md#apple-tv-4k-4th-generation)をご覧ください |

さらに 2 つの場合では、ヘルパーを通じて root として手順が実行されます。

- `--preset minimal`（Minimal：未変更のブートチェーン、カーネル、TXM を使い、復元前にシステムをカスタマイズします）も軽量化なしで単独で復元され、その `fw patch` はヘルパーを通じて root として実行されます。Userspace debugging のボックス（`vphone-cli fw patches` の Features にある `userspace-debugging`）は、そこに記載された各パッチに対する `--allow` です。Trusted darwinOS environment のボックス（`trusted-darwinos`、つまり `--allow filesystem-exp-trusted_darwinos`）は、iPhone または iPad を trusted darwinOS として復元し、cloudOS の cryptexctl を追加します。これにより、ゲストの実行中に cryptex をインストールできます（VM ウインドウの Apps › Install Cryptex…。[Cryptex](../machines/cryptexes.md) を参照）。ボックスの説明に、その影響が記載されています。ゲストでは Restricted Execution Mode が強制され、リサーチボードのゲスト（cloudOS 26.5〜26.7）ではデベロッパモードをオンにできません。ボックスの変更は、復元をやり直したときにのみ反映されます。
- cloudOS に vphone600 のコンポーネントがないマシン（そのリリース自身の cloudOS、Watch、iOS 18 ゲスト）では、kernelcache ミックスを `fw kernelcache` で準備し、ヘルパーが root としてリンクします。

### パッチの上書き設定

`--block <patch>` と `--allow <patch>` には、`vphone-cli fw patches` が表示する識別子を、パッチごとに 1 回ずつ指定します。

```sh
vphone-launchpad-cli exec fw patches --preset <preset>
```

Launchpad は作成処理のバンドルからそのカタログを読み込み、どのパッチセットにも宣言されていない識別子や、ブロックと許可の両方に指定された識別子を拒否し、`fw set-patches` と同じく、プリセットと異なるものだけを保持します。その後、New Machine と同じ方法でそれらを分けます。

- **ブートチェーンのパッチ**（AVPBooter、iBSS、iBEC、LLB、TXM、kernelcache、DeviceTree …）はテンプレートのキーに含まれます。Find Template はそれを適用して作られたテンプレートを探し、テンプレートの作成処理は `fw patch` の前に `fw set-patches` でそれを記録します。
- **ゲストパッチ**はテンプレートに含まれません。複製は `fw set-patches` でそれを記録し、Apply Guest Patches の手順で、初回起動の前にヘルパーを通じて `cfw update-environment` で書き込みます。そのため、ゲストの上書き設定だけであれば、通常のテンプレートが再利用されます。

結果の `patches` オブジェクトには、プリセット、`blocked` と `allowed` の上書き設定、複製に適用された `guest` の上書き設定が含まれます。`--no-template` の場合、すべての上書き設定はマシン自身の復元に反映されます。`--from` は `--block` と `--allow` を拒否します。やり直す場合は、作成処理のパッチがそのまま使われます。

## 結果に含まれるバンドルのフィールド

| コマンド | フィールド | 意味 |
| --- | --- | --- |
| `status` | `defaultBundle` | 標準のバージョン。古いスクリプトのために、`activeBundle` にも同じ値が入ります |
| `bundle list` | `default` | このバージョンが標準であること。古いスクリプトのために、`active` にも同じ値が入ります |
| `bundle list` | `machines` | このバージョンに紐付いたマシンの名前 |
| `vm list` | `bundle` | マシンのホストプログラムが使うバージョン |
| `vm list` | `guestEnvironmentBundle` | 最後にゲスト環境をインストールしたバージョン。不明な間は `null` |
| `vm list` | `bootChainBundle` | ブートチェーンを作ったバージョン。Launchpad が記録するようになる前に作成されたマシンでは `null` |
| `vm create`、`cfw …`、`exec` | `bundle` | コマンドが使ったバージョン |

`guestEnvironmentBundle` が `bundle` と異なる場合、ホストとゲストは別のビルドのものです。`cfw update-environment` でゲストを合わせられます。

## タッチ座標とディスプレイの形状

`guest send` のタッチ座標は、`t:screenshot` が返す**直立したスクリーンショット全体**を基準にします。90 度回転すると、幅と高さが入れ替わります。ホストは、GUI でもヘッドレスでも、その座標を固定パネルの HID 座標に変換します。スワイプは、開始時に取得した形状を使い続けます。スクリーンショットの間に形状が変わった場合は、入力座標があいまいな画像の代わりにエラーが返されます。

回転時の座標のずれを診断するには、形状を読み取ります。

```sh
vphone-launchpad-cli guest send <name> '{"t":"display.geometry"}'
```

ホストで設定されたピクセル寸法と取得したピクセル寸法に加え、表示中のディスプレイビューの境界、回転、アスペクト比を保った描画領域、ポインタとタッチの経路が返されます。入力やディスプレイの状態は何も変わりません。`capture_pixels` はホストの生のフレームで、`screenshot_pixels` と `input_orientation` は入力座標を表します。`device.screen`、`display.orientation`、ゲストが実際に受け取るイベントと比較してください。

## 接続の仕組み

CLI は、`~/Library/Application Support/vphone-launchpad/control.sock`（モード 0600、同じユーザにのみ提供）の Unix ソケットを通じて、実行中の Launchpad と通信します。CLI は権限も独自の状態も持ちません。バンドルは Launchpad のヘルパーを通じてインストールされ、各マシンは自身の Core Bundle の `vphone-cli` を通じて実行されます。ネットワークでリッスンするものは何もありません。別のマシンから使うには、ssh で接続してください。

## 関連項目

- [Core Bundle とローカルビルド](core-bundles.md)
- [バンドルの組み込み](bundle-integration.md)
- [作成と実行](../machines/create-and-run.md)
