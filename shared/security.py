from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta
from typing import Annotated, Callable

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from pwdlib import PasswordHash


ALGORITHM = "HS256"
_DEV_SECRET = "development-only-secret-change-before-deploying"
_bearer = HTTPBearer(auto_error=False)
_password_hash = PasswordHash.recommended()


class AuthenticatedUser(BaseModel):
    id: str
    username: str
    role: str


def hash_password(password: str) -> str:
    return _password_hash.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    return _password_hash.verify(password, password_hash)


def create_access_token(
    *, user_id: str, username: str, role: str, expires_minutes: int = 60
) -> str:
    now = datetime.now(UTC)
    payload = {
        "sub": user_id,
        "username": username,
        "role": role,
        "iat": now,
        "exp": now + timedelta(minutes=expires_minutes),
    }
    secret = os.getenv("JWT_SECRET", _DEV_SECRET)
    return jwt.encode(payload, secret, algorithm=ALGORITHM)


def decode_access_token(token: str) -> AuthenticatedUser:
    secret = os.getenv("JWT_SECRET", _DEV_SECRET)
    try:
        payload = jwt.decode(token, secret, algorithms=[ALGORITHM])
        return AuthenticatedUser(
            id=payload["sub"],
            username=payload["username"],
            role=payload["role"],
        )
    except (jwt.PyJWTError, KeyError, ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired access token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc


async def require_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> AuthenticatedUser:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return decode_access_token(credentials.credentials)


def require_roles(*roles: str) -> Callable[..., AuthenticatedUser]:
    async def dependency(
        user: Annotated[AuthenticatedUser, Depends(require_user)],
    ) -> AuthenticatedUser:
        if user.role not in roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Required role: {', '.join(roles)}",
            )
        return user

    return dependency

