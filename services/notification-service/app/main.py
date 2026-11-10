from __future__ import annotations

import asyncio
import json
import logging
import os
from contextlib import asynccontextmanager

import aio_pika
from fastapi import FastAPI, HTTPException, status
from opentelemetry import propagate, trace
from opentelemetry.trace import SpanKind
from prometheus_client import Counter

from shared.broker import declare_event_infrastructure
from shared.observability import setup_observability


logger = logging.getLogger("notification-service")
tracer = trace.get_tracer("notification-service.messaging")
events_processed = Counter(
    "lms_notification_events_total",
    "Number of notification events processed",
    ("event_type", "result"),
)
RABBITMQ_URL = os.getenv(
    "RABBITMQ_URL", "amqp://lms:lms_password@localhost:5672/"
)


async def consume(app: FastAPI) -> None:
    connection = await aio_pika.connect_robust(RABBITMQ_URL)
    app.state.rabbit_connection = connection
    channel = await connection.channel()
    await channel.set_qos(prefetch_count=10)
    queue = await declare_event_infrastructure(channel)

    async def handle(message: aio_pika.IncomingMessage) -> None:
        async with message.process(requeue=False):
            carrier = {str(k): str(v) for k, v in (message.headers or {}).items()}
            context = propagate.extract(carrier)
            with tracer.start_as_current_span(
                "rabbitmq process enrollment.created",
                context=context,
                kind=SpanKind.CONSUMER,
            ) as span:
                try:
                    event = json.loads(message.body)
                    span.set_attribute("messaging.system", "rabbitmq")
                    span.set_attribute("messaging.destination.name", queue.name)
                    span.set_attribute("messaging.message.id", event.get("event_id", ""))
                    logger.info(
                        "notification_simulated",
                        extra={
                            "event_id": event.get("event_id"),
                            "username": event.get("username"),
                            "course_title": event.get("course_title"),
                            "notification": (
                                f"Вітаємо! Ви записалися на курс "
                                f"«{event.get('course_title')}»."
                            ),
                        },
                    )
                    events_processed.labels(
                        event_type=event.get("event_type", "unknown"), result="success"
                    ).inc()
                except Exception as exc:
                    events_processed.labels(event_type="unknown", result="error").inc()
                    span.record_exception(exc)
                    logger.exception("notification_processing_failed")
                    raise

    await queue.consume(handle)
    logger.info("rabbitmq_consumer_started", extra={"queue": queue.name})
    await asyncio.Future()


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.rabbit_connection = None
    app.state.consumer_task = asyncio.create_task(consume(app))
    logger.info("service_started")
    yield
    app.state.consumer_task.cancel()
    try:
        await app.state.consumer_task
    except asyncio.CancelledError:
        pass
    if app.state.rabbit_connection is not None:
        await app.state.rabbit_connection.close()


app = FastAPI(
    title="LMS Notification Service",
    version="0.1.0",
    lifespan=lifespan,
)
setup_observability(app, "notification-service")


@app.get("/health", tags=["system"])
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "notification-service"}


@app.get("/ready", tags=["system"])
async def ready() -> dict[str, str]:
    connection = app.state.rabbit_connection
    if connection is None or connection.is_closed:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="RabbitMQ connection is not ready",
        )
    return {"status": "ready"}

