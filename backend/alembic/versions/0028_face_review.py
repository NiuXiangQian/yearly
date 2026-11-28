"""Keep video track evidence, rejection decisions and durable matching work."""
from alembic import op
import sqlalchemy as sa

revision = "0028"
down_revision = "0027"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("media_face", sa.Column("alternate_embeddings", sa.JSON()))
    op.add_column("media_face", sa.Column("rejected_child_ids", sa.JSON()))
    op.add_column("media_face_index", sa.Column("match_pending", sa.Boolean(), nullable=False, server_default="0"))
    op.add_column("media_face_index", sa.Column("reference_cursor", sa.BigInteger()))
    op.create_index("ix_media_face_index_match_pending", "media_face_index", ["match_pending"])


def downgrade():
    op.drop_index("ix_media_face_index_match_pending", table_name="media_face_index")
    op.drop_column("media_face_index", "reference_cursor")
    op.drop_column("media_face_index", "match_pending")
    op.drop_column("media_face", "rejected_child_ids")
    op.drop_column("media_face", "alternate_embeddings")
