"""Independent, reversible media curation and image-quality cache."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME
revision = "0025"
down_revision = "0024"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("media_curation",
        sa.Column("media_id", sa.BigInteger(), sa.ForeignKey("media.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("disposition", sa.String(16), nullable=False),
        sa.Column("fingerprint", sa.String(64)), sa.Column("quality", sa.JSON(none_as_null=True)),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False), sa.Column("updated_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB", mysql_charset="utf8mb4", mysql_collate="utf8mb4_unicode_ci")
    op.create_index("ix_media_curation_fingerprint", "media_curation", ["fingerprint"])
    op.create_table("curation_batch",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("actor_id", sa.BigInteger(), sa.ForeignKey("sys_user.id"), nullable=False),
        sa.Column("before", sa.JSON(), nullable=False), sa.Column("after", sa.JSON(), nullable=False),
        sa.Column("undone", sa.Boolean(), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False), sa.Column("updated_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB", mysql_charset="utf8mb4", mysql_collate="utf8mb4_unicode_ci")


def downgrade():
    op.drop_table("curation_batch")
    op.drop_table("media_curation")
