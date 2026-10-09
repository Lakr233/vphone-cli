# Photos import over the guest API

`photos.import` creates a PhotoKit image or video asset. Files dropped on the
window still use `files.save_to_files_app`; an item in Files is not a Photos
asset. Both destinations reuse `PUT /v1/files/content?path=...`.

1. Upload a supported file to a unique temporary guest path.
2. Call `photos.import` with `job` (a UUID chosen by the caller), `path` (the
   uploaded file), and `name` (its original single filename).
3. Poll `photos.status` with the same `job` until `complete` is true.

For example, the JSON RPC body after uploading an image:

```json
{"method":"photos.import","params":{"job":"22102381-41FA-49D3-BD6E-83AF5B6C70A7","path":"/var/mobile/Media/upload.png","name":"image.png"}}
```

An accepted job returns `job`, `filename`, `bytes`, `source`, and
`complete: false`. A completed receipt adds `ok`, `imported`, `asset_id`
(on success), and `source_removed`. A refusal returns `ok: false`, `code`
and `error`. Treat `complete: false` as pending, not success. The host helper
`VPhoneGuestControl.importMedia` handles upload progress and receipt polling.

Images: jpg/jpeg/png/heic/heif/gif/tif/tiff/bmp. Videos: mov/mp4/m4v.
Files must be regular files from 1 byte to 256 MiB; symlinks are refused.
At most eight unfinished jobs are accepted. PhotoKit runs serially in
separately executed mobile (uid 501) workers, each bounded to 150 seconds.
HTTP request handling never waits for PhotoKit. A startup timer reconciles
persisted jobs every two seconds.

Jobs live under `/var/mobile/Media/vphone-photo-imports/<job>/`.
Acceptance copies the upload into a private job directory and atomically
publishes the directory, then removes the temporary upload. On failure, the
staged media is retained there. `source_removed` reports removal of this
staged copy after successful asset creation. Receipts remain available for
replay; callers can explicitly remove a finished job directory when they no
longer need its receipt. Do not delete a pending job.

Reusing a job with the same source path and filename returns its existing
state, even after the original upload was consumed. A conflicting reuse is
refused. After a timeout or transport error, query the original job instead of
starting a new one.

Before PhotoKit commits, its placeholder identifier is written to
`pending.json`. Success is persisted to `result.json` before source deletion.
A worker that dies after committing is recovered by fetching that identifier;
recovery never creates another asset. An unresolved transaction retains its
journal and source and returns an error for manual inspection. A lock inherited
by the child prevents a restarted HTTP daemon from racing an older worker.
An alarm also bounds orphaned workers.

Validation (2026-10-09):

- Release `vphoned` and `vphone-vm` build with the selected Xcode SDKs.
- `zsh VPhoneDaemon/Tests/run-photos-tests.sh`: 138 assertions pass with UBSan,
  real files and spawned processes, and a fake PhotoKit library (no access to
  the host's library). Covers image/video resource selection, receipt replay,
  conflicting jobs, failed transactions, crash/exception/timeout after commit,
  unresolved journals, interrupted cleanup, spawn failure, path/type/size
  rejection, the eight-job limit, atomic publication failure, and a worker
  retaining the supervisor lock after the parent's descriptor closes.
- ASan on this host (macOS 26.6.2, selected Xcode 26.0) stalls before `main`.
  A process sample shows `AsanInitInternal` recursively entering malloc via
  `dyld_shared_cache_iterate_text_swift`; ASan coverage is not claimed.
- Live guest image/video import and host integration remain pending. The fake
  library does not prove PhotoKit authorization or actual asset creation.
