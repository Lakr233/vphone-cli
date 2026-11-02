# Package Environment

The VM has no package manager by default. To install one:

1. In the menu bar, choose **Apps > Install Bootstrap…** and select the **roothide** layout (**rootless** is deprecated). This installs Irisin in the VM.
2. In Irisin, open the **OwnGoal Packages** repository, find **OwnGoal Bootstrap for vphone** (`owngoal-bootstrap-vphone`), and install it with **Bootstrap Install**.

   This one package brings in everything a VM needs in a single pass: `apt` and `dpkg`, `bash`, `zsh` and `dash`, `sudo`, the core command-line tools, `openssh-server`, `curl`, `wget`, `vim`, `git`, `uikittools`, `launchctl`, and the OwnGoal apps. Do not install these packages one by one: several depend on one another, and `openssh-server` declares some dependencies circularly, so separate installs can fail partway.
3. After the first installation, install further packages normally.

`vphone-cli vm create <name> --bootstrap roothide` does steps 1 and 2 during the new machine's first boot: it installs Irisin, then `owngoal-bootstrap-vphone` with Bootstrap Install through `irisin-cli`, from the repositories Irisin recommends. Step 2 needs an Irisin whose `irisin-cli install` has `--repository` and `--bootstrap-install`.

If the first installation fails, do not repair it in place. Choose **Apps > Uninstall Bootstrap…**, then start again from step 1.

## Remove the Environment

Choose **Apps > Uninstall Bootstrap…**. The VM restarts after removal.

Irisin keeps its data (downloads, journal, settings) in `Documents/wiki.qaq.irisin` under its home. On **roothide** that home is the environment's own `/var/mobile`, so uninstalling removes the data with everything else. On **rootless** it is the system's `/var/mobile`, and the data stays.

Hold Option while opening the **Apps** menu to see two more options:

- **Install Bootstrap from File…:** Installs from a local Irisin `.deb`.
- **Uninstall Bootstrap Without Restarting…:** Removes the environment without restarting the VM.
