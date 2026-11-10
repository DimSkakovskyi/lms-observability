from __future__ import annotations

import json
from typing import Any

import aio_pika
from aio_pika import DeliveryMode, ExchangeType, Message
from opentelemetry import propagate


EXCHANGE_NAME = "lms.events"
ENROLLMENT_QUEUE = "notification.enrollment-events"
ENROLLMENT_ROUTING_KEY = "enrollment.created"


async def declare_event_infrastructure(
    channel: aio_pika.abc.AbstractChannel,
) -> aio_pika.abc.AbstractQueue:
    exchange = await channel.declare_exchange(
        EXCHANGE_NAME, ExchangeType.TOPIC, durable=True
    )
    queue = await channel.declare_queue(ENROLLMENT_QUEUE, durable=True)
    await queue.bind(exchange, routing_key=ENROLLMENT_ROUTING_KEY)
    return queue


class EventPublisher:
    def __init__(self, url: str) -> None:
        self.url = url
        self.connection: aio_pika.abc.AbstractRobustConnection | None = None
        self.channel: aio_pika.abc.AbstractChannel | None = None
        self.exchange: aio_pika.abc.AbstractExchange | None = None

    async def connect(self) -> None:
        self.connection = await aio_pika.connect_robust(self.url)
        self.channel = await self.connection.channel(publisher_confirms=True)
        await declare_event_infrastructure(self.channel)
        self.exchange = await self.channel.get_exchange(EXCHANGE_NAME)

    async def publish(self, routing_key: str, payload: dict[str, Any]) -> None:
        if self.exchange is None:
            raise RuntimeError("Event publisher is not connected")
        headers: dict[str, str] = {}
        propagate.inject(headers)
        message = Message(
            body=json.dumps(payload, default=str).encode(),
            content_type="application/json",
            headers=headers,
            delivery_mode=DeliveryMode.PERSISTENT,
        )
        await self.exchange.publish(message, routing_key=routing_key)

    async def close(self) -> None:
        if self.connection is not None:
            await self.connection.close()
