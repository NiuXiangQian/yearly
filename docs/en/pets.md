# People & pets

[简体中文](../pets.md) | **English** · [Home](../../README.en.md)

Choose **Add person** or **Add pet** on the People & pets page. People can be parents, grandparents, children, friends, or anyone else in your family story. Choose a suggested relationship or enter a custom one. Each profile supports an avatar, nickname, description, color, display order, and archiving.

These profiles tag memories; they do not create login accounts or change account permissions.

Profiles have an **Enable growth timeline** setting. Children and pets default to on; parents, grandparents, and other people default to off. Choosing the child relationship for a new person enables it by default, but subsequent relationship changes preserve a manual choice.

When off, the profile links to **View related memories**. Photos, videos, journals, and any/all profile filtering remain available, while age labels, age stages, birth-day shortcuts, and growth milestones are omitted. Birthdays and existing links are preserved; enabling growth again recalculates ages.

Birthdays remain optional. Age browsing and birthday navigation require both an enabled growth timeline and a birthday.

## Pet categories

Set a pet category and breed separately. Suggested categories include cats, dogs, rabbits, birds, fish, hamsters, and turtles; custom categories are also supported. Existing species values serve as categories without losing breed information.

Profile lists and file selectors can narrow candidates to people, pets, or an existing pet category. Pets without a category appear under **Pets · Uncategorized**. Search matches names, nicknames, relationships, categories, and breeds.

## Who is in each file?

- Use **Who is in this? (select multiple)** when uploading a batch or editing a file. A photo can include a child, parents, grandparents, and pets together.
- Existing files support bulk adding, removing, and replacing profile links. Journals support the same shared cast.
- **Select these profiles** in an editor adds the matching candidates while preserving existing selections. **Clear selection** removes all selections.
- Click profiles on the timeline to filter. Choose **Any selected profile** or **All selected profiles** for combined filters. After finding a category, **Filter by these profiles** switches to that group, such as all cats. Searching candidates alone does not change the selected timeline scope.
- Each shared photo, video, or journal appears in every linked profile’s timeline. Originals are stored once and records are not duplicated in combined views.
- Deleting a profile removes only its links; other profiles and originals remain. Only administrators can delete profiles.

## Data and upgrades

Alembic `0010` adds `relationship` to the existing `child` table. Existing child IDs, avatars, and links remain intact and receive the child relationship. New people use `profile_type=person`; pets remain `pet`, with categories stored in `species`. For compatibility, `/api/children`, `child_ids`, and existing relationship tables now refer to all people and pets. New person birthdays are optional; older clients omitting the type still use the original child validation rules.

`/api/stats` reports `people` and `pets`, while retaining `children` for compatibility. Backups preserve relationships, categories, and associations; older manifests without relationships remain supported.

Alembic `0011` adds `growth_enabled`. Existing children and pets retain growth; other people default to off. Backups preserve explicit choices, while older manifests use these defaults.

Run migrations for each environment you intend to upgrade before starting the backend:

```bash
./scripts/manage.sh test migrate
./scripts/manage.sh production migrate
```

Sharing continues to enforce date ranges and content permissions. Public responses omit relationships and private people/pet profiles and do not grant original-file access. Review visible media and user-written titles or journal text before sharing.
