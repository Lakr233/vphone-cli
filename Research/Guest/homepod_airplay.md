# HomePod AirPlay from the Mac

Measured on 2026-10-26 with `homepod-std`: HomePod Software 26.5 (23L471),
`homepod-mini` on the 26.5 kernelcache mix, `system-homepod-exp-setup_bypass`
on, NAT network. The sender is the host Mac's Music app (AppleScript
`current AirPlay devices`), which goes through AirPlayXPCHelper and the Mac's
mediaremoted.

## Before local setup completion

The HomePod advertises `_airplay._tcp` and `_raop._tcp` (model
`AudioAccessory5,1`, `srcvers=950.7.1`) only once setup is done. With the two
`com.apple.purplebuddy` keys alone, port 7000 answers `/info`, pair-setup
succeeds, and the Mac's control session activates.

## The VM discovery gate

The HomePod's airplayd logs `Discovery mode set to none - customer VM build`.
In AirPlaySender, `browserController_updateDiscoveryMode` forces
`kFigEndpointManagerDiscoveryMode_None` when `APSIsVirtualMachine()` is true and
`IsAppleInternalBuild()` is false. Without discovery the HomePod never finds its
own output device (`searchAVOutputDeviceForUID` for its own UID times out), so
its mediaremoted has no local endpoint (`NoLocalEndpointConnection`), and the
Mac's `loadDeviceInfo` over the remote-control channel times out (MediaRemote
error 113; Music reports -15016).

`APSIsVirtualMachine` (AirPlaySupport) caches `sysctlbyname("kern.hv_vmm_present")`
once per process, then clears the flag when the AirPlay setting
`useWiFiAndAWDLOnVirtualMachine` is non-zero (`APSSettingsGetInt64`, domain
`com.apple.airplay`, read with `CFPreferencesCopyAppValue`). The AirPlay
daemons run as mobile, so the value belongs in
`/private/var/mobile/Library/Preferences/com.apple.airplay.plist` (0600,
501:501). Written live through vphoned and followed by a reboot, it changes:

- the discovery mode follows the endpoints again, and airplayd creates
  `APEndpoint-RC` for the HomePod itself;
- after a clean boot the HomePod's mediaremoted opens its local endpoint
  (`Open comm channel completed (err=0)`, 0.11 s);
- the Mac's control session activates and `loadDeviceInfo` returns in 13 ms.

Side effect: airplayd now asks the absent WiFiManager and corewifi about AWDL
Solo support about once a second (`kNotFoundErr`, `NSXPCConnectionInvalid`).

A direct file write is not enough while the guest runs: cfprefsd keeps
serving its cached copy until a reboot. The patch below writes through
CFPreferences instead.

## The audio session: gPTP

With discovery back, the buffered-audio session stalled after pair-setup: the
receiver (`tvairplayd`, AirPlayReceiver) accepted SETUP, created the session
(`TP=PTP`), activated its AVAudioSession and NowPlaying, then never answered.
A guest `spindump` showed the session thread in `CM8021ASClockCreate` →
TimeSync, blocked on a reply from `com.apple.timesync.expositor`
(`audioclocksyncd`). `audioclocksyncd` waits for the kernel's
`IOTimeSyncgPTPManager`, and the IORegistry had none, although
`IOTimeSyncClockManager` carried `WantsgPTPServices = Yes`.

The cause was the kernelcache mix. It took `IOgPTPPlugin` from the B520
kernel, whose `IOTimeSyncgPTPManager` personality adds
`TemperatureSensor = {B520: "PMU tdev1"}`: its start looks up an
`IOHIDEventService` with that `Product`, logs "could not get matching service"
and fails on a VM. Apple's VM build in the vphone600 kernel has the same
personality without the sensor (and without the tvOS Wi-Fi controller). The
iPhone 26.5 mix already pairs that plugin with the research board's own
`IOTimeSyncFamily` 1450.2, so the HomePod recipe now pins the same two:
`IOTimeSyncFamily` from `base`, `IOgPTPPlugin` from `vphone600_26.4_23E5207q`
(`kextOverrides`). The vphone600 family itself does not link against the 26.5
kernel: it imports an `IOPlatformExpert` private function the base does not
provide.

After the relink, restore and CFW (2026-10-27), the guest has
`IOTimeSyncgPTPManager`, an `IOTimeSyncDomain` and a local clock port. With
`useWiFiAndAWDLOnVirtualMachine` set, the Mac's Music selected the HomePod and
played a clip over AirPlay 2 (selected, active, playing); SoundBoard reported
`mediaState 1`, and the audio came out of the host through the virtio sound
device. The top cap stays dark while playing: the media glow is the 27.2+
`system-homepod-exp-sound_glow`.

## The patch: `system-homepod-exp-airplay_vm`

The Data volume is encrypted on the host, so the setting is installed like the
setup completion: the patch puts the marker `/usr/share/vphone/HomePodAirPlay.plist`
on the System volume, and the HomePod setup helper (running as mobile at boot)
does the rest:

- it journals the current value in
  `/var/mobile/Library/Application Support/vphone/HomePodAirPlayOriginal.plist`
  (an absent key is recorded as absent);
- it sets `useWiFiAndAWDLOnVirtualMachine = 1` with `CFPreferencesSetValue`
  (current user, any host) and synchronizes;
- only if the value changed, it sends SIGTERM once to mobile's exact
  `/usr/libexec/airplayd`, `/usr/libexec/tvairplayd` and
  `/System/Library/PrivateFrameworks/MediaRemote.framework/Support/mediaremoted`,
  rechecking each identity first; launchd restarts them and they read the new
  value (`APSIsVirtualMachine` caches it per process);
- it writes `HomePodAirPlayStatus.plist` (`Enabled`, `Succeeded`, `Changed`,
  `Restarted`, `Updated`, `Error`).

With the marker gone, the helper restores the journalled value and then deletes
the journal. Unit tests: `make -C VPhoneGuestComponents test-homepod-setup`
(`HomePodAirPlayTests`).

Validated on 2026-10-27, bundle `2.13.5-local.47579029`, after removing the
manually written pref: the environment update staged the marker, and on the next
boot the status showed `Changed=true`, `Restarted=3`, `Succeeded=true`. The
journal recorded the key as absent, and the Mac's Music played to the HomePod
with no manual step.

## Related limits (2026-10-27)

- **Top cap while playing.** 26.5's NowPlayingCap has no media glow. Its only
  playback effect is a blue `audioTapping` pulse behind the internal default
  `depictNonGroupLeaders` (suite `com.apple.NowPlayingCap`), drawn only while
  the local `MRDeviceInfo.isGroupLeader` is false. With the default set for
  mobile, the LEDs stayed dark playing to the HomePod alone and in a group with
  the Mac's speakers: in both it leads its own group. Only a follower in a group
  led by another HomePod or Apple TV would show it.
- **Setup from a Mac.** With `system-homepod-exp-setup_bypass` off, the
  HomePod in setup mode drops `_airplay._tcp`/`_raop._tcp` and advertises
  `_companion-link._tcp` (and, with the guest BTVC patch, `_btvc._tcp`). The
  macOS Home app cannot add accessories; the Mac's sharingd looks for HomePod
  setup only over Bluetooth LE. Real setup would need an OS 26+ iPhone guest
  reaching the HomePod over BTVC.
- **Top cap input.** The cap's consumer HID events reach SoundBoard; it ignores
  them in two states. With nothing playing there is no volume category
  (`Volume State..OFF with current Volume Category..(null)`), so +/- do
  nothing. While playing, the first press brings NowPlayingCap forward and
  later presses change the volume (0.90 → 0.85 → 0.90, read with the
  debug interface's `getVolume:`); the center tap pauses the sender. Siri can
  also stay the foreground activity while idle (`getAllDebugInfo:`:
  `Foreground Activity: Siri`); SoundBoard then ignores volume input, even its
  own `sendButtonCommand:`. What keeps pushing Siri forward is corespeechd's
  voice-trigger recorder: it asks for 14 channels at 16 kHz (the B520 mic
  array) from a 2-channel 48 kHz virtio input, AudioQueue fails
  (`kAudioQueueProperty_ChannelLayout` -50, `prepareRecordForStream` -11795)
  and it retries about once a second. Turning `VoiceTrigger Enabled` off in
  mobile's `com.apple.voicetrigger` stops the Siri activations, but on two of
  two boots the Mac's Music then selected the HomePod without it becoming
  active (later -15016), while tvairplayd saw no connection; with the value
  restored, playback works. So it is not shipped as a patch. The root fix is a
  virtual input that matches the route's 14-channel layout.
