# Guest SOCKS5 server

Run [HevSocks5Server](https://github.com/heiher/hev-socks5-server/tree/2.13.1) on a NAT iPhone guest. SOCKS5 clients on the Mac can make TCP connections with `CONNECT` and relay UDP datagrams with `UDP ASSOCIATE`. Clients can send hostnames for the guest to resolve.

## Install and enable

Start the iPhone, then run the installer from the source tree on a Mac with Xcode. **The server is disabled by default.**

```sh
Addons/SOCKS5/install.zsh ~/.vphone/machines/myphone
```

Choose **Diagnostics > Guest SOCKS5 Server** in the VM window to toggle the service for that machine. A checkmark indicates that it is enabled. For command-line control, use the same installer.

```sh
Addons/SOCKS5/install.zsh --enable ~/.vphone/machines/myphone
Addons/SOCKS5/install.zsh --disable ~/.vphone/machines/myphone
```

Once enabled, the server starts when the guest is ready, including on headless boots. Disabling it closes the listener and saves that choice for subsequent boots. Installing an update preserves the current setting and any open connections. The update takes effect the next time the server starts.

Set the Mac client's SOCKS5 endpoint to the guest's `en0` IPv4 address and port `1080`. The listener and UDP relay bind to that NAT address. Other guests that can reach it can use this unauthenticated proxy. A [fixed NAT address](../../Documents/en/networking/addresses.md) keeps the endpoint stable.

The installer builds HEV from a checksum-pinned source release with the iPhoneOS SDK, uploads the executable and license notices through the VM's control socket, and installs a per-user launch agent for this machine.

To uninstall, start the VM and run the command below. Do this before moving or renaming its machine directory, which identifies its launch agent.

```sh
Addons/SOCKS5/install.zsh --uninstall ~/.vphone/machines/myphone
```
