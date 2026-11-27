"""Allow one share to cover multiple profiles and preserve existing links."""

from alembic import op
import sqlalchemy as sa

revision = "0027"
down_revision = "0026"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "timeline_share_profile",
        sa.Column("share_id", sa.BigInteger(), nullable=False),
        sa.Column("profile_id", sa.BigInteger(), nullable=False),
        sa.PrimaryKeyConstraint("share_id", "profile_id"),
        sa.ForeignKeyConstraint(["share_id"], ["timeline_share.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["profile_id"], ["child.id"]),
    )
    op.execute("""
        INSERT INTO timeline_share_profile (share_id, profile_id)
        SELECT id, profile_id FROM timeline_share WHERE profile_id IS NOT NULL
    """)
    op.execute("ALTER TABLE timeline_share DROP FOREIGN KEY fk_share_profile, DROP COLUMN profile_id")


def downgrade():
    op.add_column("timeline_share", sa.Column("profile_id", sa.BigInteger(), nullable=True))
    op.create_foreign_key("fk_share_profile", "timeline_share", "child", ["profile_id"], ["id"])
    op.execute("""
        UPDATE timeline_share AS target
        JOIN (
            SELECT share_id, MIN(profile_id) AS profile_id, COUNT(*) AS total
            FROM timeline_share_profile GROUP BY share_id
        ) AS scope ON scope.share_id = target.id
        SET target.profile_id = scope.profile_id, target.revoked = target.revoked OR scope.total > 1
    """)
    op.drop_table("timeline_share_profile")
