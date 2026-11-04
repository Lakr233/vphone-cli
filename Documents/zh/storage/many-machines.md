# 批量创建虚拟机

`vm create-bulk` 按顺序创建 plist 中描述的每台虚拟机。可以用它从一个文件搭建实验室或 CI 虚拟机群。

## 运行

```sh
vphone-cli vm create-bulk list.plist --dry-run   # print each machine's vm create command
vphone-cli vm create-bulk list.plist
```

与 `vm create` 一样，当某台虚拟机需要构建时，请用 `sudo` 运行。

## 编写列表

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

- 每个键是 `vm create` 选项的长名称，后面跟它的值：字符串或整数，标志用 `true`，`keep-apps` 用数组。
- `defaults` 适用于每台虚拟机。虚拟机自己的键优先，`false` 会清除默认值。
- 相对路径以 plist 所在的文件夹为基准解析。
- `library-root` 把虚拟机放到另一个资料库中；命令行中的 `-l` 会覆盖它。
- 每台虚拟机都必须指定固件（`iphone-version`、`iphone-build`，或 `iphone-source` 加 `cloudos-source`）或 `template`，这样运行过程中不会出现任何提示。

## 运行方式

在创建第一台虚拟机之前，所有虚拟机都会像 `vm create` 那样接受检查。虚拟机按顺序创建，因此模板键相同的虚拟机会克隆第一台构建出的模板。遇到第一个失败就会停止运行。

名称已存在会被视为错误。有两个标志可以改变这一行为，但不能同时使用：

| 标志 | 作用 |
| --- | --- |
| `--skip-existing` | 跳过名称已存在的虚拟机，这样中途停止的运行可以再次执行，以创建剩下的虚拟机。失败的虚拟机会保持停止时的状态，因此请先删除它，否则它也会被跳过。 |
| `--force-override` | 在创建某台虚拟机之前删除同名的虚拟机。如果该虚拟机正在运行，或者该文件夹不是虚拟机，则拒绝执行。 |

## 另请参阅

- [模板](templates.md)
- [构建与查找模板](template-building.md)
- [创建与运行虚拟机](../machines/create-and-run.md)
