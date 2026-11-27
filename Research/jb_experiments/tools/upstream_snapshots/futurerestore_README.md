# futurerestore
_It is a hacked up idevicerestore wrapper, which allows manually specifying SEP and Baseband for restoring._

Latest compiled version can be found [here](https://github.com/tihmstar/futurerestore/releases).

__Only use if you are sure what you're doing.__

---

# Features  
* Supports the following downgrade methods:
  * Prometheus 64-bit devices (generator and ApNonce collision mode)
  * Odysseus for 32-bit & 64-bit (A7-A11) devices
  * Re-restoring 32-bit devices to iOS 9.x with [alitek123](https://github.com/alitek12)'s no-ApNonce method (alternative — [idevicererestore](https://downgrade.party)).
* Allows restoring to non-matching firmware with custom SEP+baseband

# Dependencies
* ## External libs
  Make sure these are installed
  * [libzip](https://github.com/nih-at/libzip);
  * [libcurl](https://github.com/curl/curl);
  * [openssl](https://github.com/openssl/openssl) (or CommonCrypto on macOS/OS X);
  * [libplist](https://github.com/libimobiledevice/libplist);
  * [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd);
  * [libirecovery](https://github.com/libimobiledevice/libirecovery);
  * [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice);
  * [img4tool](https://github.com/tihmstar/img4tool);

* ## Submodules
  Make sure these projects compile on your system (install it's dependencies):
  * [jssy](https://github.com/tihmstar/jssy);
  * [tsschecker](https://github.com/tihmstar/tsschecker);
  * [idevicerestore](https://github.com/tihmstar/idevicerestore)

## Report an issue
You can do it [here](https://github.com/tihmstar/futurerestore/issues).

### Restoring on Windows 10
1.  Try to restore the device, error `-8` occurs;
2.  Leave the device plugged in, it'll stay on the Recovery screen;
3.  Head over to device manager under control panel in Windows;
4.  Locate "Apple Recovery (iBoot) USB Composite Device" (at the bottom);
5.  Right click and choose "Uninstall device".
    You may see a tick box that allows you to uninstall the driver software as well, tick that (all the three Apple mobile device entries under USB devices will disappear);
6.  Unplug the device and re-plug it in;
7.  Go back to futurerestore and send the restore command again (just press the up arrow to get it back, then enter).
    Error `-8` is now fixed, but the process will fail again after the screen of your device has turned green;
8.  Go back to device manager and repeat the driver uninstall process as described above (step 4 to 6);
9.  Go back to futurerestore once again and repeat the restore process;
10. The device will reboot and error `-10` will also be solved;
11. The restore will now proceed and succeed.

### Some about [cURL](https://github.com/curl/curl)
* Linux: Follow [this guide](https://dev.to/jake/using-libcurl3-and-libcurl4-on-ubuntu-1804-bionic-184g) to use tsschecker on Ubuntu 18.04 (Bionic) as it requires libcurl3 which cannot coexist with libcurl4 on this OS.

# Help
_(might become outdated):_

Usage: `futurerestore [OPTIONS] iPSW`

| option (short) | option (long)                                      | description                                                                       |
|----------------|------------------------------------------|-----------------------------------------------------------------------------------|
|  ` -t `           | ` --apticket PATH	 `                    | Signing tickets used for restoring |
|  ` -u `           | ` --update `                                    | Update instead of erase install (requires appropriate APTicket) |
|                       |                                                           | DO NOT use this parameter, if you update from jailbroken firmware! |
|  ` -w `           | ` --wait `                                        | Keep rebooting until ApNonce matches APTicket (ApNonce collision, unreliable) |
|  ` -d `           | ` --debug `                                      | Show all code, use to save a log for debug testing |
|  ` -e `           | ` --exit-recovery `                       | Exit recovery mode and quit |
|                       | ` --use-pwndfu `                           | Restoring devices with Odysseus method. Device needs to be in pwned DFU mode already |
|                       | ` --just-boot "-v" `                     | Tethered booting the device from pwned DFU mode. You can optionally set ` boot-args ` |
|                       | ` --latest-sep `                             | Use latest signed SEP instead of manually specifying one (may cause bad restore) |
|  ` -s `           | ` --sep PATH `                                 | SEP to be flashed |
|  ` -m `           | ` --sep-manifest PATH `              | BuildManifest for requesting SEP ticket |
|                       | ` --latest-baseband `                | Use latest signed baseband instead of manually specifying one (may cause bad restore) |
|  ` -b `           | ` --baseband PATH	`                     | Baseband to be flashed |
|  ` -p `           | ` --baseband-manifest PATH `  | BuildManifest for requesting baseband ticket |
|                       | ` --no-baseband `                         | Skip checks and don't flash baseband |
|                       |                                                           | Only use this for device without a baseband (eg. iPod touch or some Wi-Fi only iPads) |

---

## 0) What futurerestore can do
**Downgrade/Upgrade/Re-restore same mobile firmware version.**
Whenever you read "downgrade" nowadays it means you can also upgrade and re-restore if you're on the same firmware version. Basically this allows restoring an firmware version and the installed firmware version doesn't matter.

---

## 1) Prometheus (64-bit device) - generator method
### Requirements
- Jailbreak
- signing ticket files (`.shsh`, `.shsh2`, `.plist`) with a generator
- nonceEnabler patch enabled

### Info
You can downgrade, if the destination firmware version is compatible with the **latest signed SEP and baseband** and if you **have a signing tickets files with a generator for that firmware version**.

### How to use
1. Device must be jailbroken and nonceEnabler patch must be active
2. Open signing ticket file and look up the generator
  * Looks like this: `<key>generator</key><string>0xde3318d224cf14a1</string>`
3. Write the generator to device's NVRAM
  * Connect with SSH into the device and run `nvram com.apple.System.boot-nonce=0xde3318d224cf14a1` to set the generator *0xde3318d224cf14a1*
  * verify it with `nvram -p`
4. Connect your device in normal mode to computer
5. On the computer run `futurerestore -t ticket.shsh --latest-baseband --latest-sep ios.ipsw`

### Youtube
<a href="http://www.youtube.com/watch?feature=player_embedded&v=BIMx2Y13Ukc" target="_blank"><img src="http://img.youtube.com/vi/BIMx2Y13Ukc/0.jpg" alt="Prometheus" width="240" height="180"/></a>
      *Prometheus*

<a href="http://www.youtube.com/watch?feature=player_embedded&v=UXxpUH71-s4" target="_blank"><img src="http://img.youtube.com/vi/UXxpUH71-s4/0.jpg" alt="Prometheus" width="240" height="180"/></a>
      *nonceEnabler*

### Recommended methods to activate nonceEnabler patch
#### Method 1: ios-kern-utils (iOS 7.x-10.x)
1. Install DEB-file of [ios-kern-utils](https://github.com/Siguza/ios-kern-utils/releases/) on device;
2. Run on the device `nvpatch com.apple.System.boot-nonce`.

#### Method 2: Using special applications
Use utilities for setting boot-nonce generator:
1. [PhœnixNonce](https://github.com/Siguza/PhoenixNonce) for iOS 9.x;
2. [v0rtexnonce](https://github.com/arx8x/v0rtexnonce) for iOS 10.x;
3. [Nonceset1112](https://github.com/julioverne/NonceSet112) for iOS 11.0-11.1.2;
4. [noncereboot1131UI](https://github.com/s0uthwest/noncereboot1131UI) for iOS 11.0-11.4b3;
5. [NonceReboot12xx](https://github.com/ur0/NonceReboot12XX) for iOS 12.0-12.1.2;
6. [GeneratorAutoSetter](https://github.com/Halo-Michael/GeneratorAutoSetter) for checkra1n jailbreak on iOS / iPadOS 13.x. Install it from Cydia's developer repo (https://halo-michael.github.io/repo/) on device.

#### Method 3: Using jailbreak tools
Use jailbreak tools for setting boot-nonce generator:
1. [Meridian](https://meridian.sparkes.zone) for iOS 10.x;
2. [backr00m](https://nito.tv) or greeng0blin for tvOS 10.2-11.1;
3. [Electra and ElectraTV](https://coolstar.org/electra) for iOS and tvOS 11.x;
4. [unc0ver](https://unc0ver.dev) for iOS 11.0-12.2, 12.4.x;
5. [Chimera and ChimeraTV](https://chimera.sh) for iOS 12.0-12.2, 12.4 and tvOS 12.0-12.2, 12.4.

### Activate tfp0, if jailbreak doesn't allow it
#### Method 1 (if jailbroken on iOS 9.2-9.3.x)
  * reboot;
  * reactivate jailbreak with [Luca Todesco](https://github.com/kpwn)'s [JailbreakMe](https://jbme.qwertyoruiop.com/);
  * done.
  
#### Method 2 (if jailbroken on iOS 8.0-8.1 with [Pangu8](https://en.8.pangu.io))
  * install this [untether DEB-file](http://apt.saurik.com/beta/pangu8-tfp0/io.pangu.xuanyuansword8_0.5_iphoneos-arm.deb) with included tfp0 patch
  
#### Method 3 (if jailbroken on iOS 7.x with [Pangu7](https://en.7.pangu.io))
  * install this [untether DEB-file](http://apt.saurik.com/debs/io.pangu.axe7_0.3_iphoneos-arm.deb) with included tfp0 patch

#### Method 4
  * Use [cl0ver](https://github.com/Siguza/cl0ver) for iOS 9.x.

---

## 2) Prometheus (64-bit device) - ApNonce collision method (Recovery mode)
### Requirements
- **Device with A7 chip on iOS 9.1 - 10.2 or iOS 10.3 beta 1**;
- Jailbreak doesn't required;
- Signing ticket files (`.shsh`, `.shsh2`, `.plist`) with a customly chosen ApNonce;
- Signing ticket files needs to have one of the ApNonces, which the device generates a lot;

### Info
You can downgrade if the destination firmware version, if it is compatible with the **latest signed SEP and baseband**. You also need to have **special signing ticket files**. If you don't know what this is, you probably can **NOT** use this method!

### How to use
1. Connect your device in normal or recovery mode;
2. On the computer run `futurerestore -w -t ticket.shsh --latest-baseband --latest-sep firmware.ipsw`
* If you have saved multiple signing tickets with different nonces you can specify more than
one to speed up the process: `futurerestore -w -t t1.shsh -t t2.shsh -t t3.shsh -t t4.shsh --latest-baseband --latest-sep firmware.ipsw`

---

## 3) Prometheus (64-bit device) - ApNonce collision method (DFU mode)
### Requirements
- __Devices with A7 (iPhone 5s, iPad Air, iPad mini 2), A8 (iPhone 6 [+], iPad mini [2,3,4], iPod touch [6th generation]) and A8X (iPad Air 2) chips on all firmwares;__
- __Devices have been released after ~September, 2015 {PROBABLY};__
- Jailbreak doesn't required;
- Signing ticket files (`.shsh`, `.shsh2`, `.plist`) with a customly chosen APNonce;
- Signing ticket files needs to have one of the ApNonces, which the device generates a lot;
- __[img4tool](https://github.com/tihmstar/img4tool) can't be used for Windows [problem with signing iBSS/iBEC], now it's TO-DO;__

### Info
You can downgrade if the destination firmware version, if it is compatible with the **latest signed SEP and baseband**. You also need to have **special signing ticket files**. If you don't know what this is, you probably can **NOT** use this method!

### How to use
1. Connect your device in DFU mode;
2. Use [irecovery](https://github.com/libimobiledevice/libirecovery) for checking ApNonce, which booted in DFU;
3. Extract iBSS/iBEC from target firmware for downgrade (unsigned);
4. Check DFU-collisioned ApNonces with [irecovery](https://github.com/libimobiledevice/libirecovery), which booted in DFU.
    You can't automatically collision DFU ApNonces.
    
    __If ApNonce is not collisioned, "use hands" for DFU booting.__
    
    __If ApNonce is successfully coliisioned, use this SHSH2 for sign iBSS/iBEC.__
5. Use img4tool for sign iBSS:
   `img4tool -s ticket.shsh -c iBSS.signed -p <original_iBSS>`;
6. Use img4tool for sign iBEC:
   `img4tool -s ticket.shsh -c iBEC.signed -p <original_iBEC>`;
7. So, after signing we can boot into Recovery with irecovery.

   `irecovery -f iBSS.signed` - loading iBSS;
   
   `irecovery -f iBEC.signed` - loading iBEC;
8. So good! On the computer run `futurerestore -t ticket.shsh --latest-baseband --latest-sep -w firmware.ipsw`.

---

## 4) Odysseus (32-bit / 64-bit devices)
### Requirements
- futurerestore compiled with libipatcher;
- Jailbreak or bootrom exploit (limera1n, checkm8);
- **32-bit**: firmware keys for the device/destination firmware version must be public (check ipsw.me);
- **64-bit**: devices with **A12** and **A13** chips is **NOT** compatible with this method;
- Signing ticket files (`.shsh`, `.shsh2`, `.plist`) from by destination firmware (OTA blobs work too!).

### Info
If you have a jailbroken device, you can downgrade to **any** firmware version you have blobs for. You can still get OTA blobs for iOS 6.1.3, 8.4.1 or 10.3.3 for some devices and use those.

### How to use
1. Get device into kDFU/pwnDFU
  * Pre-iPhone4s (limera1n devices):
    * Enter to pwnDFU mode with redsn0w or any other tool
  * iPhone 4s and later 32-bit devices:
    * Enter to kDFU mode with kDFU app (cydia: repo.tihmstar.net) or by loading a pwnediBSS from any existing odysseus bundle
  * Any 64-bit device:
    * Enter to pwnDFU mode and patch signature check with special fork of [ipwndfu](https://github.com/LinusHenze/ipwndfu_public)
2. Connect your device to computer in kDFU mode (or pwnDFU mode)
3. On the computer run `futurerestore --use-pwndfu -t ticket.shsh --latest-baseband firmware.ipsw`

### Youtube
<a href="http://www.youtube.com/watch?feature=player_embedded&v=FQfcybsEWmM" target="_blank"><img src="http://img.youtube.com/vi/FQfcybsEWmM/0.jpg" alt="Odysseus" width="240" height="180"/></a>   *futurerestore + libipatcher*

<a href="http://www.youtube.com/watch?feature=player_embedded&v=8Ro4g6StPeI" target="_blank"><img src="http://img.youtube.com/vi/8Ro4g6StPeI/0.jpg" alt="Odysseus" width="240" height="180"/></a>  *kDFU app*

<a href="http://www.youtube.com/watch?feature=player_embedded&v=Wo7mGdMcjxw" target="_blank"><img src="http://img.youtube.com/vi/Wo7mGdMcjxw/0.jpg" alt="Odysseus" width="240" height="180"/></a>  *Enter kDFU mode (watch up to the point where the screen goes black)*  

You can use **any** odysseus bundle for this.

## 5) iOS 9.x re-restore bug by @alitek123 (only for 32-bit devices)
### Requirements
- Jailbreak doesn't required;
- Signing ticket files (`.shsh`, `.shsh2`, `.plist`) from by iOS 9.x without ApNonce (noNonce APTickets)

### Info
If you have **signing tickets files for iOS 9.x**, which **do not contain a ApNonce**, you can restore to that firmware.

### How to use
1. Connect your device in DFU mode
2. On the computer run `futurerestore -t ticket.shsh --latest-baseband ios9.ipsw`
