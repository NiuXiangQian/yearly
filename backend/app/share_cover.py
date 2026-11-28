from io import BytesIO
from math import ceil, sqrt

import oss2
from fastapi import HTTPException
from PIL import Image, ImageOps
from sqlalchemy import or_, select

from .models import DisplayPreview, Media, MediaFile, TimelineFolder
from .visibility import sharing_visibility


def share_avatar_ids(share):
    profiles = sorted(share.profiles, key=lambda profile: (profile.sort_order, profile.id))
    return [profile.avatar_media_id for profile in profiles if profile.avatar_media_id][:9]


def group_cover(db, storage, avatar_ids):
    folders = select(TimelineFolder.id).where(
        TimelineFolder.status == "active", sharing_visibility(TimelineFolder),
    )
    rows = db.execute(
        select(MediaFile, DisplayPreview)
        .join(Media, Media.id == MediaFile.media_id)
        .outerjoin(DisplayPreview, DisplayPreview.sha256 == MediaFile.sha256)
        .where(
            Media.id.in_(avatar_ids),
            Media.status == "active",
            Media.media_type == "photo",
            MediaFile.file_role == "original",
            MediaFile.upload_status == "complete",
            sharing_visibility(Media),
            or_(Media.folder_id.is_(None), Media.folder_id.in_(folders)),
        )
    )
    files = {file.media_id: (file, preview) for file, preview in rows}
    images = []
    for media_id in avatar_ids:
        if media_id not in files:
            continue
        try:
            data = storage.read_thumbnail(*files[media_id])
            with Image.open(BytesIO(data)) as image:
                if image.width * image.height <= 1024 * 1024:
                    images.append(ImageOps.exif_transpose(image).convert("RGBA"))
        except (HTTPException, oss2.exceptions.OssError, OSError, Image.DecompressionBombError):
            continue
    return compose_group_cover(images) if images else None


def compose_group_cover(images):
    size, margin, gap = 360, 12, 6
    count = len(images)
    columns = ceil(sqrt(count))
    complete_rows, remainder = divmod(count, columns)
    rows = ([remainder] if remainder else []) + [columns] * complete_rows
    tile = (size - 2 * margin - gap * (columns - 1)) // columns
    canvas = Image.new("RGB", (size, size), "#e8eaed")
    y = (size - len(rows) * tile - (len(rows) - 1) * gap) // 2
    index = 0
    for length in rows:
        x = (size - length * tile - (length - 1) * gap) // 2
        for _ in range(length):
            image = ImageOps.fit(images[index], (tile, tile), method=Image.Resampling.LANCZOS)
            canvas.paste(image, (x, y), image)
            index += 1
            x += tile + gap
        y += tile + gap
    output = BytesIO()
    canvas.save(output, format="PNG", optimize=True)
    return output.getvalue()
