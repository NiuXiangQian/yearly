# Children & pets

[简体中文](../pets.md) | **English** · [Home](../../README.en.md)

Choose **Add child** or **Add pet** on the Children & pets page. Pet profiles support names, nicknames, individual avatars, species, breed, gender, descriptions, colors, display order, and archiving.

A pet's birthday is optional. Once supplied, photo and journal ages are calculated from capture dates, and age-stage browsing and birthday navigation become available. Profiles with unknown birthdays omit ages and disable age filtering. Child profiles still require a birthday.

## Shared memories

- Select children and pets together when uploading. Link existing photos or videos to pets through media details or bulk linking.
- Journals can link both children and pets. The same record appears when browsing either profile.
- Choose **Any selected profile** or **All selected profiles** for combined filters. Shared photos retain a single original and appear only once in the combined timeline.
- Deleting a pet profile removes only its links. Child links, shared journals, and original files remain. Only administrators can delete profiles.

## Data and upgrades

Alembic `0009` adds `profile_type`, `species`, and `breed` to the existing `child` table and allows a missing birthday for pets. Existing profiles default to children. To preserve compatibility, `/api/children`, `child_ids`, and relationship table names remain unchanged and can now refer to either children or pets. `/api/stats` reports `children` and `pets` separately.

Run migrations for each environment you intend to upgrade before starting the new backend:

```bash
./scripts/manage.sh test migrate
./scripts/manage.sh production migrate
```

Portable backups preserve pet details and relationships. Older manifests without a profile type restore profiles as children. Downgrading removes pet-specific fields; null birthdays prevent a direct schema downgrade. Back up and resolve those profiles before reverting.

Sharing still uses date ranges and content permissions. Adding pets does not broaden access, and public responses do not return child or pet profiles. Review visible media, user-written titles, and journal text before sharing.
