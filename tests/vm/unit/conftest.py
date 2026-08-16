from __future__ import annotations

from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def isolate_service_mutation_lock(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Keep unit tests independent from a durable operation's production lock."""
    lock_path = tmp_path / "service-mutation.lock"
    monkeypatch.setattr(
        "enoshima_vm.config.global_mutation_lock_path", lambda: lock_path
    )
