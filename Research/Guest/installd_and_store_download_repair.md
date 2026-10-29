# installd and Store downloads: retained repair

Two separate failures were repaired on the iPhone19,4 guest with iOS 27.1
24A94425 and cloudOS 26.4 23E5207q.

## installd: native X1 detour relocation

MISFixDetour.c previously copied PACIBSPPC into its trampoline unchanged.
That instruction binds the link-register signature to its instruction PC and
SP, so moving it changes the signing context. The retained fix signs with
the original PC and SP through PACIB171615, only for the first displaced
instruction; later occurrences are rejected to avoid clobbering prologue state.

The native comparison matched 4,096 signatures; 64 guest MIS signature
validations succeeded. The user subsequently installed their own app through
Xcode, confirming the installd-backed path. The intermediate report saying
installd installation was not yet verified predates that successful install.
The local app, provisioning material, signed probes and raw logs are excluded.
Reproducible probe sources accompany duo_session_handoff.md.

## Store services: built-in app placeholder downloads

The guest's trimmed service profile had disabled the Store and account jobs.
DNS resolved Apple endpoints and HTTPS transport succeeded; this was not a
demonstrated loss of internet access. Restoring the six jobs listed in
store-service-allow.json repaired built-in app downloads:

- Maps downloaded, registered and launched with foreground verification.
- Freeform downloaded and registered.
- appstored subsequently reported download progress for additional built-in
  apps, including App Store itself. Progress alone is not counted as a completed
  installation of every listed app.

This is a per-guest configuration repair. To reproduce without discarding
existing profile groups or exceptions, follow the request-generation and
apply/restart workflow in carplay_connection_diagnosis.md, replacing the
`--slurpfile keep` argument with
`Research/Guest/store-service-allow.json`. Inspect the generated request and
the apply reply's failed array. Keep the original profile locally for rollback.
The Store and CarPlay/Siri allow lists can be combined by union; applying
either workflow to the current profile preserves the other's exceptions.

The default service-trimming policy is unchanged by this collection. Upstream
review should decide how to expose Store/download compatibility for guests
that intentionally retain system-app placeholders or the App Store.

This evidence establishes built-in Apple app restoration, not successful
Apple Account sign-in or third-party FairPlay authorization. Configurator's
App Store-list installation still returned "device is not booted" after client
restart; that separate client workflow is not claimed fixed.
