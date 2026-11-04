# Expiring timeline shares

[简体中文](../sharing.md) | **English** · [Home](../../README.en.md)

Set **Allow sharing** during normal content editing. Creating a link only requires a timeline date range and a lifetime.

- **File:** open its details, change **Allow sharing** in the existing edit form, and save.
- **Folder:** open it, choose **Edit folder**, change **Allow sharing**, and save. Disabling a folder hides all its contents too.
- **Timeline day:** toggle **Allow sharing this day** in the date action bar. It saves immediately and controls all files, folders, and diaries on that day.
- **Diary:** change **Allow sharing** in its editor and save.

Sharing is allowed by default. These persistent settings apply to **all existing and new links**. A file is hidden if its parent folder or day disallows sharing, even when the file itself allows it. Enabling this option does not publish a link. Normal family browsing, editing, and original downloads remain available.

Click **Share timeline**:

1. Choose inclusive start and end archive dates. Main-page child, search, and media-type filters do not scope the share.
2. Choose **1–168 hours (up to 7 days)** from successful creation.
3. Create, copy, or preview the link. There is no file picker: the server automatically filters content using its saved permissions. Save the full link before closing the dialog.
4. Revoke links under **Manage recent shares**. Members manage their own links; admins manage all links. The list shows the latest 100. Viewers cannot create or modify sharing settings.

Shares update with the timeline and saved permissions, including new content allowed for sharing. To change a link's date range, revoke it and create a new link.

Recipients need no account and read a separate, read-only timeline. Each day initially shows eight entries, with more available on demand. Folders and media retain their mixed order. Readers can open folders and diaries, zoom images, and play compressed videos and Live Photos. Undated files are outside date-range shares. The signed-in mobile timeline also folds entries beyond eight per day; selection and sorting modes show all entries for editing.

## Preview

These 2× lossless PNGs use fictional data only. The creation dialog only asks for dates and lifetime; file permissions belong in their editors. The interface also supports English.

![Fictional example: date-only sharing dialog](../images/demo-share-create.png)

![Fictional example: read-only shared timeline](../images/demo-share.png)

## Privacy and bandwidth

- Anyone with a link can read it. Share only with trusted recipients. This does not prevent screenshots or saving visible content.
- Public lists, folder thumbnails, counts, and media URLs enforce scope, content permissions, expiry, revocation, and creator permissions on the server.
- Only compressed thumbnails and previews are served. There is no original-download entry point. Unavailable video previews ask readers to retry; they never fall back to originals.
- Regular list payloads omit accounts, child profiles, original filenames, GPS, EXIF, and storage details. OSS previews use short-lived signed URLs; recipients can see the domain and object path, with the signature limited to that preview.
- **Custom titles and diary text are shared content.** Review private writing before sharing. Diaries do not expose original media associations or covers that could reveal excluded files.
- Expiry and revocation block new API access immediately. Previously issued preview URLs remain valid for at most 60 seconds, never beyond the share's remaining lifetime. Loaded or saved content cannot be recalled.
- The database stores only SHA-256 digests of random link tokens. Portable backups omit share links. Deactivating a creator or removing their editing role also disables their links.
- The frontend suppresses Referrer headers and requests no search indexing. The sample Nginx access log redacts share tokens; API access logging is disabled. Treat other proxy, monitoring, and error logs as sensitive.

## Migration

Alembic revision `0008` adds `share_allowed` to media, folders, and diaries, and stores day permissions in `timeline_day`. It removes per-link file selections and revokes old links with nonempty exclusions so their scope cannot silently expand. Portable backups retain these permissions and remain compatible with older backups. Manual initialization SQL is updated too. Migrate test and production separately:

```bash
./scripts/manage.sh test migrate
# Back up production first; run during deployment:
./scripts/manage.sh production migrate
```

Deploy the backend, frontend build, and Nginx changes together. A link pointing to your own localhost is not reachable by external recipients; use a publicly reachable HTTPS deployment domain for real sharing.
