# Create many machines

`vm create-bulk` creates every machine a plist describes, in order. Use it to set up a lab or CI fleet from one file.

## Run it

```sh
vphone-cli vm create-bulk list.plist --dry-run   # print each machine's vm create command
vphone-cli vm create-bulk list.plist
```

Run it with `sudo` when a machine needs a build, as with `vm create`.

## Write the list

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

- Each key is a `vm create` option's long name, with its value: a string or integer, `true` for a flag, an array for `keep-apps`.
- `defaults` apply to every machine. A machine's own keys win, and `false` clears a default.
- Relative paths resolve against the plist's folder.
- `library-root` puts the machines in another library; `-l` on the command line overrides it.
- Every machine must name its firmware (`iphone-version`, `iphone-build`, or `iphone-source` with `cloudos-source`) or a `template`, so nothing prompts.

## How the run behaves

All machines are checked as `vm create` checks them before the first is made. Machines are created in order, so those with one template key clone the template the first one built. The first failure stops the run.

A name that already exists is an error. Two flags change that; they cannot be combined:

| Flag | Effect |
| --- | --- |
| `--skip-existing` | Skips a machine whose name exists, so a run that stopped can be run again for the rest. A machine that failed is left as it stopped, so delete it first or it is skipped too. |
| `--force-override` | Deletes that VM just before its machine is created. Refuses one that is running, or a folder that is not a VM. |

## See also

- [Templates](templates.md)
- [Building and finding templates](template-building.md)
- [Create and run a machine](../machines/create-and-run.md)
