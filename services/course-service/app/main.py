from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Query, Response, status
from sqlalchemy import func, or_, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from shared.observability import setup_observability
from shared.security import AuthenticatedUser, require_roles, require_user

from .database import SessionLocal, engine, get_session, init_db
from .models import Course
from .schemas import CourseCreate, CourseListResponse, CourseResponse, CourseUpdate


logger = logging.getLogger("course-service")

SEED_COURSES = [
    {
        "slug": "python-fundamentals",
        "title": "Python: основи програмування",
        "description": "Практичний вступ до Python, типів даних, функцій та модулів.",
        "instructor": "Олена Коваль",
        "duration_hours": 24,
    },
    {
        "slug": "microservices-fastapi",
        "title": "Мікросервіси з FastAPI",
        "description": "Побудова REST API, взаємодія сервісів і контейнеризація.",
        "instructor": "Андрій Мельник",
        "duration_hours": 18,
    },
    {
        "slug": "observability-stack",
        "title": "Observability: Prometheus, Loki та Tempo",
        "description": "Метрики, централізовані логи й розподілені трейси на практиці.",
        "instructor": "Ірина Бондар",
        "duration_hours": 16,
    },
    {
        "slug": "postgresql-for-developers",
        "title": "PostgreSQL для розробників",
        "description": "Схеми, запити, індекси, транзакції та оптимізація баз даних.",
        "instructor": "Максим Шевченко",
        "duration_hours": 20,
    },
]


async def seed_courses() -> None:
    async with SessionLocal() as session:
        existing = await session.scalar(select(func.count(Course.id)))
        if existing == 0:
            session.add_all([Course(**course) for course in SEED_COURSES])
            await session.commit()
            logger.info("courses_seeded", extra={"count": len(SEED_COURSES)})


@asynccontextmanager
async def lifespan(_: FastAPI):
    await init_db()
    await seed_courses()
    logger.info("service_started")
    yield
    await engine.dispose()


app = FastAPI(
    title="LMS Course Service",
    version="0.1.0",
    lifespan=lifespan,
)
setup_observability(app, "course-service")


@app.get("/health", tags=["system"])
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "course-service"}


@app.get("/ready", tags=["system"])
async def ready(session: Annotated[AsyncSession, Depends(get_session)]) -> dict[str, str]:
    await session.execute(text("SELECT 1"))
    return {"status": "ready"}


@app.get("/api/v1/courses", response_model=CourseListResponse, tags=["courses"])
async def list_courses(
    _: Annotated[AuthenticatedUser, Depends(require_user)],
    session: Annotated[AsyncSession, Depends(get_session)],
    search: Annotated[str | None, Query(max_length=100)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> CourseListResponse:
    filters = [Course.published.is_(True)]
    if search:
        pattern = f"%{search}%"
        filters.append(or_(Course.title.ilike(pattern), Course.description.ilike(pattern)))

    total = await session.scalar(select(func.count(Course.id)).where(*filters))
    courses = (
        await session.scalars(
            select(Course)
            .where(*filters)
            .order_by(Course.created_at.desc())
            .offset(offset)
            .limit(limit)
        )
    ).all()
    return CourseListResponse(items=list(courses), total=total or 0)


@app.get("/api/v1/courses/{course_id}", response_model=CourseResponse, tags=["courses"])
async def get_course(
    course_id: int,
    _: Annotated[AuthenticatedUser, Depends(require_user)],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Course:
    course = await session.get(Course, course_id)
    if course is None or not course.published:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Course not found")
    return course


@app.post(
    "/api/v1/courses",
    response_model=CourseResponse,
    status_code=status.HTTP_201_CREATED,
    tags=["courses"],
)
async def create_course(
    payload: CourseCreate,
    admin: Annotated[AuthenticatedUser, Depends(require_roles("admin"))],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Course:
    course = Course(**payload.model_dump())
    session.add(course)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Course slug already exists",
        ) from exc
    await session.refresh(course)
    logger.info(
        "course_created", extra={"course_id": course.id, "actor_id": admin.id}
    )
    return course


@app.patch("/api/v1/courses/{course_id}", response_model=CourseResponse, tags=["courses"])
async def update_course(
    course_id: int,
    payload: CourseUpdate,
    admin: Annotated[AuthenticatedUser, Depends(require_roles("admin"))],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Course:
    course = await session.get(Course, course_id)
    if course is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Course not found")
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(course, field, value)
    course.updated_at = datetime.now(UTC)
    await session.commit()
    await session.refresh(course)
    logger.info(
        "course_updated", extra={"course_id": course.id, "actor_id": admin.id}
    )
    return course


@app.delete(
    "/api/v1/courses/{course_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    tags=["courses"],
)
async def delete_course(
    course_id: int,
    admin: Annotated[AuthenticatedUser, Depends(require_roles("admin"))],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Response:
    course = await session.get(Course, course_id)
    if course is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Course not found")
    await session.delete(course)
    await session.commit()
    logger.info(
        "course_deleted", extra={"course_id": course_id, "actor_id": admin.id}
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)

