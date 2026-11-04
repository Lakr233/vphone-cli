# iPadOS ゲスト

vphone のマシンで iOS の代わりに iPadOS を実行する方法です。iPad のユーザランド、画面サイズ、マルチタスク機能が必要な場合に使います。

仮想ハードウェアは変わりません。ブートチェーン、カーネル、SEP、デバイスツリーは引き続き PCC の cloudOS IPSW（`vresearch101ap` / `vphone600ap`）から取得します。ユーザランドだけが iPhone17,3 ではなく iPad の復元用 IPSW から取得され、ユーザランドから iPad に見えるようにデバイスツリーが書き換えられます。

![vphone の仮想マシンで表示した iPadOS のホーム画面](../../ipados-demo.jpeg)

## 作成する

### Launchpad で

1. **New Machine** を選びます。
2. **Device** で iPad を、**iPadOS** でリリースを選びます。推奨される cloudOS も一緒に選ばれます。
3. カタログにない IPSW を使う場合は、**Source** を **Custom IPSWs** にし、**iPhone IPSW** 欄に iPad の IPSW を、もう一方の欄に cloudOS の IPSW を入力します。

**Device** メニューは、カタログに iPad が含まれる Core Bundle の場合にだけ表示されます。ターミナルからは、`vphone-launchpad-cli vm create <name> --device iPad16,1` で同じことができます。

### vphone-cli で

iPhone の IPSW を渡す場所に、iPad の復元用 IPSW を渡します。cloudOS は、同じリリースの iPhone ゲストが使うものと同じです。

```sh
vphone-cli vm create ipad-mini \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/cf7db64d-5866-4bf2-bfff-50a32f58bec3/iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'

# The 13-inch iPad Pro (M5), from the IPSW that also carries the 11-inch
vphone-cli vm create ipad-pro-13 --device iPad17,3 \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/<…>/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'
```

リリースを探すには：

| コマンド | 表示されるもの |
| --- | --- |
| `vphone-cli fw catalog` | サポートされるすべての iPad の iPadOS リリースと、それぞれの cloudOS |
| `vphone-cli fw catalog --device iPad16,1` | 1 台の iPad のリリース |
| `vphone-cli fw prepare --device iPad16,1 --list` | その iPad でダウンロードできる IPSW |
| `vphone-cli fw prepare --device iPad16,1 --iphone-version 26.6.2` | 1 つの IPSW を特定 |

`--device` を指定してソースを指定しない場合、`vm create` はその iPad のリリースを選択肢として表示します。

### 共有 IPSW でモデルを選ぶ

ほとんどの iPad の IPSW は複数のモデルに対応しています。iPad Air と iPad Pro の IPSW には両方のサイズが含まれます。`--device` を指定しないと、`fw prepare` は IPSW に最初に記載されたモデル（11 インチ）を選びます。13 インチにするには、`fw prepare` または `vm create` に `--device iPad17,3` を渡します。Launchpad の New Machine は **Device** で選んだモデルを渡します。**Custom IPSWs** の場合は最初のモデルを選びます。

<img src="../../ipados/ipad-pro-13-home.jpg" alt="vphone の仮想マシンで表示した 13 インチ iPad Pro のホーム画面" width="360" />

### 手動の段階

手動の段階は iPhone ゲストと同じです：`vm new`、`fw prepare`、`fw patch`、DFU と `restore`、`cfw install`、`vm launch`。iPad で動作が異なるのは `fw prepare` と `fw patch` だけで、DFU、`restore`、`cfw install` はそのまま実行されます。

## サポートされるデバイス

| 製品 | モデル | ボード | パネル | ポイント @2x |
| --- | --- | --- | --- | --- |
| `iPad16,1` | iPad mini（A17 Pro） | J410AP | 1488x2266 @ 326 ppi | 744x1133 |
| `iPad15,7` | iPad（A16） | J481AP | 1640x2360 @ 264 ppi | 820x1180 |
| `iPad15,3` | 11 インチ iPad Air（M3） | J607AP | 1640x2360 @ 264 ppi | 820x1180 |
| `iPad15,5` | 13 インチ iPad Air（M3） | J637AP | 2048x2732 @ 264 ppi | 1024x1366 |
| `iPad16,3` | 11 インチ iPad Pro（M4） | J717AP | 1668x2420 @ 264 ppi | 834x1210 |
| `iPad16,5` | 13 インチ iPad Pro（M4） | J720AP | 2064x2752 @ 264 ppi | 1032x1376 |
| `iPad17,1` | 11 インチ iPad Pro（M5） | J817AP | 1668x2420 @ 264 ppi | 834x1210 |
| `iPad17,3` | 13 インチ iPad Pro（M5） | J820AP | 2064x2752 @ 264 ppi | 1032x1376 |

セルラーモデル（`iPad16,2`、`iPad15,4`、`iPad15,6`、`iPad16,4`、`iPad16,6`、`iPad17,2`、`iPad17,4`）は、対応する Wi-Fi モデルと IPSW を共有し、そのモデルとして動作します。仮想マシンにはベースバンドがありません。`iPad15,8` は Wi-Fi モデルのボードを含まない独自の IPSW で配布されており、サポートされていません。

テスト済みの組み合わせは[互換性](compatibility.md)にあります。

## iPad で変わること

- **`fw prepare`** は `SupportedProductTypes` から IPSW を認識し、ゲストのボードに対応する消去用アイデンティティと `DeviceMap` のエントリを選び（iPad の IPSW は複数のボードに対応しています）、製品タイプと iPad のディスプレイをマシンの `config.plist`（`guestProductType`、`screenConfig`）に記録します。復元ツリーの名前は `iPhoneOS_iPad16,1_<version>_<build>_Restore` になります。`iPhone` という接頭辞は、復元ツリーを読み取るすべての処理が照合する命名規則であり、デバイスを表すものではありません。
- **2 つのデバイスツリー。** ハイブリッドなマニフェストでは、通常 `DeviceTree` と `RestoreDeviceTree` が同じ vphone600 のファイルを指します。iPad の場合、`DeviceTree` はコピーである `Firmware/all_flash/DeviceTree.vphone600ap.guest.im4p` を指します。復元時は、`restored_external` がマニフェストと照合する未変更のアイデンティティ（`iPhone99,11`）で起動し、ゲストはコピーで起動します。
- **`fw patch`** は、そのコピーに iPad のアイデンティティと表示を与えます（パッチセット `devicetree`、エントリ `devicetree-cfw-ipad_*`）。
  - ルートの `model`、`target-type`、`target-sub-type` をボードと同じ値にし（iPad mini の場合は `iPad16,1`、`J410`、`J410AP`）、`compatible` はボードを先頭にして `VPHONE600AP` を 2 番目に残します。
  - `/product`：ボードのアートワークのイディオム、サブタイプ、スケール、製品名、外観、カメラとボタンの配置、マルチタスク機能（`medusa-overlay-app-capability`、`ui-floating-live-app`、`ui-overlay-app`、`ui-pinned-app`、そしてステージマネージャのないボードでは `disable-chamois`）、製品タイプと固有のモデル。これらはすべて、復元ツリーに残っているボードの `DeviceTree.<board>.im4p` から読み取ります。
  - iPhone 専用の `syscfg` のプレースホルダ（Dynamic Island、簡易アクセス、着信/サイレントスイッチ、音量ボタンの配置、CarPlay、Apple Watch のペアリング）は削除されます。

  仮想ハードウェアは vphone600 の記述のままです：GPU の機能セット、フレームバッファ、メモリクラス、ブートフラグ。
- **LLB** には、iPad ゲストの場合にもう 1 つのパッチ `llb-cfw-display_scale` が適用されます。LLB は準仮想化ディスプレイのブートビデオのワードから `/chosen/display-scale` を設定しますが、この値は常に 3x を示します。MobileGestalt はこのプロパティを画面のスケールとして使うため、iPad では 496x755 ポイントのキャンバスになってしまいます。このパッチで、LLB が iPad 本来のスケール（iPad mini の場合は 2x、744x1133 ポイント）を書き込むようにします。
- **`cfw install`** は、インストールされたデバイスツリーに手を加えません。iPhone17,3 の復元後のアイデンティティ書き換え（`preboot-exp-devicetree_identity`）は、iPad ゲストでは省かれます。
- **マシンのウィンドウ**は `screenConfig` に従うため、iPad の縦横比で開きます。

<img src="../../ipados/display-scale-3x-before.jpg" alt="LLB パッチ適用前の、3x のディスプレイスケールで表示された iPad ゲスト" width="240" />

## iPad を追加する

iPad のモデルを追加するには、[`VPhoneGuestDevice`](../../../VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestDevice.swift) に製品タイプ、ボード、パネルの 1 行を加えるだけです。デバイスツリーに必要な情報は、すべて IPSW 内のボード自身の `DeviceTree.<board>.im4p` から読み取られます。

## 関連項目

- [その他の iPhone モデル](iphone-models.md)
- [ファームウェアの互換性](compatibility.md)
- [マシンの作成と実行](../machines/create-and-run.md)
