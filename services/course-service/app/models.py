from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import Boolean, DateTime, Float, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from .database import Base


class Course(Base):
    __tablename__ = "courses"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    slug: Mapped[str] = mapped_column(String(120), unique=True, index=True)
    title: Mapped[str] = mapped_column(String(200), index=True)
    description: Mapped[str] = mapped_column(Text)
    instructor: Mapped[str] = mapped_column(String(120))
    duration_hours: Mapped[float] = mapped_column(Float)
    published: Mapped[bool] = mapped_column(Boolean, default=True, index=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(UTC),
        onupdate=lambda: datetime.now(UTC),
    )

