from __future__ import annotations

import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Annotated

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request, status
from opentelemetry import trace
from opentelemetry.trace import SpanKind
from prometheus_client import Counter
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from shared.broker import ENROLLMENT_ROUTING_KEY, EventPublisher
from shared.observability import setup_observability
from shared.security import AuthenticatedUser, require_user

from .database import engine, get_session, init_db
from .models import Enrollment
from .schemas import EnrollmentCreate, EnrollmentResponse, ProgressUpdate


logger = logging.getLogger("enrollment-service")
tracer = trace.get_tracer("enrollment-service.messaging")
events_published = Counter(
    "lms_events_published_total",
    "Number of domain events published",
    ("service", "event_type"),
)

COURSE_SERVICE_URL = os.getenv("COURSE_SERVICE_URL", "http://localhost:8002")
RABBITMQ_URL = os.getenv(
    "RABBITMQ_URL", "amqp://lms:lms_password@localhost:5672/"
)
publisher = EventPublisher(RABBITMQ_URL)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    await publisher.connect()
    app.state.http_client = httpx.AsyncClient(timeout=5.0)
    logger.info("service_started")
    yield
    await app.state.http_client.aclose()
    await publisher.close()
    await engine.dispose()


app = FastAPI(
    title="LMS Enrollment Service",
    version="0.1.0",
    lifespan=lifespan,
)
setup_observability(app, "enrollment-service")


@app.get("/health", tags=["system"])
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "enrollment-service"}


@app.get("/ready", tags=["system"])
async def ready(session: Annotated[AsyncSession, Depends(get_session)]) -> dict[str, str]:
    await session.execute(text("SELECT 1"))
    if publisher.connection is None or publisher.connection.is_closed:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="RabbitMQ connection is not ready",
        )
    return {"status": "ready"}


async def fetch_course(request: Request, course_id: int) -> dict:
    authorization = request.headers.get("authorization", "")
    try:
        response = await request.app.state.http_client.get(
            f"{COURSE_SERVICE_URL}/api/v1/courses/{course_id}",
            headers={"Authorization": authorization},
        )
    except httpx.RequestError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Course service is unavailable",
        ) from exc
    if response.status_code == status.HTTP_404_NOT_FOUND:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Course not found")
    if response.status_code != status.HTTP_200_OK:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Course service returned an unexpected response",
        )
    return response.json()


@app.get(
    "/api/v1/enrollments",
    response_model=list[EnrollmentResponse],
    tags=["enrollments"],
)
async def list_my_enrollments(
    current_user: Annotated[AuthenticatedUser, Depends(require_user)],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> list[Enrollment]:
    enrollments = (
        await session.scalars(
            select(Enrollment)
            .where(Enrollment.user_id == current_user.id)
            .order_by(Enrollment.enrolled_at.desc())
        )
    ).all()
    return list(enrollments)


@app.post(
    "/api/v1/enrollments",
    response_model=EnrollmentResponse,
    status_code=status.HTTP_201_CREATED,
    tags=["enrollments"],
)
async def enroll(
    payload: EnrollmentCreate,
    request: Request,
    current_user: Annotated[AuthenticatedUser, Depends(require_user)],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Enrollment:
    course = await fetch_course(request, payload.course_id)
    enrollment = Enrollment(
        user_id=current_user.id,
        username=current_user.username,
        course_id=course["id"],
        course_title=course["title"],
    )
    session.add(enrollment)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="User is already enrolled in this course",
        ) from exc
    await session.refresh(enrollment)

    event = {
        "event_id": str(uuid.uuid4()),
        "event_type": ENROLLMENT_ROUTING_KEY,
        "occurred_at": datetime.now(UTC).isoformat(),
        "enrollment_id": enrollment.id,
        "user_id": current_user.id,
        "username": current_user.username,
        "course_id": enrollment.course_id,
        "course_title": enrollment.course_title,
    }
    try:
        with tracer.start_as_current_span(
            "rabbitmq publish enrollment.created", kind=SpanKind.PRODUCER
        ) as span:
            span.set_attribute("messaging.system", "rabbitmq")
            span.set_attribute("messaging.destination.name", "lms.events")
            span.set_attribute("messaging.message.id", event["event_id"])
            await publisher.publish(ENROLLMENT_ROUTING_KEY, event)
        events_published.labels(
            service="enrollment-service", event_type=ENROLLMENT_ROUTING_KEY
        ).inc()
    except Exception:
        logger.exception(
            "enrollment_event_publish_failed",
            extra={"enrollment_id": enrollment.id},
        )

    logger.info(
        "student_enrolled",
        extra={
            "enrollment_id": enrollment.id,
            "user_id": current_user.id,
            "course_id": enrollment.course_id,
        },
    )
    return enrollment


@app.patch(
    "/api/v1/enrollments/{enrollment_id}/progress",
    response_model=EnrollmentResponse,
    tags=["enrollments"],
)
async def update_progress(
    enrollment_id: str,
    payload: ProgressUpdate,
    current_user: Annotated[AuthenticatedUser, Depends(require_user)],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Enrollment:
    enrollment = await session.get(Enrollment, enrollment_id)
    if enrollment is None or enrollment.user_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Enrollment not found"
        )
    enrollment.progress_percent = payload.progress_percent
    enrollment.status = "completed" if payload.progress_percent == 100 else "active"
    enrollment.updated_at = datetime.now(UTC)
    await session.commit()
    await session.refresh(enrollment)
    return enrollment

