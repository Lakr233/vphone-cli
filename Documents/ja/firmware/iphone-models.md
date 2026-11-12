# その他の iPhone モデル

iPhone17,3（iPhone 16）ではなく、別の iPhone の復元用 IPSW から取得した iOS でゲストを実行する方法です。特定のモデルのユーザランド、パネルサイズ、アイデンティティが必要な場合に使います。

[iPad ゲスト](ipados.md)と同じく、仮想ハードウェアは変わりません。ブートチェーン、カーネル、SEP、デバイスツリーは引き続き PCC の cloudOS IPSW（`vresearch101ap` / `vphone600ap`）から取得します。ユーザランドだけが選んだモデルの IPSW から取得され、ゲストが起動に使うデバイスツリーはそのモデルとして見えるように書き換えられます。

## 作成する

Launchpad では、**New Machine** を選び、**Device** でモデルを、**iOS** でリリースを選びます。

ターミナルから Launchpad を通じて作成する場合：

```sh
vphone-launchpad-cli vm create iphone17pro --device iPhone18,1
```

`vphone-cli` では、モデルの IPSW と cloudOS を渡します。

```sh
vphone-cli vm create iphone17pro \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/f768ecdf-e037-44e6-bfa6-949b6d127c4f/iPhone18,1_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'
```

iPhone の各モデルにはそれぞれ専用の IPSW があるため、ソースを明示する場合は `--device` は不要です。

リリースを探すには `fw catalog` を実行します。iPhone 13、16、17 の各モデルの 26.0〜27.0.1 のリリース（iPhone 17e は 26.3.1 から）と iPhone 18 Pro の 27.0.1 が、同じリリースの iPhone17,3 が使う cloudOS とともに表示されます。1 つのモデルのリリースを表示するには：

```sh
vphone-cli fw catalog --device iPhone18,1
```

## サポートされるデバイス

| 製品 | モデル | ボード | パネル | ポイント @3x |
| --- | --- | --- | --- | --- |
| `iPhone14,5` | iPhone 13 | D17AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone17,3` | iPhone 16 | D47AP | 1179x2556 @ 460 ppi | 393x852 |
| `iPhone17,4` | iPhone 16 Plus | D48AP | 1290x2796 @ 460 ppi | 430x932 |
| `iPhone17,1` | iPhone 16 Pro | D93AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone17,2` | iPhone 16 Pro Max | D94AP | 1320x2868 @ 460 ppi | 440x956 |
| `iPhone17,5` | iPhone 16e | V59AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone18,3` | iPhone 17 | V57AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone18,4` | iPhone Air | D23AP | 1260x2736 @ 460 ppi | 420x912 |
| `iPhone18,1` | iPhone 17 Pro | V53AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone18,2` | iPhone 17 Pro Max | V54AP | 1320x2868 @ 460 ppi | 440x956 |
| `iPhone18,5` | iPhone 17e | V159AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone19,2` | iPhone 18 Pro | V63AP | 1206x2622 @ 460 ppi | 402x874 |

iPhone17,3 を含むすべてのモデルが、パネルとアイデンティティを自身のデバイスツリーから取得します。新しく作成した iPhone17,3 マシンは iPhone 16 本来の 1179x2556 パネルを使います。以前の VPhone.bundle で作成したマシンは、構成に記録された 1290x2796 パネルのままです。

iPhone 17 Pro、17 Pro Max、18 Pro には起動検証の記録があります。[互換性](compatibility.md)の「その他の iPhone モデル」をご覧ください。iPhone 17 Pro と 17 Pro Max は iOS 27 でパッチが必要で、その内容も同じ箇所に記載されています。

> [!WARNING]
> iPhone19,2 は ARM64E_X1 を使います。X1 にネイティブ対応していないホストでは、standard プリセットがサポートされていない命令を置き換えるため、PC に結び付いたポインタ認証が弱まります。

## 別の iPhone で変わること

[iPadOS ゲスト](ipados.md)の「iPad で変わること」に記載された内容がすべて当てはまりますが、違いが 2 つあります。

- ボードの `/product` の値が同じ方法で vphone600 のプレースホルダを置き換えますが、iPhone のボードでは iPhone 固有のプロパティが残ります。Dynamic Island、簡易アクセス、OLED、音量ボタンの配置、CarPlay、Apple Watch のペアリングは、削除されずにボードから取得されます。パッチ ID は `devicetree-cfw-ipad_*` のままです。これらは iPhone で使われるようになる前に名付けられました。
- LLB にディスプレイスケールのパッチは適用されません。準仮想化ディスプレイのブートビデオのワードは 3x を示しており、これはもともと iPhone のスケールです。

## 関連項目

- [iPadOS ゲスト](ipados.md)
- [ファームウェアの互換性](compatibility.md)
- [マシンの作成と実行](../machines/create-and-run.md)
