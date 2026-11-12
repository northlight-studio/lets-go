"""batches: photos, follows, notes, payments, pickup codes

Revision ID: 0008
Revises: 0007
"""

import sqlalchemy as sa

from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "photos",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("owner_id", sa.UUID(), nullable=False),
        sa.Column("content_type", sa.String(length=32), nullable=False),
        sa.Column("data", sa.LargeBinary(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["owner_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "follows",
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("kitchen_id", sa.UUID(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["kitchen_id"], ["kitchens.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("user_id", "kitchen_id"),
    )
    op.create_index(op.f("ix_follows_kitchen_id"), "follows", ["kitchen_id"], unique=False)
    op.create_table(
        "notes",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("kitchen_id", sa.UUID(), nullable=False),
        sa.Column("drop_id", sa.UUID(), nullable=True),
        sa.Column("read_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["drop_id"], ["drops.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["kitchen_id"], ["kitchens.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_notes_user_id"), "notes", ["user_id"], unique=False)
    op.add_column("drops", sa.Column("menu_item_id", sa.UUID(), nullable=True))
    op.add_column("drops", sa.Column("title", sa.String(length=80), server_default="", nullable=False))
    op.add_column("drops", sa.Column("unit", sa.String(length=20), server_default="", nullable=False))
    op.add_column(
        "drops", sa.Column("tags", sa.ARRAY(sa.String(length=30)), server_default="{}", nullable=False)
    )
    op.add_column("drops", sa.Column("pickup_spot", sa.String(length=8), server_default="", nullable=False))
    op.add_column("drops", sa.Column("photo_id", sa.UUID(), nullable=True))
    op.create_foreign_key("drops_menu_item_id_fkey", "drops", "menu_items", ["menu_item_id"], ["id"])
    op.create_foreign_key("drops_photo_id_fkey", "drops", "photos", ["photo_id"], ["id"], ondelete="SET NULL")
    op.add_column("kitchens", sa.Column("address", sa.String(length=200), server_default="", nullable=False))
    op.add_column("kitchens", sa.Column("stripe_account_id", sa.String(length=64), nullable=True))
    op.add_column(
        "kitchens", sa.Column("payouts_ready", sa.Boolean(), server_default="false", nullable=False)
    )
    op.add_column(
        "orders", sa.Column("payment", sa.String(length=12), server_default="at_pickup", nullable=False)
    )
    op.add_column("orders", sa.Column("payment_intent_id", sa.String(length=64), nullable=True))
    op.add_column("orders", sa.Column("paid_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("orders", sa.Column("pickup_code", sa.String(length=3), server_default="", nullable=False))
    op.add_column("orders", sa.Column("picked_up_at", sa.DateTime(timezone=True), nullable=True))
    op.create_unique_constraint("orders_payment_intent_id_key", "orders", ["payment_intent_id"])


def downgrade() -> None:
    op.drop_constraint("orders_payment_intent_id_key", "orders", type_="unique")
    op.drop_column("orders", "picked_up_at")
    op.drop_column("orders", "pickup_code")
    op.drop_column("orders", "paid_at")
    op.drop_column("orders", "payment_intent_id")
    op.drop_column("orders", "payment")
    op.drop_column("kitchens", "payouts_ready")
    op.drop_column("kitchens", "stripe_account_id")
    op.drop_column("kitchens", "address")
    op.drop_constraint("drops_photo_id_fkey", "drops", type_="foreignkey")
    op.drop_constraint("drops_menu_item_id_fkey", "drops", type_="foreignkey")
    op.drop_column("drops", "photo_id")
    op.drop_column("drops", "pickup_spot")
    op.drop_column("drops", "tags")
    op.drop_column("drops", "unit")
    op.drop_column("drops", "title")
    op.drop_column("drops", "menu_item_id")
    op.drop_index(op.f("ix_notes_user_id"), table_name="notes")
    op.drop_table("notes")
    op.drop_index(op.f("ix_follows_kitchen_id"), table_name="follows")
    op.drop_table("follows")
    op.drop_table("photos")
