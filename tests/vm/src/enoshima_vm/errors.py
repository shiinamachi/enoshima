from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class FailureCategory(StrEnum):
    IMAGE_ERROR = "IMAGE_ERROR"
    VM_BOOT_ERROR = "VM_BOOT_ERROR"
    GUEST_AGENT_TIMEOUT = "GUEST_AGENT_TIMEOUT"
    SSH_TIMEOUT = "SSH_TIMEOUT"
    VALIDATION_FAILED = "VALIDATION_FAILED"
    BOOTSTRAP_FAILED = "BOOTSTRAP_FAILED"
    POSTFLIGHT_FAILED = "POSTFLIGHT_FAILED"
    IDEMPOTENCY_FAILED = "IDEMPOTENCY_FAILED"
    REBOOT_FAILED = "REBOOT_FAILED"
    DESKTOP_SESSION_FAILED = "DESKTOP_SESSION_FAILED"
    LOGIN_SESSION_FAILED = "LOGIN_SESSION_FAILED"
    VISUAL_ASSERTION_FAILED = "VISUAL_ASSERTION_FAILED"
    SECURE_BOOT_FAILED = "SECURE_BOOT_FAILED"
    UNMAPPED_RUNTIME_PATH = "UNMAPPED_RUNTIME_PATH"
    VM_BLOCKED = "VM_BLOCKED"
    HOST_INFRA_ERROR = "HOST_INFRA_ERROR"
    SOURCE_INVALIDATED = "SOURCE_INVALIDATED"
    HARNESS_ERROR = "HARNESS_ERROR"


@dataclass(slots=True)
class VMError(RuntimeError):
    category: FailureCategory
    message: str
    details: dict[str, object] | None = None

    def __str__(self) -> str:
        return f"{self.category}: {self.message}"
