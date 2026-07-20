from __future__ import annotations

import os
import re
import shutil
import tempfile
import urllib.request
from hashlib import sha256
from pathlib import Path

from .config import ImageDefinition, RuntimePaths
from .errors import FailureCategory, VMError
from .process import run

SHA256_PATTERN = re.compile(r"\b([0-9a-fA-F]{64})\b")


def file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class ImageCache:
    def __init__(self, paths: RuntimePaths) -> None:
        self.paths = paths
        self.root = paths.cache / "images"

    @staticmethod
    def _download(url: str, destination: Path) -> None:
        request = urllib.request.Request(url, headers={"User-Agent": "enoshima-vm/0.1"})
        with urllib.request.urlopen(request, timeout=60) as response:
            with destination.open("wb") as output:
                shutil.copyfileobj(response, output, length=1024 * 1024)
        destination.chmod(0o600)

    def _expected_sha256(self, image: ImageDefinition) -> str:
        if image.sha256:
            return image.sha256.lower()
        if not image.checksum_url:
            raise VMError(
                FailureCategory.IMAGE_ERROR,
                f"image {image.name} has no checksum source",
            )
        try:
            request = urllib.request.Request(
                image.checksum_url,
                headers={"User-Agent": "enoshima-vm/0.1"},
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                checksum_text = response.read(4096).decode("utf-8", errors="replace")
        except OSError as error:
            raise VMError(
                FailureCategory.IMAGE_ERROR,
                f"cannot download checksum for {image.name}",
                {"error": str(error)},
            ) from error
        match = SHA256_PATTERN.search(checksum_text)
        if not match:
            raise VMError(
                FailureCategory.IMAGE_ERROR,
                f"invalid checksum response for {image.name}",
            )
        return match.group(1).lower()

    def ensure(self, image: ImageDefinition) -> Path:
        expected = self._expected_sha256(image)
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        destination = self.root / f"{image.name}-{expected[:16]}.qcow2"
        if destination.exists() and file_sha256(destination) == expected:
            return destination

        temporary_fd, temporary_name = tempfile.mkstemp(
            prefix=f".{image.name}-", suffix=".part", dir=self.root
        )
        os.close(temporary_fd)
        temporary = Path(temporary_name)
        signature = temporary.with_suffix(".sig")
        try:
            self._download(image.url, temporary)
            actual = file_sha256(temporary)
            if actual != expected:
                raise VMError(
                    FailureCategory.IMAGE_ERROR,
                    f"checksum mismatch for {image.name}",
                    {"expected": expected, "actual": actual},
                )
            if image.signature_required:
                if not image.signature_url:
                    raise VMError(
                        FailureCategory.IMAGE_ERROR,
                        f"signature is required but missing for {image.name}",
                    )
                keyring = Path(image.keyring)
                if not keyring.is_file():
                    raise VMError(
                        FailureCategory.IMAGE_ERROR,
                        f"Arch signing keyring is unavailable: {keyring}",
                    )
                self._download(image.signature_url, signature)
                try:
                    run(
                        ["gpgv", "--keyring", keyring, signature, temporary],
                        timeout=60,
                    )
                except Exception as error:
                    raise VMError(
                        FailureCategory.IMAGE_ERROR,
                        f"signature verification failed for {image.name}",
                        {"error": str(error)},
                    ) from error
            os.replace(temporary, destination)
            destination.chmod(0o600)
        except VMError:
            raise
        except OSError as error:
            raise VMError(
                FailureCategory.IMAGE_ERROR,
                f"cannot cache image {image.name}",
                {"error": str(error)},
            ) from error
        finally:
            temporary.unlink(missing_ok=True)
            signature.unlink(missing_ok=True)
        return destination
