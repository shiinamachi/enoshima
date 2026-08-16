from __future__ import annotations

import io
import urllib.error
from hashlib import sha256
from pathlib import Path

import pytest

from enoshima_vm.config import ImageDefinition, RuntimePaths
from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.image import NETWORK_FETCH_ATTEMPTS, ImageCache, file_sha256


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


def checksum_definition() -> ImageDefinition:
    return ImageDefinition(
        name="fixture",
        url="https://example.invalid/fixture.qcow2",
        sha256=None,
        checksum_url="https://example.invalid/sha256sums.txt",
        signature_url=None,
        signature_required=False,
        keyring="",
    )


def test_checksum_fetch_retries_transient_dns_failure(
    tmp_path: Path, monkeypatch
) -> None:
    digest = "a" * 64
    responses: list[object] = [
        urllib.error.URLError("temporary name resolution failure"),
        urllib.error.URLError("temporary name resolution failure"),
        io.BytesIO(f"{digest} fixture.qcow2\n".encode()),
    ]
    sleeps: list[int] = []

    def urlopen(*_args, **_kwargs):
        response = responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response

    monkeypatch.setattr("enoshima_vm.image.urllib.request.urlopen", urlopen)
    monkeypatch.setattr("enoshima_vm.image.time.sleep", sleeps.append)

    actual = ImageCache(paths(tmp_path))._expected_sha256(checksum_definition())

    assert actual == digest
    assert sleeps == [1, 2]


def test_exhausted_checksum_dns_failure_is_retryable_infrastructure(
    tmp_path: Path, monkeypatch
) -> None:
    calls = 0

    def urlopen(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        raise urllib.error.URLError("temporary name resolution failure")

    monkeypatch.setattr("enoshima_vm.image.urllib.request.urlopen", urlopen)
    monkeypatch.setattr("enoshima_vm.image.time.sleep", lambda _seconds: None)

    with pytest.raises(VMError) as failure:
        ImageCache(paths(tmp_path))._expected_sha256(checksum_definition())

    assert failure.value.category == FailureCategory.HOST_INFRA_ERROR
    assert failure.value.details == {
        "attempts": NETWORK_FETCH_ATTEMPTS,
        "error": "<urlopen error temporary name resolution failure>",
    }
    assert calls == NETWORK_FETCH_ATTEMPTS


def test_nonretryable_checksum_http_status_fails_once(
    tmp_path: Path, monkeypatch
) -> None:
    calls = 0

    def urlopen(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        raise urllib.error.HTTPError(
            "https://example.invalid/sha256sums.txt",
            404,
            "not found",
            {},
            None,
        )

    monkeypatch.setattr("enoshima_vm.image.urllib.request.urlopen", urlopen)

    with pytest.raises(VMError) as failure:
        ImageCache(paths(tmp_path))._expected_sha256(checksum_definition())

    assert failure.value.category == FailureCategory.IMAGE_ERROR
    assert "non-retryable HTTP status 404" in failure.value.message
    assert calls == 1
