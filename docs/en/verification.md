# Verification scope and known limitations

[简体中文](../verification.md) | **English** · [Home](../../README.en.md)

This document records only publicly shareable functional verification. It contains no real family data, accounts, service addresses, private storage identifiers, or deployment-instance status. Public screenshots use the fictional data in `docs/images/demo-*.png`.

## Interface refinement verification (2026-11-05)

Based on the [description and chapter notes of Ludi's video](https://www.douyin.com/video/7699196387954642214), this update uses subtle surface layers, lighter dark-theme weights, tabular numerals, and feedback matched to each action. yearly has no streaming chat; soft reveals apply to compressed previews and month expansion, while selection, keyboard focus, and drop indicators remain visible.

- All 62 frontend tests, type checking, and the production build passed. This frontend-only update requires no database migration; backend and real OSS tests were not repeated.
- Isolated fictional-data browser checks covered desktop light/dark themes, month collapse/expansion, folder previews and the move-out indicator, 390px profiles, the English upload page, and the Chinese shared timeline. Checked mobile pages had no horizontal overflow; preview screenshots were saved.
- Browser styles confirmed heading weights of 600 in light mode and 500 in dark mode, plus tabular date/counter numerals. With reduced motion enabled, month animations and image opacity transitions were disabled.
- Images still request existing thumbnails; original-file access and sharing authorization are unchanged. Drag changes are visual only; actual move/sort writes were not revalidated this round. Production was not deployed.

## Optional growth timeline verification (2026-11-05)

- All 62 frontend tests, type checking, the production build, and 29 relevant backend tests passed. Coverage includes child/pet defaults on, other people defaults off, explicit preferences, legacy clients preserving preferences, and new/legacy backup restoration.
- Disabled profiles omit media/journal ages and return no growth milestones. People and pets remain available for shared tagging and any/all filtering; existing files and associations are preserved.
- Browser checks used isolated fictional data: a parent with a birthday still opens related memories, and a pet can disable growth with the preference saved and age navigation hidden. Chinese/English high-resolution profile screenshots were refreshed; the 390px layout has no horizontal overflow, and a settings screenshot was saved.
- Test MySQL was upgraded to `0011 (head)` and local services resumed. Production was neither migrated nor deployed. OSS was mocked this round; real OSS acceptance was not repeated.

## People and pet category verification (2026-11-04)

- All 60 frontend tests, type checking, the production build, and 28 relevant backend tests passed. Coverage includes relationships, optional birthdays, shared people/pet media and journals, bulk links, deduplication, deletion preserving other links, and new/legacy backups.
- Browser checks used isolated fictional data for grandparent creation, relationship search, pet category filters, tagging people and pets together, preserving editor selections when adding a category, and Chinese/English layouts at 390px. High-resolution screenshots were saved.
- Public shares omit relationships and private profiles; anonymous profile access remains denied. Tests used MySQL and mocked OSS, not real OSS or production acceptance.
- Test MySQL is at `0010 (head)` and local services resumed. Production was neither migrated nor deployed.


## Pet profile verification (2026-11-04)

- All 58 frontend tests, type checking, the production build, and 24 relevant backend tests passed. Coverage includes shared child/pet photos and journals, any/all deduplication, unknown birthdays, avatars, archiving, deletion preserving originals, and new/legacy backup restoration.
- Role and public-sharing boundaries passed: viewers cannot edit pets, members cannot delete profiles, public responses omit profiles and associations, and anonymous access to private profiles and media is denied.
- Browser checks used isolated fictional data for pet creation, mixed selection, unavailable age filtering with unknown birthdays, switching from age view to pets, Chinese/English labels, and 390px layouts. README profile screenshots use 2× resolution.
- Test MySQL was upgraded to `0009 (head)` and local services resumed. Production was neither migrated nor deployed. OSS was mocked in this round; real OSS acceptance was not repeated.


## Shared timeline scrubbing verification (2026-11-04)

- All 56 frontend tests, type checking, and the production build passed. All 24 relevant backend sharing/ordering tests passed. Cases cover date previews during dragging, release/cancel, single dates, keyboard controls, folded months, and unloaded-date jumps.
- Date indexes exclude hidden media, folders, diaries, days, and dates outside the share. Modified anchors cannot expand scope; expired or revoked links return 404.
- Browser checks used fictional data for mouse dragging, 390px touch emulation, jumps in both directions, scroll tracking, and Chinese/English layouts. Emulation is not real-device acceptance.
- No migration is required; production was not deployed. OSS signing is unchanged and was not retested against real OSS in this round; prior evidence is below.

## Previous monthly collapse verification (2026-11-04)

- All 53 frontend tests, type checking, and the production build passed. Cases cover year boundaries, unknown dates, appended pages after collapse, ordering, editing visibility, and English labels.
- Browser checks with fictional data covered individual/all-month folding, ascending order, day expansion, selection/sorting, and 390px Chinese/English layouts in family and shared timelines. High-resolution screenshots were saved.
- This frontend-only update needs no migration and was not deployed to production. Backend and OSS authorization are unchanged; the following results belong to the previous round and were not rerun.

## Previous timeline-sharing verification (2026-11-04)

- Frontend: 49 Vitest tests passed, including date-only share creation, date presets and leap days, public sort order and pagination, expansion, collapse, and expiration cleanup.
- Backend: 43 relevant tests passed across private/public ascending and descending pagination, undated entries, manual ordering, content permissions, cross-share signing rejection, folders, and compressed previews.
- Type checking and production build passed. Test MySQL previously reported `0008 (head)`; this update needs no new migration. Production was not migrated or deployed.
- Browser checks covered sorting and refresh persistence, start-date presets, public-page expansion/collapse, and 390px Chinese and English layouts.
- Real test OSS: an authorized compressed preview returned 200. Unsigned original access, removed or changed processing parameters, changed object paths, and expired signatures returned 403. The bucket was private; the temporary synthetic image was removed.

Screenshots use a separate virtual API with no family MySQL or OSS connection. API tests use test MySQL with mocked signing; the separate real OSS check used a synthetic image with the test configuration. No family photos were used or links sent to real recipients. This does not establish production, external-network, or all-configuration acceptance.

## Previous date and language verification

As of November 4, 2026, the date selection, language switching, and high-resolution screenshot verification round recorded:

| Check | Result | Scope |
| --- | --- | --- |
| Frontend Vitest | 43 passed | Frontend suite at that revision |
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
