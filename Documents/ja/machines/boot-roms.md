# ブート ROM

仮想マシンが起動に使うブート ROM と SEP ブート ROM を選びます。このページでは、仮想マシンが使っている ROM の確認方法と、オープンソースの ROM と Apple の ROM の切り替え方法を説明します。

## 確認と切り替え

```sh
vphone-cli vm info myphone                                    # shows rom and seprom
vphone-cli vm config myphone --rom openavb --seprom opensep   # open-source ROMs
vphone-cli vm config myphone --rom apple --seprom apple       # Apple's ROMs
```

切り替えは、どちらの方向でも復元なしで、仮想マシンの次回の起動から反映されます。

| オプション | 値 | ROM |
| --- | --- | --- |
| `--rom` | `openavb` | バンドルに含まれる OpenAVB |
| `--rom` | `apple` | Virtualization.framework の AVPBooter（マシン専用のパッチ済みコピーがある場合はそれ） |
| `--rom` | ファイルのパス | その他の任意のブート ROM |
| `--seprom` | `opensep` | バンドルに含まれる OpenSEP |
| `--seprom` | `apple` | Virtualization.framework の AVPSEPBooter |
| `--seprom` | ファイルのパス | その他の任意の SEP ブート ROM |

どちらのブート ROM も同じパッチ済みの LLB を読み込み、どちらの SEP ROM も復元時にインストールされた SEP ファームウェアを読み込みます。そのため、復元は必要ありません。

> [!NOTE]
> OpenAVB で起動する仮想マシンを復元するには、`VPhone.bundle` 2.10.1 以降が必要です。

## 仮想マシンが使う ROM

新しい仮想マシンは、Virtualization.framework に含まれるクローズドな ROM ではなく、2 つのオープンソースの ROM から起動します。

- [OpenAVB](https://github.com/owngoal-dev/OpenAVB) はブート ROM である AVPBooter の代わりです。パッチが不要なので、`fw patch` は変更を加えません。
- [OpenSEP](https://github.com/owngoal-dev/OpenSEP) は SEP ブート ROM である AVPSEPBooter の代わりです。

両方を使うと、iBoot と SEPOS より前に実行されるコードに Apple が書いたものはなくなります。以前のバージョンで作成した仮想マシンは、切り替えるまで Apple の ROM を使い続けます。

## ROM の出どころ

どちらの ROM も、固定した上流のコミットからビルドされた状態で `VPhone.bundle` に含まれています。それぞれの README に、ビルドし直してバイト単位で照合する方法が記載されています。

- [OpenAVB の README](../../../VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/README.md)
- [OpenSEP の README](../../../VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/README.md)

詳しくは、[OpenAVB](../../../Research/Firmware/openavb_boot_rom.md) と [OpenSEP](../../../Research/Firmware/opensep_sep_rom.md) の研究記録をご覧ください。

## 関連項目

- [仮想マシンの作成と実行](create-and-run.md)
- [ファームウェアの準備](../firmware/firmware-preparation.md)
- [トラブルシューティング](../help/troubleshooting.md)
