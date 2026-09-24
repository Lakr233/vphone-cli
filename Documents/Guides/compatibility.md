# Firmware compatibility

[Documentation](../README.md) · [Create a VM](create-and-run.md) · [Patch inventory](../../Research/0_binary_patch_comparison.md)

**v2.0.0 VM format:** This release starts only newly created VMs whose
`config.plist` has `schemaVersion=2`. Recreate VMs made by earlier releases
with `vm create`; there is no in-place upgrade. The firmware results below
describe tested pairings, not compatibility with older VM bundles.

## Tested Environments

These are the two iPhone17,3 combinations exercised with the native JB pipeline in [PR #486](https://github.com/Lakr233/vphone-cli/pull/486). Both reached the lock screen and answered a vphoned ping. A fresh 26.6.2 `vm create` also completed all stages and exited successfully after its first-boot ping.

| Validation | iPhone restore IPSW | PCC/cloudOS IPSW | Observed result |
| --- | --- | --- | --- |
| PR #486 | `17,3_26.6.2_23G90` | `26.4-23E5207q` | JB patches, restore, CFW, boot, vphoned ping |
| PR #486 | `17,3_27.0_24A435` | `26.4-23E5207q` | JB patches, restore, CFW, boot, vphoned ping |

The cloudOS 26.4 image was the latest one **verified to contain `vphone600ap` during that investigation**. This is a dated observation, not a promise that it remains the newest available release. Use `vphone-cli fw catalog` to inspect the current catalogue. Other versions may work, but they have not passed this same end-to-end check.

## Earlier reported combinations

The previous README recorded the following host and firmware pairings. They predate the current single-mode flow or lack the same vphoned acceptance evidence, so treat them as research history rather than the current support matrix.

| Host            | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_26.6.2_23G90`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A435`    | `26.4-23E5207q` |
