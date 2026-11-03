# Apple Intelligence eligibility on the Duo VM — 2026-10-29

Read-only investigation on iPhone-Duo, iPhone19,4 / 27.1 (24A94425),
cloudOS 26.4 (23E5207q), local bundle 2.14.0-local.e1ece920.
The AI services were restored before probing; core model/runtime daemons run.
No region, MobileGestalt cache, eligibility file or device-tree value changed.

A temporary Foundation executable called MGCopyAnswer in a separate process:

| Key | Answer |
| --- | --- |
| ProductType | iPhone19,4 |
| DeviceClass | iPhone |
| HardwarePlatform | vresearch1 |
| IsVirtualDevice | true |
| HasAppleNeuralEngine | true |
| AppleNeuralEngineSubtype | 784 |
| generative-model-systems | false |
| I3lidq+FVH2CeOi/ARa0tg (hashed form) | false |
| DeviceSupportsGenerativeModelSystems | false |
| SiriMode | 0 |

The key names/hashes were cross-checked against PoomSmart/MGKeys mapping.h.
IORegistryEntryCreateCFProperty at IODeviceTree:/product returned assistant=1,
exclaves-enabled=0 and no vm-supports-generative-models property. The same VM
property was absent at the root. Its absence is a possible upstream cause,
not a demonstrated causal explanation of MobileGestalt's false answer.

The GREYMATTER eligibility record has overall answer 2 and its
OS_ELIGIBILITY_INPUT_GENERATIVE_MODEL_SYSTEM input is 2; the device class,
languages, language match, region-code, shared-iPad and external-boot-drive
inputs are 3. Billing input is 7 and country-location input is 1. Numeric
country statuses were not interpreted as proven additional blockers.
SIRI_MODE also has input DEVICE_SIRI_MODE=2. Siri AI's saved isEnabled=false
is an outcome/current setting, not proof of the upstream cause.

A second temporary executable used Apple's public FoundationModels API.
SystemLanguageModel.default.availability and
PrivateCloudComputeLanguageModel().availability both returned
unavailable(deviceNotEligible). No prompt or generation request was sent.

Conclusion: local device/model capability eligibility is a confirmed blocker,
independent of any later online attestation failure. A successful account or
region change alone has not been shown to fix it. The next isolated experiment
would change the capability answer at its source and re-query eligibility;
that is not yet authorized or performed, nor does it establish working model
execution or Private Cloud Compute access.

Probe sources/results are in .vphone-setup/ai-diagnosis in the working folder.
Temporary guest probe executables were removed after reading the results.

## Follow-up capability and inference experiments

The user authorized fixing the eligibility gates. Original MobileGestalt cache
and eligibility output files were saved under .vphone-setup/ai-diagnosis.
Setting CacheExtra keys A62OafQ85EJAiiqKn4agtg and
I3lidq+FVH2CeOi/ARa0tg to true made the corresponding MG answers true, survived
reboot, and changed GREYMATTER's GENERATIVE_MODEL_SYSTEM status from 2 to 3.
The overall answer then became 1, with country billing=7 and location=1.
A SiriMode=2 numeric cache override yielded unstable nonsensical values in the
probe, including after reboot and with an explicit NULL MGCopyAnswer options
argument; it was removed. Do not reuse that override without understanding its
encoding on 27.1.

A narrow cached-result test set only GREYMATTER and FOUNDATION_MODELS answers
to 4 and their billing/location statuses to 3. Both public FoundationModels
availability APIs then returned available. A local, nonpersonal generation
request still failed with SensitiveContentAnalysisML 15, ultimately
com.apple.tokengeneration 5. Capture from HostInferenceProviderService proved:
`No remote service with name com.apple.modelmanager.remote`.
Modelmanagerd selected host-inference for instruct_300m assets. The unrelated
analyticsd bootstrap error in modelmanagerd's trace was not the inference cause.

Read-only inspection of the Mac's stock modelmanagerd LaunchDaemon shows that
RemoteServices entry gated by ModelManager/virtualization and
RequireEntitlement=AppleInternal. No host service, flags, entitlements or
security policy was changed. Disabling only the guest's existing
ModelManager/virtualization flag and rebooting still selected HostInferencePro
and failed the same generation request. The user reported that the new UI did
appear in the last test configuration, but was insufficient to enable AI.
Thus UI eligibility was partly overcome; a functioning inference backend was
not demonstrated.

The temporary guest ModelManager flag, MobileGestalt overrides and eligibility
output overrides were restored from backups and the VM rebooted. AI/Siri/CarKit
service exceptions remain. Test sources/configurations/results are preserved
for reproducibility. No firmware downloaded.

## Snapshot issue set aside at user's request

Snapshot metadata was generated, but existing .ktx files had UF_COMPRESSED,
compression header type 16, and open/read failed with EIO. This is stronger
evidence of a hybrid-userland/kernel compression incompatibility than a trim
problem. A snapshot-directory-only exclusion in AppleFSCompression's system
rules did not demonstrate a fix; the original rules file was restored when the
user asked to set thumbnail work aside. No snapshot cache was deleted.

Final cleanup verification: a guest reboot did not reconnect the control agent;
a clean Launchpad stop/start recovered it, with vphoned answering in 5 seconds.
The guest is running, unlocked, and / is sealed/read-only again. The original
compression rules and ModelManager virtualization=true were verified; the three
experimental MobileGestalt keys are absent. Siri, CarKit and the 21 AI-related
service exceptions remain enabled. See rollback-verified.json for the check.
