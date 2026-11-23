# Pausing and resuming a guest

How **Device > Pause Guest**, `vphone-cli vm pause` / `vm resume` and the
control socket's `pause` / `resume` hold a running guest, and what was
measured. The user's side is
[Create and Run a VM](../../Documents/en/machines/create-and-run.md#pause-and-resume);
the code is `pause()` and `resume()` in `VPhoneVirtualMachine`.

Measured 2026-11-23 on a MacBook Air (`Mac17,3`, 16 GB RAM), macOS 27.2.1
(`26B131`), with an iPhone17,3 guest on iOS 27.2 (`24B119`) over a cloudOS
27.2 kernel, 8 GB RAM, 5 vCPUs, the SEP coprocessor on OpenSEP.

## The interface

`-[VZVirtualMachine pauseWithCompletionHandler:]` and
`resumeWithCompletionHandler:`, public API since macOS 12. They are the same
pause the core writer uses for a memory dump
([memory_dump.md](memory_dump.md)), so the guest's devices and the SEP
coprocessor stop and start with the vCPUs. Nothing is saved: the paused
guest lives only in the VM service's memory, and `saveMachineStateToURL:`
still refuses a configuration with a coprocessor.

## What was seen

- **The guest stands still.** The kernel debug stub read the same `pc`, `lr`,
  `sp_el0` and `cpsr` on all five vCPUs in two sessions two seconds apart,
  and again before and after a memory dump of the paused guest.
- **It costs the Mac nothing.** The VM service used 0.01 s of CPU in 80 s
  paused, against 2.77 s in 20 s for the same guest idle at its Lock Screen.
- **Fast.** `pause` answered on the control socket in 0.07 s.
- **The guest's clock stands still too.** After pauses of 1.2, 5.0, 10.1 and
  30.4 s, `VPhoneClockSync` found the guest exactly that far behind and set it
  (`[clock] guest was 30.4 s behind, set to the Mac's time`). No watchdog in
  the guest sees the time go by.
- **A memory dump leaves a paused guest paused.** The core writer neither
  resumed it nor needed it running; the dump holds the guest as it stood at
  the pause.
- **Input is held, then replayed at once.** Virtualization keeps HID events
  sent to a paused guest and delivers them together at the resume. A swipe
  up on the Lock Screen sent while paused arrived as a tap ("Swipe up to
  open"); the same swipe while running unlocked the guest.
- **vphoned's connections wait.** A VSOCK request sent while paused is
  answered after the resume, with whatever the host put in it at the time.

## What `vphone-vm` does with it

- **Requests to the guest are refused while paused**, from the moment
  `pause()` is called (`VPhoneGuestControl.isGuestPaused`): a request held
  until the resume would act on what the host knew at the pause, such as
  the Mac's time for the clock. The health probe waits instead of failing,
  so a pause is not a disconnect. A probe already sent at the pause goes
  unanswered until the 120 s socket timeout and its retry is refused; that
  failure is not counted as a disconnect either, which would otherwise make
  a stop of the still-paused guest power it off instead of resuming it.
- **Requests already out at the pause wait** for the guest like any VSOCK
  request, and fail with the same 120 s timeout when the pause outlasts it;
  a file push under way is one.
- **Input is dropped while paused**, so nothing arrives late: the VM view
  takes no mouse input and gives up a captured mouse,
  `VPhoneApplication.takeKeyEvent` passes only menu shortcuts and the
  releases of keys already down, and the control socket refuses `tap`,
  `swipe`, `key` and `hostkey`. Keys and buttons held through vphoned
  (`input.hid`: 🌐, keys the virtual keyboard drops, the TV and hardware
  buttons) are let go before the pause, while the guest still answers: a
  release sent while paused is refused and the key stayed held after the
  resume. A key held in the virtual keyboard gets its release through
  Virtualization, which delivers it at the resume. A tap on the
  Settings icon sent while paused left the Home Screen as it was; the same
  tap while running opened Settings.
- **The clock is set at the resume** (`guestResumedNotification`), and the
  minute's clock timer skips a paused guest. A `time.clock` sent just before
  the pause is answered after the resume with the Mac's time from before
  it, which the guest's stopped clock matches, so it changes nothing;
  `VPhoneClockSync` sends again once it is answered, after it rather than
  beside it so the older time is never the last one the guest takes.
- **Stopping resumes first.** Closing the window, ⌘Q, `vm stop` and
  Control-C resume a paused guest so it can shut down through vphoned; a
  paused guest stopped with `vm stop` shut down in 6.9 s. **Restart Guest…**
  and **Shut Down Guest…** resume it too. A pause or resume on its way, or a
  memory dump, is waited for first (`resumeWhenSettled()`), and the 15 s
  shutdown limit starts only after it: started at the stop, it turned a
  paused guest off in the middle of a dump and left the dump's folder
  empty (2026-11-24). A guest that cannot be resumed is turned off and the
  log says why. `vphone-cli vm stop` still sends SIGKILL after its
  `--timeout` (20 s).
- **One change at a time.** A second `pause` or `resume` while one is on its
  way through Virtualization is refused as busy, not answered early.
- **Not during a dump.** `pause()` and `resume()` refuse while a memory dump
  of the VM is being taken; the core writer does its own pause and resume.

## Not covered

- Pausing across a sleep of the Mac, and pauses of hours.
- Network peers of the guest: a long pause can outlast their timeouts, as
  a long sleep of a real device would.
