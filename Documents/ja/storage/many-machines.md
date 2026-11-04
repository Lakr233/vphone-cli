# 複数マシンの一括作成

`vm create-bulk` は、plist に記述されたすべてのマシンを順に作成します。1 つのファイルから実験環境や CI 用のマシン群を準備するときに使います。

## 実行する

```sh
vphone-cli vm create-bulk list.plist --dry-run   # print each machine's vm create command
vphone-cli vm create-bulk list.plist
```

`vm create` と同じく、マシンのビルドが必要な場合は `sudo` で実行してください。

## リストを書く

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

- 各キーは `vm create` のオプションの長い名前で、値を伴います。値は文字列または整数、フラグには `true`、`keep-apps` には配列を使います。
- `defaults` はすべてのマシンに適用されます。マシン自身のキーが優先され、`false` を指定すると `defaults` の値を消去します。
- 相対パスは plist のあるフォルダを基準に解決されます。
- `library-root` はマシンを別のライブラリに置きます。コマンドラインの `-l` がこれより優先されます。
- 何も入力を求められないように、すべてのマシンでファームウェア（`iphone-version`、`iphone-build`、または `iphone-source` と `cloudos-source`）か `template` を指定する必要があります。

## 実行時の動作

最初のマシンを作る前に、すべてのマシンが `vm create` と同じ方法でチェックされます。マシンは順に作成されるため、テンプレートのキーが同じマシンは、最初のマシンが作ったテンプレートから複製されます。最初の失敗で実行が止まります。

すでにある名前はエラーになります。この動作は次の 2 つのフラグで変えられますが、両方を同時には指定できません。

| フラグ | 効果 |
| --- | --- |
| `--skip-existing` | 名前がすでにあるマシンを飛ばします。途中で止まった実行を、残りのマシンについてやり直せます。失敗したマシンは止まった状態のまま残るため、先に削除してください。削除しないと、そのマシンも飛ばされます。 |
| `--force-override` | そのマシンを作成する直前に、同名の仮想マシンを削除します。実行中の仮想マシンや、仮想マシンではないフォルダは拒否します。 |

## 関連項目

- [テンプレート](templates.md)
- [テンプレートの作成と検索](template-building.md)
- [マシンの作成と実行](../machines/create-and-run.md)
