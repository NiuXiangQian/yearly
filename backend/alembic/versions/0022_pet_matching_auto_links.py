"""Isolate pet detections and distinguish automatic links from reference samples."""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME

revision = "0022"
down_revision = "0021"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("media_face", sa.Column("auto_match_score", sa.Numeric(7, 4)))
    op.add_column("media_face", sa.Column("auto_reference_face_id", sa.BigInteger()))
    op.add_column(
        "media_face",
        sa.Column(
            "auto_link_blocked", sa.Boolean(), nullable=False, server_default="0"
        ),
    )
    op.create_table(
        "media_pet_index",
        sa.Column(
            "media_id",
            sa.BigInteger(),
            sa.ForeignKey("media.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("source_sha256", sa.String(64), nullable=False),
        sa.Column("model", sa.String(64), nullable=False),
        sa.Column("detections", sa.JSON(), nullable=False),
        sa.Column("managed_child_ids", sa.JSON(), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB",
        mysql_charset="utf8mb4",
    )


def downgrade():
    op.drop_table("media_pet_index")
    for name in ["auto_link_blocked", "auto_reference_face_id", "auto_match_score"]:
        op.drop_column("media_face", name)
