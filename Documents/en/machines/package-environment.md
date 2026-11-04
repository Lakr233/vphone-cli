# Package Environment

Install a package manager in the VM, or remove it. A new VM has no package manager; follow this page when you need `apt`, a shell, SSH or other command-line tools in the guest.

## Install

1. In the VM window's menu bar, choose **Apps > Install Bootstrap…** and select the **roothide** layout (**rootless** is deprecated). This installs Irisin in the VM.
2. In Irisin, open the **OwnGoal Packages** repository, find **OwnGoal Bootstrap for vphone** (`owngoal-bootstrap-vphone`), and install it with **Bootstrap Install**.
3. After this first installation, install further packages normally.

`owngoal-bootstrap-vphone` brings in everything a VM needs in a single pass: `apt` and `dpkg`, `bash`, `zsh` and `dash`, `sudo`, the core command-line tools, `openssh-server`, `curl`, `wget`, `vim`, `git`, `uikittools`, `launchctl`, and the OwnGoal apps.

> [!WARNING]
> Do not install these packages one by one. Several depend on one another, and `openssh-server` declares some dependencies circularly, so separate installs can fail partway.

If the first installation fails, do not repair it in place. Choose **Apps > Uninstall Bootstrap…**, then start again from step 1.

### Install while creating the VM

```sh
vphone-cli vm create myphone --bootstrap roothide ...
```

`--bootstrap roothide` does steps 1 and 2 during the new machine's first boot: it installs Irisin, then `owngoal-bootstrap-vphone` with Bootstrap Install through `irisin-cli`, from the repositories Irisin recommends. Step 2 needs an Irisin whose `irisin-cli install` has `--repository` and `--bootstrap-install`.

## Remove

Choose **Apps > Uninstall Bootstrap…**. The VM restarts after removal.

Irisin keeps its data (downloads, journal, settings) in `Documents/wiki.qaq.irisin` under its home:

| Layout | Irisin's home | After uninstalling |
| --- | --- | --- |
| roothide | The environment's own `/var/mobile` | The data is removed with everything else. |
| rootless | The system's `/var/mobile` | The data stays. |

## More options

Hold Option while opening the **Apps** menu to see two more items:

- **Install Bootstrap from File…:** Installs from a local Irisin `.deb`.
- **Uninstall Bootstrap Without Restarting…:** Removes the environment without restarting the VM.

The same operations are available through the automation API (`bootstrap.install`, `bootstrap.status`). See the [API reference](../../../Research/vphoned_http_api.md).

## See also

- [Create and Run a VM](create-and-run.md)
- [Automation API](automation-api.md)
- [Troubleshooting](../help/troubleshooting.md)
