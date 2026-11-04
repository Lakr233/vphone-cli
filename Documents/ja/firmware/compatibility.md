# ファームウェアの互換性

どのゲストファームウェアと cloudOS の組み合わせが、どのホストで起動することが確認されているかをまとめています。新しいマシンのリリースを選ぶ前や、作成に失敗してその組み合わせがテストされたことがあるかを知りたい場合にご覧ください。

現在のカタログでこの Mac に提供されるものを確認するには、次を実行します。

```sh
vphone-cli fw catalog
```

> [!NOTE]
> v2.0.0 以降、vphone は `config.plist` が `schemaVersion=2` のマシンだけを起動します。以前のリリースで作成したマシンは `vm create` で作り直してください。その場でのアップグレードはありません。以下の結果はテスト済みの組み合わせを示すもので、古いマシンバンドルとの互換性を示すものではありません。

## テスト済みの環境

ネイティブの JB パイプラインで最初から最後まで実行した iPhone17,3 の組み合わせです。PR #486 の 2 行（[PR #486](https://github.com/Lakr233/vphone-cli/pull/486)）はロック画面に到達し、vphoned の ping に応答しました。新規に実行した 26.6.2 の `vm create` もすべての段階を完了し、初回起動の ping の後に正常終了しました。

| 検証 | iPhone 復元用 IPSW | PCC/cloudOS IPSW | 確認された結果 |
| --- | --- | --- | --- |
| PR #486 | `17,3_26.6.2_23G90` | `26.4-23E5207q` | JB パッチ、復元、CFW、起動、vphoned の ping |
| PR #486 | `17,3_27.0_24A435` | `26.4-23E5207q` | JB パッチ、復元、CFW、起動、vphoned の ping |
| 研究用ボード | `17,3_26.6_23G71` | `26.6-23G71` | CLI から standard と Minimal プリセット、Launchpad から standard（2026-10-20）：デバイスツリーと SEP の変換、kernelcache ミックス、復元、CFW、起動、vphoned の ping |
| 研究用ボード | `17,3_26.5_23F77` | `26.5-23F75` | CLI から standard プリセット（2026-10-20）：一時的な cloudOS の復元から GPU ドライバ、kernelcache ミックス、復元、CFW、起動、vphoned の ping |
| 研究用ボード | `17,3_26.4_23E246` | `26.4-23E244` | CLI から standard プリセット（2026-10-20）：一時的な cloudOS の復元から GPU ドライバ、kernelcache ミックス、復元、CFW、起動、vphoned の ping |
| 研究用ボード | `Watch7,18_26.4_23T240` | `26.4-23E244` | CLI と Launchpad から `watchos` プリセット（2026-10-20）：Watch の kernelcache ミックス、復元、起動、vphoned の ping |
| 研究用ボード | `11,6_18.7.2_22H124` | `18.7.2-22H43` | CLI から Minimal プリセット（2026-10-21）：一時的な cloudOS の復元から GPU ドライバ、macOS 15.6.1 の kmutil で ssh 経由でリンクした iOS 18 の kernelcache ミックス、復元、起動、vphoned の ping。画面、ロック画面、ロック解除、ホームへのスワイプを確認 |
| 研究用ボード | `11,6_18.1_22B83` | `18.1-22B83` | CLI から Minimal プリセット（2026-10-21）：一時的な cloudOS の復元から GPU ドライバ、macOS 15.6.1 の kmutil で ssh 経由でリンクした kernelcache ミックス、復元、起動、vphoned。「こんにちは」画面、ロック画面、ロック解除、ホームへのスワイプを確認 |
| 研究用ボード | `11,6_18.5_22F76` | `18.5-22F76` | CLI から Minimal プリセット（2026-10-21）：一時的な cloudOS の復元から GPU ドライバ、macOS 15.6.1 の kmutil で ssh 経由でリンクした kernelcache ミックス、復元、起動、vphoned。ロック画面、ロック解除、ホームへのスワイプを確認 |
| 研究用ボード | `11,6_18.6_22G86` | `18.6-22G86` | Launchpad の CLI から standard プリセット（2026-10-24）：kernelcache ミックス（キャッシュ済み）、復元、CFW、起動、vphoned、「こんにちは」画面。2 つの Frida パッチを許可した状態で Frida 17.24.3 の attach、spawn、Interceptor、Stalker |

### どの cloudOS を使うか

特に理由がなければ、cloudOS 26.4 ベータ（`26.4-23E5207q`）を使ってください。これは `vphone600ap` を含む最新の cloudOS です。`vphone600ap` は、ゲストのカーネル、SEP、デバイスツリーの元になるアイデンティティです。また、`vphone-cli` 以外に何も必要としません。

それ以降の cloudOS（2026-10-03 に確認）には PCC のボードと `vresearch101ap` しかありません。`SupportedProductTypes` から `iPhone99,11` がなくなり、`kernelcache.*.vphone600`、`sep-firmware.vphone600`、`DeviceTree.vphone600ap` もありません。このような cloudOS では、研究用ボード（Research Board パッチセット）が代わりを務めます。

- `fw patch` は、研究用ボードのデバイスツリーと SEP を vphone600 のものに変換し、その kernelcache 用のレシピに従って、vphone600 の仮想化 kext を加えて kernelcache を作り直します。
- KDK の展開はネイティブで行われ、root が必要なのはリンクだけです（`vphone-cli fw kernelcache`）。[kernelcache のレシピ](../../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md)と[ファームウェアの準備](firmware-preparation.md)をご覧ください。
- `fw prepare` は、どのレシピにも該当しない cloudOS を拒否します。
- `fw catalog` は各 iOS リリースに対応する cloudOS を推奨の cloudOS と並べて表示し、Launchpad では **Firmware** でそれを選べます。

| cloudOS | `vresearch101ap` | `vphone600ap` | kernelcache のレシピ |
| --- | --- | --- | --- |
| `26.4-23E5207q`（ベータ） | あり | あり | 不要 |
| `26.4-23E244` | あり | なし | あり |
| `26.4.1-23E254` | あり | なし | なし |
| `26.5-23F75` | あり | なし | あり |
| `26.5.2-23F83` | あり | なし | なし |
| `26.6-23G71` | あり | なし | あり |
| `26.6.1-23G82` | あり | なし | なし |
| `26.7-23H20` | あり | なし | あり |

ほかのバージョンの iPhone と iPad も `26.4-23E5207q` で動作する可能性がありますが、同じエンドツーエンドのチェックは通過していません。

### iOS 18 ゲスト

iOS 18.1〜18.7.2 は、それぞれのリリースに対応する cloudOS 上で、iPhone XS ファミリーの IPSW のユーザランドを使って動作します。

- `vm create --device iPhone11,6` で作成します。既定のプリセットは Minimal です。`--preset standard` は 18.6 で確認済みです。
- `fw catalog --device iPhone11,6` でリリースの一覧を表示できます。
- これらのカーネルは kernel-first です。macOS 26.4 以降では、macOS 15 または 26.0〜26.3 を実行している別の Mac または macOS 仮想マシンが ssh 経由でミックスをリンクします（`VPHONE_KMUTIL_SSH`。[ファームウェアの準備](firmware-preparation.md)をご覧ください）。
- Launchpad では iPhone XS Max として表示され、その Mac を macOS ビルダーとして使います。

18.1、18.5、18.7.2 は仮想マシンで確認済みです。残りの 4 つのレシピはまだ起動していません。

### iOS 27.0.1 の iPhone17,3

iOS 27.0.1（24A446）は、バンドル 2.5.0 以前では初回起動に失敗します（2026-10-04 に再現、Apple の未変更の launchd でも同様）。TXM の selector-24 の事前チェックが init の時点ですべてのバイナリを拒否し、`unexpected SIGKILL of init` でパニックします。`txm-boot-precheck_admission` パッチでこれが修正されます（[研究記録](../../../Research/Firmware/txm_selector24_cms_gate.md)をご覧ください）。このパッチを使うと、`26.4-23E5207q` 上の iPhone17,3 27.0.1 はゲストまで起動し、vphoned の `device.info` に応答します（同日に検証）。このパッチを含む最初のリリースはバンドル 2.6.0 です。

## macOS 26.6.2 のホスト

2026-10-23 に Core Bundle 2.12.1 で、2026-10-24 に Core Bundle 2.12.2 で、Mac mini M4 のホスト（Mac16,10、16 GB、macOS 26.6.2 25G83）で確認しました。すべてのマシンを CLI から新規に作成しました。研究用ボードの組み合わせでは、kernelcache ミックスをユーザとして準備して sudo でリンクし、その後 `sudo vphone-cli vm create` を実行しました。「標準」は、この Mac で `fw catalog` がそのデバイスに示す最新の組み合わせで、Launchpad の New Machine が選ぶものです。その後、各マシンをヘッドレスで 2 回起動し、vphoned が応答すること、`device.info` がリリースを報告すること、ゲストのシリアルログにパニックがないことを確認しました。

| ゲスト | ファームウェア | cloudOS | 結果 |
| --- | --- | --- | --- |
| iPhone17,3 | iOS 27.0.1（標準） | `26.4-23E5207q` | テンプレートの作成、複製、2 回の起動 |
| iPhone18,2 | iOS 27.0.1（標準） | `26.4-23E5207q` | テンプレートの作成、複製、2 回の起動 |
| iPad16,1 | iPadOS 27.0.1（標準） | `26.4-23E5207q` | テンプレートの作成、複製、2 回の起動 |
| iPhone17,3 | iOS 26.6.2 | `26.4-23E5207q` | テンプレートの作成、複製、2 回の起動 |
| iPhone17,3 | iOS 26.6.2 | `26.6-23G71` | 研究用ボード：ネイティブの KDK 展開、auth スタブの残らない macOS 26 でのリンク、28 個の kernelcache パッチ、2 回の起動 |
| iPhone17,3 | iOS 26.5 | `26.5-23F75` | 研究用ボード、上と同じ |
| iPhone17,3 | iOS 26.4 | `26.4-23E244` | 研究用ボード、上と同じ |
| iPhone17,3 | iOS 18.6.2 | `26.1-23B85` | テンプレートの作成、複製、2 回の起動 |
| iPhone11,6 | iOS 18.7.2（標準） | `18.7.2-22H43` | Minimal、macOS 15.7.7 仮想マシンの kmutil で ssh 経由でリンクしたミックス、2 回の起動 |
| iPhone11,6 | iOS 18.6 | `18.6-22G86` | 上と同じ：このレシピの初めての起動 |
| iPhone11,6 | iOS 18.7 | `18.7-22H20` | 上と同じ：このレシピの初めての起動 |
| Watch7,18 | watchOS 26.4（標準） | `26.4-23E244` | `watchos` プリセット、Watch の kernelcache ミックス、2 回の起動 |
| AppleTV5,3 | tvOS 26.6（標準） | `26.4-23E5207q` | `tvos` プリセット、2 回の起動 |
| AppleTV14,1 | tvOS 26.6（macOS 26 での標準） | `26.4-23E5207q` | `tvos-4k` プリセット、26.6 の OTA のユーザランド、2 回の起動 |
| AudioAccessory5,1 | HomePod ソフトウェア 27.0（macOS 26 での標準） | `26.4-23E5207q` | `homepod-mini` プリセット、2 回の起動 |
| AppleTV14,1 | tvOS 27.0 | — | ダウンロード前に拒否：macOS 27 が必要 |
| AudioAccessory5,1 | HomePod ソフトウェア 27.2 | — | ダウンロード前に拒否：macOS 27 が必要 |

tvOS 27.0（24J361）と HomePod ソフトウェア 27.2（24K120）の OTA はペイロードを LZRAVEN で圧縮しており、これを展開できるのは macOS 27 だけです。古い Mac では `fw catalog` がこれらを除外するため、それらのデバイスでの Launchpad の標準は tvOS 26.6 と HomePod ソフトウェア 27.0 になり、これらのバージョンを指定すると何もダウンロードされないうちに拒否されます。

Apple TV 4K（第 4 世代）、`AppleTV18,1` / `J265AP` は、立ち上げ作業用としてのみ、tvOS 27.2 ベータ（`24K120`）で利用できます。Apple TV HD 26.6 の復元ベースと cloudOS 26.4 ベータ（`23E5207q`）の上に、そのフル OTA を重ねて使います。macOS 27 と `tvos-4k` プリセットが必要です。2026-10-24 に 1 台のマシンを復元してカスタムファームウェアをインストールし、2 回コールドブートして、vphoned と旧 TVSetup の 4K 言語選択画面まで到達しました。セットアップ自体は完了していません。上のテスト済みの表には含まれていません。[立ち上げの記録](../../../Research/Firmware/tvos_support.md#apple-tv-4k-4th-generation)をご覧ください。

cloudOS 26.7（23H20）には組み合わせられる iPhone のリリースがありません。iOS 26.6.2 のユーザランドで準備すると、ミックスはリンクでき 28 個の kernelcache パッチも適用されますが、CFW パッチ `_vm_fault_enter_prepare` がそのカーネルで適用箇所を見つけられません。起動はしていません。

> [!TIP]
> `vphone-escalator` は許可リストを amfid のメモリに保持するため、amfid が再起動すると許可リストは失われます。これらのホストでも、実行中に一度そうなりました。Launchpad は、AMFI がバンドルを拒否すると再び許可します。CLI からの場合は、`host preflight` が表示する `vphone-escalator allow` コマンドをもう一度実行してください。

## その他の iPhone モデル

iPhone17,3 以外のモデルについては[その他の iPhone モデル](iphone-models.md)をご覧ください。

| ホスト | iPhone 復元用 IPSW | PCC/cloudOS IPSW | 確認された結果 |
| --- | --- | --- | --- |
| Mac17,9 (M5 Pro) 27.0.1 | `18,1_26.6.2_23G90` (iPhone 17 Pro) | `26.4-23E5207q` | Launchpad の `vm create`（2.5.1 のローカルバンドル）：準備、パッチ、復元、CFW、402x874 pt @3x のホーム画面まで起動、`model` iPhone18,1、vphoned の ping |
| Mac17,9 (M5 Pro) 27.0.1 | `18,2_27.0.1_24A446` (iPhone 17 Pro Max) | `26.4-23E5207q` | `kernel-boot-shared_region_size` パッチで**起動**（2026-10-06、バンドル 2.6.0-local.0d5e6f90）：`dyld cache mapped system-wide`、パニック 0 回、vphoned が 27.0.1 として応答、440x956 pt @3x のホーム画面 |
| Mac17,7 (M5 Max) 26.4 | `19,2_27.0.1_24A446` (iPhone 18 Pro) | `26.4-23E5207q` | ARM64E_X1 互換機能を統合して**起動**（2026-10-17）：オフラインでの問題のない復元、ルートシールの検証、vphoned の ping、設定、Safari、計算機の起動 |

### iOS 27 の iPhone18,1 と iPhone18,2

これらには `kernel-boot-shared_region_size` パッチが必要です（[issue #596](https://github.com/Lakr233/vphone-cli/issues/596)、27.0 と 27.0.1）。2026-10-06 以降、iOS 27 ベースでは `standard` プリセットでオンになっています。

27.0.1 のこれらの dyld 共有キャッシュは `sharedRegionSize` が `0x185804000` で、cloudOS 26.4 のゲストカーネルの共有領域 `0x180000000` より大きいため、`dyld-boot-maxslide` でスライドをなくしてもキャッシュをマップできません。パッチがないと、launchd が初回起動時に `Library not loaded: /usr/lib/libSystem.B.dylib` でパニックします。iPhone17,3 の 27.0.1 のキャッシュ（`0x17D508000`）はまだ収まります。

このパッチは arm64 の領域を `0x1C0000000` に広げます。これは 26.4 カーネル自身のタスクマップの上限を超えない最大のサイズです。マシンのカーネルにこのパッチが含まれている場合（`PatchReceipt.plist` に記録されています）、`cfw install` は広げた領域を基準にキャッシュを測るため、これらのデバイスはインストールして起動できます。これは上のとおり iPhone18,2 27.0.1 で検証済みです。

パッチがない場合（古いバンドル、またはパッチのチェックを外した場合）、`cfw install` はパニックするゲストを残す代わりに、この説明を付けてそのようなキャッシュを拒否します。iOS 27 には iPhone17,3 を使うか、これらのデバイスでは iOS 26 を使ってください。

## iPadOS

iPad ゲストについては [iPadOS ゲスト](ipados.md)をご覧ください。

| ホスト | iPad 復元用 IPSW | PCC/cloudOS IPSW | 確認された結果 |
| --- | --- | --- | --- |
| Mac17,9 (M5 Pro) 27.0.1 | `iPad16,1,iPad16,2_26.6.2_23G90` | `26.4-23E5207q` | 準備、パッチ、復元、CFW（2.2.5 のヘルパー）、744x1133 pt @2x の iPadOS ホーム画面まで起動、`model` iPad16,1、vphoned の ping |
| Mac17,9 (M5 Pro) 27.0.1 | `iPad16,1,iPad16,2_27.0.1_24A446` | `26.4-23E5207q` | カタログからの Launchpad の `vm create --device iPad16,1`（2.4.0 のバンドル）：準備、パッチ、復元、CFW、744x1133 pt @2x の iPadOS ホーム画面まで起動、`model` iPad16,1、`ios_version` 27.0.1、vphoned の ping |

## 以前に報告された組み合わせ

以前の README には、次のホストとファームウェアの組み合わせが記録されていました。これらは現在の単一モードの手順より前のものか、同等の vphoned による受け入れの証拠がないため、現在のサポート表ではなく研究の経緯として扱ってください。

| ホスト            | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_26.6.2_23G90`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A435`    | `26.4-23E5207q` |

すべてのパッチとその適用先の一覧は、[パッチ一覧](../../../Research/0_binary_patch_comparison.md)をご覧ください。

## 関連項目

- [ファームウェアの準備](firmware-preparation.md)
- [その他の iPhone モデル](iphone-models.md)
- [iPadOS ゲスト](ipados.md)
- [マシンの作成と実行](../machines/create-and-run.md)
