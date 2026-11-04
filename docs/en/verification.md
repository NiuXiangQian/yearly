# Verification scope and known limitations

[简体中文](../verification.md) | **English** · [Home](../../README.en.md)

This document records only publicly shareable functional verification. It contains no real family data, accounts, service addresses, private storage identifiers, or deployment-instance status. Public screenshots use the fictional data in `docs/images/demo-*.png`.

## Latest functional verification

As of November 4, 2026, the date selection, language switching, and high-resolution screenshot verification round recorded:

| Check | Result | Scope |
| --- | --- | --- |
| Frontend Vitest | 43 passed | Current frontend test suite |
| Backend pytest | 15 passed in the previous round | Backend unchanged and not rerun this round; the earlier subset covered organization and folders |
| Type checking and production build | Passed | vue-tsc, Vite |
| Browser checks | Passed | Date entry and month/year switching, live language changes and refresh persistence, upload draft preservation, required birthdays and leap days, 390px English layout |

Screenshots use an isolated fictional API, with no connection to family MySQL or OSS. The upload screenshots show locally selected files waiting to upload, not a real OSS upload. Four screenshots per language are lossless 3024px-wide PNGs without EXIF or other ancillary metadata.

These are development verification results, not acceptance of every deployment environment. Revalidate in your own separate test environment after dependency, configuration, or feature changes.

## Covered functionality

- **Timeline and organization:** Capture times separate from archive dates, date confirmation when appending, named batches, mixed root ordering, folder ordering, bulk moves, pagination/filtering, and default-order reset.
- **Children and journals:** Multiple child associations, birthday/month-age boundaries, independent avatars, shared growth journals, covers and media order, soft deletion and recovery.
- **Uploads and originals:** Multipart retries, repeated completion, CRC verification, cross-batch deduplication, dual-resource Live Photos, original metadata preservation, and missing values.
- **Permissions and sessions:** Unauthenticated access, rejection of read-only writes, administrator boundaries, CSRF, Origin, CAPTCHA, session invalidation, and private-file signing.
- **Compressed previews:** Image thumbnails and detail previews, HEIC originals on demand, synthetic-video transcoding, no automatic original load while video previews are unavailable, image zoom, and video controls.
- **Backups and environments:** Independent MySQL configuration, manifest exports, legacy compatibility, relationship restoration, original-backup verification, and rejection of corrupt backups.

The JPEG EXIF fixture is a synthetic color block with test device fields, dates, and GPS values. Video tests use synthetic media, not family recordings. Mocks do not replace acceptance against real OSS, devices, and deployed infrastructure.

## Run checks

Configure `.env.test` with a separate MySQL database whose name ends in `_test`, then migrate it:

```bash
./scripts/manage.sh test migrate
./scripts/test.sh
```

Database tests use an outer transaction and SAVEPOINT rollback to restore existing records. Auto-increment sequences may still advance. Stop API and preview processes connected to that test database before running tests. Never run them against production.

For frontend checks only:

```bash
cd frontend
npm test
npm run build
```

## Deployment and device checks still required

1. Private OSS RAM permissions, CORS, HTTPS domains, and service-region configuration.
2. Long-running background uploads, real touch gestures, and native fullscreen on iPhone / Android. A mobile-sized desktop browser is not a real-device test.
3. Device-specific HEIC, MOV, RAW, VFR, MakerNote, and QuickTime metadata variants. Keep missing fields empty and use compatible previews or manual corrections where needed.
4. Whether phone photo pickers deliver originals and all Live Photo resources; a web app cannot force this behavior.
5. FFmpeg support, temporary disk space, and CPU capacity for the video preview worker. Transcoding has original-read and processing costs; smaller files do not directly equal billing savings.
6. Database and original-file backup, validation, and restore drills with writes stopped.

SHA-256 returned by OSS HEAD is client-declared metadata. Upload integrity is checked by comparing CRC64; the original-file backup process independently audits full byte-level SHA-256. See [storage](storage-and-metadata.md) and [backup](backup-restore.md).
