# OSS, originals, and metadata

[简体中文](../storage-and-metadata.md) | **English** · [Home](../../README.en.md)

## People and pet relationships

Profiles support all people and pets, who can share the same media or journal. The child association rules below also apply to other people and pets; see [People & pets](pets.md).

## Data flow and integrity

The browser selects originals → reads metadata ranges → calculates SHA-256 and CRC64/XZ in 4 MiB chunks → the user confirms → the API creates logical media, child associations, and upload tasks → the API signs each part → the browser sends PUT requests to OSS → the API obtains the authoritative part list from OSS and completes the upload → HEAD verifies size and CRC64 → media is published only after all required resources are complete.

Originals use `originals/YYYY/MM/UUID.ext`; compatible previews use `previews/YYYY/MM/UUID.ext`. User-supplied paths and reused object keys are not used. Completion requests include `x-oss-forbid-overwrite=true`. Part ETags identify parts for OSS completion; they are not whole-file MD5 values. The browser calculates whole-file CRC64 and the server compares it with OSS `x-oss-hash-crc64ecma`. Browser-calculated SHA-256 is stored in the database and object metadata. SHA-256 returned by HEAD is a declaration made at upload time, not independent proof of the object's byte-level hash. The full CLI backup recomputes SHA-256 from every byte as an independent audit.

The upload API does not receive original binaries or modify their EXIF or bytes. Lists, avatars, and journal covers use OSS image processing to produce WebP at a maximum dimension of 480px and quality 70. Details use WebP at a maximum dimension of 1600px and quality 80; OSS also converts HEIC / HEIF. Video lists load only OSS frame captures and never preload original videos. Private preview signatures last 300 seconds and are reused by the frontend while valid. `/media/{mid}/files/{fid}/url` defaults to `purpose=preview`; originals require explicit `purpose=original` or `download=true`.

The separate `generate-previews` worker produces H.264 / AAC MP4 files with a long side no larger than 1280px, a short side no larger than 720px, up to 30fps, CRF 28, a 2.2 Mbps bitrate cap, and faststart. HLG / PQ inputs are tone-mapped to SDR using FFmpeg. SHA-256 deduplication lets unique videos share `previews/video-v1/{sha256}.mp4`; normal generation reads each unique original once. After generation, playback reads only the preview. The worker downloads to a temporary directory, checks size and actual SHA-256, transcodes, uploads, and removes temporary files. Cache state is stored in MySQL `video_preview`. These generated copies are excluded from original-file manifests and backups and can be regenerated. A MySQL named lock allows only one generator per database. Processing tasks interrupted by a crash are retried at the next startup; failed tasks require `generate-previews --retry-failed`. The worker automatically discovers both historical and newly completed uploads.

Images support button, wheel, and pinch zoom, plus panning when enlarged. The video player provides seeking, volume, playback speed, and fullscreen; it loads video data only after play is requested. Live Photos use the same compressed-video workflow when “播放 LIVE” (Play LIVE) is selected. The original-file button displays the file size. HEIC originals use `heic-to` compatibility decoding only when explicitly opened. Keep `worker-src 'self' blob:` in the production CSP. Unsupported previews show a message instead of automatically downloading originals. Original-video playback still depends on browser codec support; download the original to open it in a system player if needed.

OSS image processing and frame capture may incur processing fees. Video preview generation also incurs an initial original download, extra object storage, and CPU cost. Savings come from repeated browsing and playback afterward. Place the worker in the same OSS region where practical and verify savings against actual bills.

The browser uploads each file's parts sequentially, automatically retrying a failed part three times with fresh signatures. Tasks last seven days, upload signatures 15 minutes, and download URLs five minutes. After reopening the page, use “接着珍藏” (Resume upload) to select the original again. Its SHA-256 and size must match. Resume reads the uploaded part list from OSS and skips those parts. Browsers cannot guarantee permanent background execution; keep large uploads in the foreground. Live Photo resources resume separately, and the media appears once the final resource completes.

Integrity errors return 409 and prevent publication. If an assembled object differs from the declaration, retain its record for investigation and create a new upload task. Daily cleanup aborts expired multipart uploads but retains completed objects for recovery and investigation. It does not automatically delete physical originals.

## Bucket and RAM configuration

1. Make the bucket private, disable public read/write, and enable Block Public Access.
2. Enable versioning. The application has no deletion permission; cleanup only aborts multipart uploads. Use versioning together with offline backups.
3. Use `deploy/oss-ram-policy.json` as a dedicated RAM-user policy template. Replace its bucket placeholder and grant GetObject / PutObject / AbortMultipartUpload / ListParts only on the originals / previews prefixes. Backup tools can use the same scope.
4. Set `OSS_REGION` to a region identifier such as `cn-hangzhou`, with an endpoint such as `https://oss-cn-hangzhou.aliyuncs.com`. Signing uses the official SDK's AuthV4. Permanent keys are never sent to the browser.
5. Use `deploy/oss-cors.xml` as the browser CORS template. Set AllowedOrigin to the exact family-site origin; allow PUT / GET / HEAD and signature/content headers; expose ETag and CRC64. Add `http://127.0.0.1:5173` separately for development and remove development origins in production.
6. Signed object keys are derived from database file IDs. The API cannot sign arbitrary object keys, and only the upload task creator can obtain upload authorizations.

Do not disable SDK CRC checks or make a bucket public to solve CORS errors. Use OSS request IDs to debug CORS and signatures. Do not paste complete signed URLs into logs or public issues.

When moving from local development to a server, add the browser's actual origin to the bucket CORS rules. Changing application `ALLOWED_ORIGIN` or Nginx CSP does not update OSS. With only the development origin allowed, file selection and task creation can succeed while direct uploads fail with an OSS network error. HTTP, HTTPS, and different ports are separate origins.

Use this non-writing preflight check with your site, bucket, and region. A successful response must allow the requested Origin, PUT, and Content-Type. Follow it with a real browser upload of synthetic files and an integrity check.

```bash
curl -i -X OPTIONS 'https://your-private-bucket.oss-cn-hangzhou.aliyuncs.com/verification/cors-probe' \
  -H 'Origin: https://yearly.example.com' \
  -H 'Access-Control-Request-Method: PUT' \
  -H 'Access-Control-Request-Headers: content-type'
```

## Mainland China endpoints and custom domains

New mainland China OSS accounts may be subject to default public-domain access, preview, or traffic-entry restrictions. Check the account console and current official OSS guidance; a bucket endpoint alone may not be sufficient.

One deployment option is an ICP-filed domain such as `media.example.com`. Bind it in the OSS console, configure CNAME and HTTPS as instructed, and set `OSS_CUSTOM_DOMAIN=https://media.example.com`. The SDK uses `is_cname=True` while retaining the correct `OSS_REGION` for V4 signing. Match frontend CSP and CORS to the site and OSS domains. Point the media domain directly to OSS so multi-gigabyte media traffic does not pass through the application's Nginx.

The signed hostname must exactly match the hostname used for the upload request. Do not replace the Host after generating a V4 URL. An HTTPS page must not use an HTTP OSS endpoint. Use the custom-domain setup appropriate to the region and verify download / preview responses for the account. Format preview support does not change upload size or integrity checks.

## Photo metadata parsing

`exifr` uses a ranged Blob reader for EXIF / XMP / IPTC in JPEG, PNG, WebP, HEIC/HEIF, TIFF/DNG, and some TIFF-based RAW formats. Date strings are preserved so the browser does not convert timezone-free EXIF into UTC. Available Make, Model, LensModel, Software, Orientation, ISO, exposure, aperture, focal length, flash, white balance, and GPS fields are retained as parsed. Common time, coordinate, device, and dimension values are also stored separately.

Containers, vendor MakerNotes, and browser export behavior can leave fields missing. Complete parsing is not guaranteed for CR3 or vendor RAW formats. Originals can still be stored; unread fields remain unknown. Raw JSON contains what the browser actually parsed, not every vendor tag represented in the file. Metadata is limited to 1 MiB per logical media item. For larger metadata, preserve the original and inspect it offline.

Latitude and longitude come from EXIF or QuickTime ISO6709; altitude is read where available. GPS time, direction, and other fields remain in raw JSON. There is no default geocoding or third-party location request. Manual place and GPS corrections change only the database; raw JSON retains the original values.

## Video parsing and timestamp confidence

A bounded ISO-BMFF walker reads box ranges and skips `mdat`. Limits are depth 12, 12,000 boxes, 1 MiB per leaf, and 8 MiB of total metadata reads. Multi-gigabyte videos are not loaded entirely into memory. Common MOV / MP4 support includes `mvhd` duration, `tkhd` dimensions and rotation, `stsd` codec, `hdlr` audio tracks, `mdhd/stts` constant-frame-rate approximations, and dates, locations, and identifiers from QuickTime keyed metadata.

VFR, unusual tracks, legacy ©day or vendor-private fields, read-budget limits, and uncommon containers may prevent complete parsing. Extracted values are not always authoritative. Numeric QuickTime creation seconds remain in raw JSON; differences in vendor UTC/local conventions mean they are not forced into local capture times. Only interpretable CreationDate strings become reliable date candidates.

Timestamp priority is manual correction, EXIF DateTimeOriginal, EXIF CreateDate / reliable QuickTime CreationDate, file modification time with low confidence, then unknown. Timezone-free strings retain their local date; UTC is calculated only with an explicit offset. File modification time is interpreted in the device's current time zone and is only a fallback, not a claimed capture date.

The system stores the original time, offset, source, and a separate corrected time. Corrections do not overwrite original metadata. Clear a correction in the detail view to restore the original value. To mark a low-confidence timestamp as unknown, select “拍摄时间未知” (Capture time unknown) before uploading.

## Live Photos and iPhone limitations

Reliable pairing prefers a parsed ContentIdentifier or `com.apple.quicktime.content.identifier`. `exifr` may not expose the Apple MakerNote assetIdentifier. Matching filenames alone do not trigger automatic pairing.

Without an identifier, use “手动配对” (Manual pairing) in the upload list to link a static HEIC/JPEG with its MOV. They become one logical media item with two separate `media_file` records; child associations apply to the logical item. Unpair them before uploading if needed. “播放 LIVE” (Play LIVE) in the detail view plays the compressed MP4. Each original has its own download entry; the original MOV loads only when explicitly requested.

iPhone Safari photo-picker files may be converted, exported with edits, or limited to the static resource. A web app cannot force access to PhotoKit originals and all pairedVideo resources. To preserve originals, export unmodified originals from Photos to Files and import both files. The system guarantees lossless transfer of the selected bytes, not camera-original authenticity based on extensions.

### Selection remains in the system photo picker

WebKit tracks [missing feedback while preparing multiple photos](https://bugs.webkit.org/show_bug.cgi?id=325067). The system picker can remain visible while downloading originals and converting formats, before any files reach the page. Single selections and other browsers can also be affected; this screen alone does not establish an iCloud cause. A website cannot observe this download progress or dismiss the system picker.

The upload page offers “Photo picker stuck? Paste your photos”: select photos in the Photos app → Share → Copy Photos, then return to the page, press and hold in the paste box, and choose Paste. A user-initiated paste event adds image files to the existing queue for review before upload. It bypasses the web photo picker and does not depend on the HTTPS-only programmatic clipboard API. Clipboard HTML and text are not inserted.

Pasting provides a system-generated copy that may be converted or omit the capture date and Live Photo motion. Queue items are labeled “Pasted copy”. Existing EXIF capture dates are preserved; modification-time-only or missing dates default to unknown so the copy time is not used as the capture date. Received bytes are uploaded without further compression. Use Import from Files when camera originals are required.

For batches, follow [Apple's original-download steps](https://support.apple.com/en-us/111762): select items in Photos → Share → Export Unmodified Originals, save to On My iPhone, and wait for downloading to finish. Then use Import from Files on the website and choose the system file-browsing option. There is no need to disable iCloud or download the entire library. The Files input omits the media accept filter; the upload API still validates supported formats.

File counts and hashing progress appear only after the browser delivers files. A read failure lists the affected filename while other files continue. Empty results show guidance without claiming to measure iCloud download progress.

### Native iPhone upload

1. Deploy the updated frontend to the family HTTPS site. The existing API and OSS configuration support this flow without a database migration.
2. Open [`ios/Yearly.xcodeproj`](../../ios/Yearly.xcodeproj) in Xcode on a Mac. Select your team under **Signing & Capabilities** for the Yearly target and set a unique bundle identifier if needed. Run on a paired iPhone with iOS 16 or later.
3. Enter the family's HTTPS site address in the Yearly app and sign in. Set the date and people on the upload page, then tap **Choose and upload a Live Photo**. Select one item in the system picker. The app reads the still image and paired video and starts uploading after any applicable archive-date confirmation.

The system picker shares the selected asset with the app. PhotoKit can retrieve its resources from iCloud. The app transfers up to 128 MiB per pair to the upload page in chunks, using the existing session, multipart verification, and retries. If either resource cannot be read, the app skips creation of the upload. On a real device, verify that a Live Photo with sound appears as a single timeline entry, offers both files for download, and plays through **Play LIVE** after the video preview is ready.

## Duplicate imports and child associations

Upload creation matches completed, non-recycled media by media type, original-file roles, SHA-256, and byte size. Renaming an identical original still reuses the existing record; Live Photos compare both static and motion originals. A match returns `duplicate=true`, an empty task list, and a message. The frontend shows “已存在” (Already exists), skips OSS upload, preserves the existing timeline date and manual order, and merges the newly selected children into existing associations. An accompanying compatible preview is not saved again when originals already exist; the response explains this. Files with identical names but different contents remain separate. Recycled records are not automatically restored and do not replace a new upload result.

On first use, the upload page selects the child automatically if there is only one. An explicit empty “家庭时光” (Family time) selection is preserved. Child selection immediately applies to selected files whose upload tasks have not yet been created; each row shows its actual associations. Individual files can still have their associations changed in the detail view.

## Date confirmation when appending

When appending to a specified timeline date, the page checks selected files without created upload tasks before starting. It prefers a corrected local capture date, then a parsed capture / creation date. Modification-time-only dates are marked for confirmation; explicitly unknown dates are excluded. If dates differ, a dialog groups files by date and offers keeping the append date, assigning each file to its own date, or canceling. No tasks are created before confirmation. Unknown-date files stay on the append date. This changes only `timeline_date`, not original files or capture metadata. Per-day ordering follows the upload queue, subject to the default/manual-order rules below. Resumed tasks keep their previous archive date, and duplicate imports retain the existing position. The browser File API does not expose filesystem creation time; modification time must not be described as creation time.

## Daily folders

A folder belongs to one archive date and supports one level of classification, a custom name, and free ordering among the day's root-level photos and videos. By default, folders precede media that is not in a folder. Folder contents are not duplicated in the root list. The age timeline and recycle bin still show a flat media list. Child filtering searches associated media inside folders; empty folders are shared family items.

Media can be moved in bulk only into folders on the same day. Moving media to a different archive date automatically removes it from its old folder. Appending inside a folder uses the same date confirmation: keeping the day places files in the folder, while assigning their own dates puts them in those dates' root lists. Duplicate imports reuse existing media and positions without moving them automatically.

Deleting a folder removes only its classification. Its media, including recycled media, return to the day's root list; originals are unchanged. Portable backups include folders and membership and remain compatible with older manifests without folders.

## Independent avatars

Child profiles can upload JPG, PNG, WebP, or HEIC / HEIF images up to 20 MB. The selection is previewed locally and uploaded when saving the profile. The browser center-crops a square and compresses it to a JPEG no larger than 512×512, without original EXIF / GPS. Independent avatars retain only the compressed copy. Preserve the original family image through the normal media upload flow.

Avatars use private OSS, multipart integrity checks, and short-lived signed reads, isolated from regular media by `purpose=avatar`. They do not appear in media lists, calendar / age timelines, or memory counts. Objects are stored under `avatars/`, count toward actual storage, and are included in full backup / restore. An existing photo can also be used as an avatar. Replacing or clearing an avatar changes the profile reference without deleting family originals.

## Drag-and-drop organization and default ordering

In the calendar timeline, drag photos or videos to reorder them within a day. Dropping at the center of a same-day folder moves them inside; the left/right edges insert items in the root order. Dragging a selection moves selected media from that day. Drag a folder by its title or right-side handle to place it between photos and videos. Inside folders, multiple selected items can be reordered or dragged to the top drop area to return them to the day's root timeline. Cross-date drops do not move items; use the existing date controls to change dates.

Default media order is newest effective local capture time first, with manual corrections taking precedence. Equal timestamps use descending record ID; unknown times go last. Ordinary uploads preserve this rule; only manually adjusting the upload queue saves custom ordering. “恢复默认排序” (Restore default order) in the date bar clears custom order for that day's folders and all active media, including folder contents. Folders return to the beginning and media follow capture time. The same action inside a folder resets only that folder. Reset includes unloaded or filtered-out content, as stated in its confirmation. It does not change folder membership, original metadata, or other dates.

Root-level mixed ordering is saved through `POST /api/timeline/reorder`, identifying each item by both `kind` and `id`. The server calculates order against the complete day, preserving filtered-out and unloaded items. Existing media/folder reorder endpoints use the same root ordering rules; folder contents retain independent ordering. This reuses `sort_order` fields and requires no additional database migration.
