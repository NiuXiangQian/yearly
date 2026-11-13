"""Add isolated face samples without changing released media contracts."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME

revision = "0020"
down_revision = "0019"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("media_face_index",
        sa.Column("media_id", sa.BigInteger(), sa.ForeignKey("media.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("model", sa.String(64), nullable=False),
        sa.Column("source_sha256", sa.String(64), nullable=False),
        sa.Column("managed_child_ids", sa.JSON(), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB", mysql_charset="utf8mb4")
    op.create_table("media_face",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("media_id", sa.BigInteger(), sa.ForeignKey("media_face_index.media_id", ondelete="CASCADE"), nullable=False),
        sa.Column("box", sa.JSON(), nullable=False),
        sa.Column("frame_seconds", sa.Numeric(10, 3)),
        sa.Column("embedding", sa.JSON(), nullable=False),
        sa.Column("thumbnail", sa.Text(), nullable=False),
        sa.Column("child_id", sa.BigInteger(), sa.ForeignKey("child.id")),
        sa.Column("ignored", sa.Boolean(), nullable=False),
        sa.Column("confirmed_by", sa.BigInteger(), sa.ForeignKey("sys_user.id")),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB", mysql_charset="utf8mb4")
    op.create_index("ix_media_face_media_id", "media_face", ["media_id"])
    op.create_index("ix_media_face_child_id", "media_face", ["child_id"])


def downgrade():
    op.drop_table("media_face")
    op.drop_table("media_face_index")
