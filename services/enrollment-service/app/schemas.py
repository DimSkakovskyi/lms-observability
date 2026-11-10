from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class EnrollmentCreate(BaseModel):
    course_id: int = Field(gt=0)


class ProgressUpdate(BaseModel):
    progress_percent: float = Field(ge=0, le=100)


class EnrollmentResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    username: str
    course_id: int
    course_title: str
    status: str
    progress_percent: float
    enrolled_at: datetime
    updated_at: datetime

