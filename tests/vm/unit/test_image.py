from __future__ import annotations

from hashlib import sha256
from pathlib import Path

import pytest

from enoshima_vm.config import ImageDefinition, RuntimePaths
from enoshima_vm.errors import VMError
from enoshima_vm.image import ImageCache, file_sha256


def paths(tmp_path: Path) -> RuntimePaths:
    return RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")


def test_unsigned_fixture_can_be_checksum_verified(tmp_path: Path) -> None:
    source = tmp_path / "source.qcow2"
    source.write_bytes(b"fixture image")
    digest = sha256(source.read_bytes()).hexdigest()
    definition = ImageDefinition(
        name="fixture",
        url=source.as_uri(),
        sha256=digest,
        checksum_url=None,
        signature_url=None,
        signature_required=False,
        keyring="",
    )
    destination = ImageCache(paths(tmp_path)).ensure(definition)
    assert destination.read_bytes() == source.read_bytes()
    assert file_sha256(destination) == digest


def test_checksum_mismatch_never_populates_cache(tmp_path: Path) -> None:
    source = tmp_path / "source.qcow2"
    source.write_bytes(b"fixture image")
    definition = ImageDefinition(
        name="fixture",
        url=source.as_uri(),
        sha256="0" * 64,
        checksum_url=None,
        signature_url=None,
        signature_required=False,
        keyring="",
    )
    with pytest.raises(VMError, match="checksum mismatch"):
        ImageCache(paths(tmp_path)).ensure(definition)
    assert not list((tmp_path / "cache" / "images").glob("*.qcow2"))
