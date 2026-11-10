from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, status
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from shared.observability import setup_observability
from shared.security import (
    AuthenticatedUser,
    create_access_token,
    hash_password,
    require_user,
    verify_password,
)

from .database import SessionLocal, engine, get_session, init_db
from .models import User
from .schemas import LoginRequest, RegisterRequest, TokenResponse, UserResponse


logger = logging.getLogger("auth-service")
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "60"))


async def ensure_admin_user() -> None:
    username = os.getenv("ADMIN_USERNAME", "admin")
    password = os.getenv("ADMIN_PASSWORD", "admin12345")
    async with SessionLocal() as session:
        existing = await session.scalar(select(User).where(User.username == username))
        if existing is None:
            session.add(
                User(
                    username=username,
                    password_hash=hash_password(password),
                    role="admin",
                )
            )
            await session.commit()
            logger.info("default_admin_created", extra={"username": username})


@asynccontextmanager
async def lifespan(_: FastAPI):
    await init_db()
    await ensure_admin_user()
    logger.info("service_started")
    yield
    await engine.dispose()


app = FastAPI(
    title="LMS Auth Service",
    version="0.1.0",
    lifespan=lifespan,
)
setup_observability(app, "auth-service")


@app.get("/health", tags=["system"])
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "auth-service"}


@app.get("/ready", tags=["system"])
async def ready(session: Annotated[AsyncSession, Depends(get_session)]) -> dict[str, str]:
    await session.execute(text("SELECT 1"))
    return {"status": "ready"}


@app.post(
    "/api/v1/auth/register",
    response_model=UserResponse,
    status_code=status.HTTP_201_CREATED,
    tags=["auth"],
)
async def register(
    payload: RegisterRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> User:
    user = User(
        username=payload.username,
        password_hash=hash_password(payload.password),
        role="student",
    )
    session.add(user)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Username is already registered",
        ) from exc
    await session.refresh(user)
    logger.info("user_registered", extra={"user_id": user.id, "username": user.username})
    return user


@app.post("/api/v1/auth/login", response_model=TokenResponse, tags=["auth"])
async def login(
    payload: LoginRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> TokenResponse:
    user = await session.scalar(select(User).where(User.username == payload.username))
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password",
        )
    token = create_access_token(
        user_id=user.id,
        username=user.username,
        role=user.role,
        expires_minutes=ACCESS_TOKEN_EXPIRE_MINUTES,
    )
    logger.info("user_logged_in", extra={"user_id": user.id, "username": user.username})
    return TokenResponse(
        access_token=token,
        expires_in=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
    )


@app.get("/api/v1/auth/me", response_model=UserResponse, tags=["auth"])
async def me(
    current_user: Annotated[AuthenticatedUser, Depends(require_user)],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> User:
    user = await session.get(User, current_user.id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return user

