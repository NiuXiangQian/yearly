# yearly

[简体中文（默认）](README.md) | **English**

**Keep every chapter of growing up.**

A self-hosted, private family archive with **Web, native iOS, and native Android apps**. Organize photos, videos, and growth journals by date, person, and pet. Connect all clients to the same family server to share memories, profiles, and permissions.

Native apps · Original and Live Photo uploads · Daily timeline · Expiring read-only shares · People and pet profiles · Drag-and-drop folders · Compressed previews · Original-file backups

[iOS gallery](#ios-app-gallery) · [Install the app](#ios-app) · [Web screenshots](#screenshots) · [Sharing page](#share-a-read-only-timeline) · [Quick start](#quick-start) · [Deployment](docs/en/deployment.md) · [Backup and restore](docs/en/backup-restore.md)

## iOS app gallery

A native SwiftUI client for iPhone running iOS 16 or later. Preserve originals, browse the family timeline, organize people and pets, and share selected memories with a time limit.

These screenshots show the current native UI in an iPhone simulator with isolated fictional accounts, profiles, and original sample illustrations. No real family photos are included. Each is a **1320 × 2868 px, native 3×, lossless PNG**; click to open the full-resolution image. The app screenshots use Simplified Chinese. See [screenshot notes](docs/images/ios-screenshots.md).

### Timeline, original uploads, and family profiles

Browse by date and filter by profile, uploader, keyword, or media type. Select photos, videos, and Live Photos from the system library, preserve paired still/MOV resources, and pause, retry, or resume persisted uploads. Open memories for each person or pet.

<p>
  <a href="docs/images/demo-ios-timeline.png"><img src="docs/images/demo-ios-timeline.png" width="250" alt="Daily timeline" /></a>
  <a href="docs/images/demo-ios-upload.png"><img src="docs/images/demo-ios-upload.png" width="250" alt="Original uploads" /></a>
  <a href="docs/images/demo-ios-family.png"><img src="docs/images/demo-ios-family.png" width="250" alt="People and pets" /></a>
</p>

[Timeline original](docs/images/demo-ios-timeline.png) · [Upload original](docs/images/demo-ios-upload.png) · [Profiles original](docs/images/demo-ios-family.png)

### Full-screen previews, expiring shares, and accounts

Zoom and swipe through photos, play videos and Live Photos, and share a date range or selected media for 1 hour to 7 days. Manage family accounts, roles, and change history; members can edit only the content they added.

<p>
  <a href="docs/images/demo-ios-preview.png"><img src="docs/images/demo-ios-preview.png" width="250" alt="Full-screen photo preview" /></a>
  <a href="docs/images/demo-ios-share.png"><img src="docs/images/demo-ios-share.png" width="250" alt="Expiring shares" /></a>
  <a href="docs/images/demo-ios-account.png"><img src="docs/images/demo-ios-account.png" width="250" alt="Account and permissions" /></a>
</p>

[Preview original](docs/images/demo-ios-preview.png) · [Sharing original](docs/images/demo-ios-share.png) · [Account original](docs/images/demo-ios-account.png)

[iOS build, installation, and usage guide](ios/README.md) · [Android native client guide](android/README.md)

## Screenshots

These screenshots show the actual application with isolated fictional data. Names, birthdays, entries, and counts are fictional; avatars and media use original sample illustrations. No real family photos or accounts are included. The main gallery shows the English interface; the sharing examples use Simplified Chinese. Both languages are supported. Family names and user-written content are preserved in their original language. These web screenshots are lossless PNGs captured at 2× resolution (3024px wide); open an image or its full-resolution link for details.

### A daily timeline you can organize your way

Drag photos, videos, and folders into any order within a day. Folders display small previews, and custom titles appear over the images.

![Fictional demo: daily timeline with folders and media](docs/images/demo-timeline-en.png)

[Full-resolution timeline screenshot](docs/images/demo-timeline-en.png)

### Organize a whole batch before uploading

Name a batch, select people and pets, and choose an archive date. The compact file list supports bulk selection, drag-to-reorder, and file details.

[Native iPhone upload](docs/en/storage-and-metadata.md#native-iphone-upload) lets you select a Live Photo in the system picker and upload its still image and paired video together.

![Fictional demo: batch naming and upload queue](docs/images/demo-upload-en.png)

[Full-resolution upload screenshot](docs/images/demo-upload-en.png)

### Share a read-only timeline

Set sharing permissions while editing files, folders, or timeline days. Creating a link only requires a date range and a lifetime of 1 hour to 7 days. Links can be revoked at any time.

Recipients browse compressed previews without signing in. They can switch chronological order, collapse months, and expand days beyond eight entries. The timeline on the left marks dates with dots: drag to preview a date, then release to jump and open the corresponding month.

![Fictional demo: read-only sharing page with a left timeline](docs/images/demo-share.png)

[Full-resolution sharing screenshot](docs/images/demo-share.png) · [Sharing guide and permissions](docs/en/sharing.md)

<details>
<summary>View link creation and timeline dragging</summary>

Start from the earliest date, one year ago, six months ago, or a custom date. There is no per-file picker during link creation.

![Fictional demo: share date range and lifetime](docs/images/demo-share-create.png)

Dragging previews the date; releasing loads the target content on demand.

![Fictional demo: date tooltip while dragging the timeline](docs/images/demo-share-drag.png)

</details>

<details>
<summary>View folder organization and people / pet profiles</summary>

### Keep a story together in a folder

Select multiple items, append uploads, drag items into or out of folders, reorder their contents, and restore the default order.

![Fictional demo: folder contents and organization controls](docs/images/demo-folder-en.png)

### People and pets, sharing memories

Create profiles for parents, grandparents, children, friends, and pets. Set custom relationships and pet categories, with optional birthdays. Growth timelines default to on for children and pets and off for other people, who remain available for tagging and filtering. Tag multiple people and pets in each file, then filter by profile or pet category. Shared memories keep one original. See [People & pets](docs/en/pets.md).

![Fictional demo: people and pet profiles](docs/images/demo-profiles-en.png)

</details>

## Features

| Use case | Capabilities |
| --- | --- |
| Organize memories | Daily grouping, named folders, mixed folder/media ordering, bulk selection and moves, default-order reset |
| Record growth | People and pet profiles, individual avatars, age-based browsing, one-month / 100-day / birthday navigation, shared growth journals |
| Upload in batches | Batch names, EXIF / QuickTime date parsing, date checks when appending, cross-batch deduplication, multipart uploads and retries |
| Browse efficiently | Image thumbnails, HEIC / HEIF previews, image zoom and pan, compressed video copies, originals on demand |
| Preserve originals | Direct uploads to private OSS, paired Live Photo resources, original metadata, backups and integrity checks |
| Expiring shares | [Content permissions, date ranges, 1-hour to 7-day lifetime, revocation, collapsible months, eight-entry days, draggable date navigation](docs/en/sharing.md) |
| Share with family | Administrator / member / read-only guest roles, login CAPTCHA, recycle bin, Chinese / English switching, light / dark themes, responsive layout |

Each deployment serves one family. All enabled accounts share the family archive. There is no public registration or multi-tenant isolation.

## Technology and storage

- **Backend:** Python 3.12, FastAPI, SQLAlchemy 2, Alembic.
- **Web:** Vue 3, TypeScript, Vite, Pinia, Element Plus.
- **iOS:** SwiftUI, PhotoKit, AVKit; iOS 16+.
- **Android:** Kotlin, Jetpack Compose, Material 3, Media3; Android 8.0+.
- **Database:** MySQL 5.7.8+ with separate development/test and production configuration; SQLite is not used as a substitute.
- **Files:** Private Alibaba Cloud OSS. Web and native clients upload originals directly; the database stores metadata and relationships.
- **Deployment:** Nginx + systemd, with a separate video preview worker. Redis is not required.

Browsing uses compressed previews by default. Originals are loaded only when explicitly requested through “查看原文件” (View original); preview processing never overwrites them. Initial video transcoding reads the original and requires temporary disk space.

## Interface language and date selection

The web interface defaults to Simplified Chinese. Switch to English on the login page, in the top-right header, or in family settings. The choice is saved in the current browser and survives refreshes. Menus, forms, messages, and calendars switch together; child and pet names, filenames, and journal content remain unchanged.

Long timelines support collapsible months, individual expansion, and Collapse all / Expand all in both family and shared views. Shared views also offer a draggable timeline on the left with date previews and direct jumps.

The timeline offers Day / Month / Year filters, previous/next period buttons, and All time / Today / This month / Day of birth shortcuts (the birthday shortcut appears when one child or pet with a birthday is selected). Type dates directly or click the calendar's year/month heading to navigate quickly. Child and pet birthdays, upload archive dates, and journal times use the same date controls.

## Quick start

### 1. Install dependencies

You need Python 3.12, Node.js 22.12+, MySQL 5.7.8+, and a private OSS bucket. Uploads and previews require OSS permissions, CORS, and the correct region. See [storage configuration](docs/en/storage-and-metadata.md).

```bash
git clone https://github.com/NiuXiangQian/yearly.git
cd yearly

# If nvm is installed, run nvm use to read .nvmrc
python3.12 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
(cd frontend && npm ci)

cp -n .env.test.example .env.test
chmod 600 .env.test
```

### 2. Configure the local environment

Edit `.env.test` with your database connection, Session secret, and OSS settings. The test database name must end in `_test`. Use an application account restricted to that database.

Generate a Session secret locally, save it in your configuration, and keep it out of Git:

```bash
.venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(48))'
```

Values such as `CHANGE_ME` and `your-private-bucket` in the example files are placeholders. Replace them before deployment. Database initialization examples are in the [deployment guide](docs/en/deployment.md).

### 3. Migrate and start

```bash
./scripts/manage.sh test migrate

# On first use, create an administrator and enter a password when prompted
./scripts/manage.sh test create-admin your-admin-name

./scripts/start-local.sh
```

Open [http://127.0.0.1:5173/](http://127.0.0.1:5173/). The startup script runs the API, frontend, and video preview worker together. Press `Ctrl+C` to stop them.

To start them separately, run each command in its own terminal:

```bash
./scripts/start-api.sh test --reload
(cd frontend && npm run dev -- --port 5173)
./scripts/manage.sh test generate-previews --watch
```

## iOS app

The iPhone app (iOS 16+) uses the same backend and family accounts as the web client. Deploy your family server first, then enter its full **HTTPS URL** in the app, for example `https://example.com/yearly/`. The certificate must be valid and the server reachable from your phone.

1. Install full Xcode and the iOS platform components on a Mac, then open `ios/Yearly.xcodeproj`.
2. Select your Apple Team in Signing & Capabilities, connect the iPhone, and enable Developer Mode when prompted.
3. Select the device and run from Xcode. A free Personal Team supports installation with a 7-day signing period; renew by installing over the existing app with the same Team and Bundle Identifier.

```bash
# From the repository root: local logic and project checks
./scripts/ios.sh verify

# Full Xcode: Debug / Release simulator builds
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/ios.sh build
```

The repository provides source and self-build installation instructions; no App Store or TestFlight download is offered. Uploads pause in the background and can resume in the foreground or after reopening. See the [iOS guide](ios/README.md) for installation, re-signing, behavior, and device-validation limits.

## Android app

A native client for Android 8.0+ is also included. Open `android/` in Android Studio or run `./scripts/android.sh release` to build a personal installation APK, then connect to the same HTTPS family server. See the [Android guide](android/README.md) for builds, installation, and compatibility.

## Environments and deployment

| Setting | Local testing | Production |
| --- | --- | --- |
| Environment | `APP_ENV=test` | `APP_ENV=production` |
| Configuration | `.env.test` | `.env.production` |
| Database | Name ends in `_test` | Separate database; name must not end in `_test` |
| Access | Local HTTP | HTTPS and Secure cookies |
| Database account, secrets, OSS settings | Configured independently | Configured independently |

Use Alembic to create the schema for a new deployment. Back up an existing deployment before running migrations. The account and audit migration revision is `0013`. Production requires both the API and the video preview worker, together with Nginx, private OSS, and backup jobs.

Follow the [deployment guide](docs/en/deployment.md). This repository contains the application and deployment templates, not working server, database, or OSS credentials.

## Development and verification

```bash
# Frontend tests and build
(cd frontend && npm test && npm run build)

# Full backend/frontend checks: configure and migrate a separate test MySQL first
./scripts/test.sh
```

Backend tests use MySQL with transaction rollback. OSS operations are mocked, with separate signing and synthetic-media tests. Stop services connected to the same test database before running database tests to avoid concurrent writes.

See [verification notes](docs/en/verification.md) for coverage and remaining acceptance checks.

## Data boundaries and privacy

- Members can upload and edit their own files, folders, profiles, and journals. Other content is locked for editing. Administrators manage accounts and all content. Changes record the actor and field history transactionally. Legacy folders and profiles without a known creator are managed by administrators. Existing read-only guests remain read-only.
- The application preserves the bytes selected in the browser. Phone photo pickers may convert formats or omit Live Photo resources; check how originals are exported before importing.
- Original capture times and manual corrections are stored separately. Missing times, time zones, or GPS data are not fabricated.
- Deleted media and journals enter the recycle bin. Deleting a folder only removes its classification. Originals are never automatically permanently deleted.
- Restore backups during a maintenance window with writes stopped. Keep more than one storage copy of irreplaceable family originals.
- Do not upload `.env` files, passwords, private keys, certificates, database dumps, original family photos, or logs containing personal information to the repository or issues. Use fictional data for public screenshots and check image EXIF metadata before sharing.

## Documentation

| Document | Contents |
| --- | --- |
| [iOS app](ios/README.md) | Native features, Xcode installation, free re-signing, and verification scope |
| [Android app](android/README.md) | Native features, APK builds, installation, and compatibility |
| [People & pets](docs/en/pets.md) | Relationships, pet categories, file tagging, and filtering |
| [Deployment](docs/en/deployment.md) | MySQL, HTTPS, Nginx, systemd, and the video preview worker |
| [Storage and metadata](docs/en/storage-and-metadata.md) | OSS, direct uploads, compressed previews, capture times, and organization rules |
| [Backup and restore](docs/en/backup-restore.md) | Database, manifests, original-file backups, and restoration |
| [Verification](docs/en/verification.md) | Verified scope, test commands, and compatibility limitations |

Deployment templates are in [`deploy/`](deploy/); management commands are in [`scripts/`](scripts/).
