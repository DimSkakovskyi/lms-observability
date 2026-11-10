from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class CourseCreate(BaseModel):
    slug: str = Field(min_length=3, max_length=120, pattern=r"^[a-z0-9-]+$")
    title: str = Field(min_length=3, max_length=200)
    description: str = Field(min_length=10, max_length=5000)
    instructor: str = Field(min_length=2, max_length=120)
    duration_hours: float = Field(gt=0, le=1000)
    published: bool = True


class CourseUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=3, max_length=200)
    description: str | None = Field(default=None, min_length=10, max_length=5000)
    instructor: str | None = Field(default=None, min_length=2, max_length=120)
    duration_hours: float | None = Field(default=None, gt=0, le=1000)
    published: bool | None = None


class CourseResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    slug: str
    title: str
    description: str
    instructor: str
    duration_hours: float
    published: bool
    created_at: datetime
    updated_at: datetime


class CourseListResponse(BaseModel):
    items: list[CourseResponse]
    total: int

