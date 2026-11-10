"""Content ownership, last modifier and transactional modification history."""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME

revision = "0013"
down_revision = "0012"
branch_labels = None
depends_on = None

TABLES = (
    "sys_user",
    "child",
    "timeline_folder",
    "media",
    "timeline_event",
    "timeline_day",
    "timeline_share",
)


def upgrade():
    op.add_column(
        "timeline_share", sa.Column("owner_scope_id", sa.BigInteger(), nullable=True)
    )
    op.create_foreign_key(
        "fk_timeline_share_scope_owner",
        "timeline_share",
        "sys_user",
        ["owner_scope_id"],
        ["id"],
    )
    op.execute(
        "UPDATE timeline_share s JOIN sys_user u ON s.created_by = u.id SET s.owner_scope_id = s.created_by WHERE u.role != 'admin'"
    )
    for table in TABLES:
        op.add_column(table, sa.Column("updated_by", sa.BigInteger(), nullable=True))
        op.create_foreign_key(
            f"fk_{table}_modifier", table, "sys_user", ["updated_by"], ["id"]
        )
    for table in ("child", "timeline_folder"):
        op.add_column(table, sa.Column("owner_id", sa.BigInteger(), nullable=True))
        op.create_foreign_key(
            f"fk_{table}_owner", table, "sys_user", ["owner_id"], ["id"]
        )
    for table in ("timeline_day", "timeline_share"):
        op.add_column(
            table,
            sa.Column(
                "updated_at",
                DATETIME(fsp=3),
                nullable=False,
                server_default=sa.text("CURRENT_TIMESTAMP(3)"),
            ),
        )
    op.create_table(
        "audit_log",
        sa.Column("id", sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column(
            "actor_id", sa.BigInteger(), sa.ForeignKey("sys_user.id"), nullable=False
        ),
        sa.Column("actor_name", sa.String(80), nullable=False),
        sa.Column("resource_type", sa.String(80), nullable=False),
        sa.Column("resource_id", sa.String(80), nullable=False),
        sa.Column("action", sa.String(24), nullable=False),
        sa.Column("changes", sa.JSON(), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB",
        mysql_charset="utf8mb4",
        mysql_collate="utf8mb4_unicode_ci",
    )
    for column in ("actor_id", "resource_type", "resource_id", "created_at"):
        op.create_index(f"ix_audit_log_{column}", "audit_log", [column])


def downgrade():
    op.drop_constraint(
        "fk_timeline_share_scope_owner", "timeline_share", type_="foreignkey"
    )
    op.drop_column("timeline_share", "owner_scope_id")
    op.drop_table("audit_log")
    for table in ("timeline_day", "timeline_share"):
        op.drop_column(table, "updated_at")
    for table in ("child", "timeline_folder"):
        op.drop_constraint(f"fk_{table}_owner", table, type_="foreignkey")
        op.drop_column(table, "owner_id")
    for table in reversed(TABLES):
        op.drop_constraint(f"fk_{table}_modifier", table, type_="foreignkey")
        op.drop_column(table, "updated_by")
