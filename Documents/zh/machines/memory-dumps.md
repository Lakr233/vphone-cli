# 内存转储

内存转储会把运行中客户机的内存和处理器状态存储为 Mac 上的文件，供 LLDB 或你自己的工具离线分析。复制内存期间客户机会暂停，之后从暂停处继续运行。

转储分三种：

| 类型 | 从哪里开始 | 存储的内容 |
| --- | --- | --- |
| 内核与 vCPU 核心文件 | **Diagnostics > Save Memory Dump…** | 按内核虚拟地址排列的客户机 RAM、每个 vCPU 的寄存器，以及 Secure Enclave 的内存 |
| 物理内存映像 | 同一面板中的复选框 | 按物理地址排列的全部客户机 RAM |
| 单个进程 | Processes 窗口中的 **Save Memory Dump…** | 一个进程的常驻内存，按该进程自己的地址排列 |

## 存储转储

1. 在虚拟机窗口中选择 **Diagnostics > Save Memory Dump…**。
2. 选择一个文件夹。系统会在其中创建一个以虚拟机名称和时间命名的新文件夹，例如 `myphone Memory 2026-11-19 at 15.20.11`。
3. 等待提示转储存储位置的警告框。客户机只在开始阶段暂停，通常为 10 到 20 秒。写入文件时客户机已经恢复运行，写入可能还需要约一分钟。

已[暂停](create-and-run.md#暂停与继续)的客户机也可以转储。它会保持暂停，转储记录的是它暂停时的状态。

在保存转储时停止 VM，会等文件写完后再关闭客户机。`vphone-cli vm stop` 在 20 秒后不再等待，直接关闭客户机电源，转储也随之中断；请给它更长的 `--timeout`，例如 `--timeout 300`。

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

## 物理内存映像

在 Save Memory Dump 面板中勾选 **Physical memory image**，就会存储 `physical.elf` 而不是核心文件。它是一个 ELF 核心文件，客户机 DRAM 和其下方的固件保留区各有一个 `PT_LOAD`，每个段的地址就是客户机物理地址。`VPHONE` 注释（类型 `0x5650`）中的 JSON 记录了机器、客户机内核、内核的物理地址以及页表的根。可以把它交给读取物理内存的工具，或者自己沿客户机页表转换地址。

客户机从未用过的页不会写入文件。客户机会一直暂停到整个映像写完；Mac 内存充足时通常为 10 到 20 秒。

在终端中，给 `memory.dump` 加上 `"physical":true`：

```sh
printf '%s\n' '{"t":"memory.dump","path":"/Users/me/Dumps/myphone-2","physical":true}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

## 转储单个进程

1. 选择 **Diagnostics > Processes**，选中一个进程。
2. 在工具栏或上下文菜单中选择 **Save Memory Dump…**，然后选择一个文件夹。新文件夹以机器、进程和 pid 命名，例如 `myphone SpringBoard (36) Memory 2026-11-20 at 10.02.03`。

vphone 在 Mac 上读取进程的内存，无需客户机协助：它在客户机 RAM 中找到客户机内核，沿进程列表找到该 pid，然后复制进程页表映射的每一页。期间客户机会暂停，通常只有几秒。vphoned 只提供供你选择的进程列表。如果存储时该 pid 已属于另一个进程，转储会被拒绝；请刷新列表后重试。

文件夹中有一个以进程命名的 Mach-O 核心文件和 `info.json`。LLDB 可以打开这个核心文件，并根据其中 dyld 的数据找到进程的映像：

```sh
lldb -c "myphone SpringBoard (36) Memory 2026-11-20 at 10.02.03/SpringBoard.core"
(lldb) image list
(lldb) memory read 0x104218000
```

核心文件只包含进程的常驻页。进程从未访问过的页、被客户机压缩或换出的页，以及线程和寄存器都不在其中。每个段的权限取自页表项。

在终端中，用 pid 发送 `process.dump`。`name` 可选；给出时，进程名称不符就会拒绝转储：

```sh
printf '%s\n' '{"t":"process.dump","pid":36,"name":"SpringBoard","path":"/Users/me/Dumps/springboard"}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

进程转储适用于内核属于 vphone 自带的某个内核缓存配方（iOS 18.1 到 27.2）的客户机；vphone 需要该内核符号表中的两个地址。对于其他内核，转储会提示内核未知。

## 空间与时间

- `AP.core` 比客户机的 RAM 稍大，8 GB 的客户机约为 8.6 GB。全零的块不会写入文件，因此在 APFS 宗卷上它只占用实际数据的空间，通常是客户机 RAM 的大部分。
- 如果宗卷的可用空间少于客户机 RAM 再多一点，存储会在暂停客户机之前被拒绝。进程转储需要 4 GB。
- 客户机暂停期间，macOS 会保留其内存的副本。在内存紧张的 Mac 上，暂停和写入都会更久。
- 客户机暂停期间其时钟停止走动。客户机恢复运行后，`vphone-vm` 会立即把它的时钟调回 Mac 的时间。
- 同一台虚拟机一次只能存储一个转储。

内核与 vCPU 核心文件需要 Virtualization 框架能够写出内存核心文件的 macOS。macOS 27.2 可以；不支持的 macOS 上该菜单项不可用，`memory.dump` 也会说明原因。物理内存映像和进程转储从运行虚拟机的 Virtualization 进程中读取客户机 RAM，因此需要关闭系统完整性保护的调试限制，这也是 [宿主机设置](../get-started/host-setup.md) 已经要求的。

关于转储的实现方式和测量结果，请参阅 [`Research/Host/memory_dump.md`](../../../Research/Host/memory_dump.md) 和 [`Research/Host/process_memory_dump.md`](../../../Research/Host/process_memory_dump.md)。

## 另请参阅

- [创建与运行虚拟机](create-and-run.md)
- [设备名称与时钟](device-name-and-clock.md)
