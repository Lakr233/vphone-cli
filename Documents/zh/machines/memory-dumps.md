# 内存转储

内存转储会把运行中客户机的内存和处理器状态存储为 Mac 上的文件，供 LLDB 或你自己的工具离线分析。复制内存期间客户机会暂停，之后从暂停处继续运行。

## 存储转储

1. 在虚拟机窗口中选择 **Diagnostics > Save Memory Dump…**。
2. 选择一个文件夹。系统会在其中创建一个以虚拟机名称和时间命名的新文件夹，例如 `myphone Memory 2026-11-19 at 15.20.11`。
3. 等待提示转储存储位置的警告框。客户机只在开始阶段暂停，通常为 10 到 20 秒。写入文件时客户机已经恢复运行，写入可能还需要约一分钟。

在终端中，向虚拟机的[控制套接字](create-and-run.md#控制套接字)发送 `memory.dump`，并指定要创建的文件夹。该文件夹必须尚不存在，它的上级文件夹必须存在。

```sh
printf '%s\n' '{"t":"memory.dump","path":"/Users/me/Dumps/myphone-1"}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

文件写完后才会收到回复。回复列出每个文件的大小和实际包含的字节数，以及捕获和写入所用的时间。`vphone-launchpad-cli guest send` 在两分钟后停止等待，因此如果你的 Mac 写入 8 GB 需要更久，请像上面那样使用 `nc`。

## 转储包含的内容

| 文件 | 内容 |
| --- | --- |
| `AP.core` | 按内核虚拟地址排布的客户机 RAM、当时在 vCPU 上运行的进程的用户内存，以及每个 vCPU 的通用寄存器 |
| `SEP-coproc.core` | 安全隔区的内存，约 20 MB |
| `info.json` | 虚拟机、时间、vphone 和 macOS 版本，以及每个文件的大小 |

两个核心都是 Mach-O 核心文件。LLDB 可以直接打开 `AP.core`，每个 vCPU 对应一个线程：

```sh
lldb -c "myphone Memory 2026-11-19 at 15.20.11/AP.core"
```

`thread list`、`register read`、`memory read` 和 `bt` 无需其他准备即可使用。如需符号，请添加客户机启动所用的内核缓存，并用 `target modules load --file <kernelcache> --slide <slide>` 按客户机的 KASLR 偏移加载。

转储不包含物理地址、转换表基址或指针认证密钥等系统寄存器，也不包含内核未映射的内存。

## 空间与时间

- `AP.core` 比客户机的 RAM 稍大，8 GB 的客户机约为 8.6 GB。全零的块不会写入文件，因此在 APFS 宗卷上它只占用实际数据的空间，通常是客户机 RAM 的大部分。
- 如果宗卷的可用空间少于客户机 RAM 再多一点，存储会在暂停客户机之前被拒绝。
- 客户机暂停期间，macOS 会保留其内存的副本。在内存紧张的 Mac 上，暂停和写入都会更久。
- 客户机暂停期间其时钟停止走动。客户机恢复运行后，`vphone-vm` 会立即把它的时钟调回 Mac 的时间。
- 同一台虚拟机一次只能存储一个转储。

转储需要 Virtualization 框架能够写出内存核心的 macOS。macOS 27.2 可以；在不支持的 macOS 上，该菜单项不可用，`memory.dump` 也会说明这一点。

转储的生成方式和测量结果见 [`Research/Host/memory_dump.md`](../../../Research/Host/memory_dump.md)。

## 另请参阅

- [创建与运行虚拟机](create-and-run.md)
- [设备名称与时钟](device-name-and-clock.md)
