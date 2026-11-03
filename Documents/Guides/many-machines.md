# Create many machines

[Documentation](../README.md) · [Create and Run](create-and-run.md) · [Templates](templates.md)

`vm create-bulk <list.plist>` creates every machine a plist describes. Each key is a `vm create` option's long name, with its value: a string or integer, `true` for a flag, an array for `keep-apps`. `defaults` apply to every machine, a machine's own keys win, and `false` clears a default. Relative paths resolve against the plist's folder. `library-root` puts the machines in another library; `-l` on the command line overrides it.

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

Every machine must name its firmware (`iphone-version`, `iphone-build`, or `iphone-source` with `cloudos-source`) or a `template`, so nothing prompts. All machines are checked as `vm create` checks them before the first is made, and `--dry-run` prints each one's `vm create` command. A name that exists is an error. `--skip-existing` skips it, so a run that stopped can be run again for the rest; a machine that failed is left as it stopped, so delete it first or it is skipped too. `--force-override` deletes that VM just before its machine is created, and refuses one that is running or a folder that is not a VM. Machines are created in order, so those with one template key clone the template the first one built, and the first failure stops the run. Run it with `sudo` when a machine needs a build, as `vm create`.
