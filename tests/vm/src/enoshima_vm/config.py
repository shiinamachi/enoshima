from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from .errors import FailureCategory, VMError

DOMAIN_PREFIX = "enoshima-test-"
RUN_ID_PATTERN = re.compile(r"^run-[0-9a-f]{12}$")
MAX_VCPUS = 8
MAX_MEMORY_MIB = 14 * 1024
MAX_DISK_GIB = 128
MAX_ACTIVE_DOMAINS = 1


def repository_root() -> Path:
    return Path(__file__).resolve().parents[4]


def vm_project_root() -> Path:
    return repository_root() / "tests" / "vm"


@dataclass(frozen=True, slots=True)
class RuntimePaths:
    repository: Path
    project: Path
    cache: Path
    state: Path

    @classmethod
    def discover(cls) -> RuntimePaths:
        repo = repository_root()
        cache = Path(
            os.environ.get(
                "ENOSHIMA_VM_CACHE_ROOT",
                Path.home() / ".cache" / "enoshima-vm",
            )
        ).expanduser()
        state = Path(
            os.environ.get(
                "ENOSHIMA_VM_STATE_ROOT",
                Path.home() / ".local" / "state" / "enoshima-vm",
            )
        ).expanduser()
        return cls(repo, vm_project_root(), cache, state)


@dataclass(frozen=True, slots=True)
class Resources:
    vcpus: int
    memory_mib: int
    disk_gib: int

    def validate(self) -> None:
        if not 1 <= self.vcpus <= MAX_VCPUS:
            raise ValueError(f"vcpus must be between 1 and {MAX_VCPUS}")
        if not 1024 <= self.memory_mib <= MAX_MEMORY_MIB:
            raise ValueError(f"memory_mib must be between 1024 and {MAX_MEMORY_MIB}")
        if not 8 <= self.disk_gib <= MAX_DISK_GIB:
            raise ValueError(f"disk_gib must be between 8 and {MAX_DISK_GIB}")


@dataclass(frozen=True, slots=True)
class Network:
    mode: str = "isolated-user"
    allow_inbound_from_host: bool = True
    allow_lan: bool = False

    def validate(self) -> None:
        if self.mode != "isolated-user":
            raise ValueError("only the isolated-user network backend is permitted")
        if not self.allow_inbound_from_host:
            raise ValueError("host-to-guest SSH is required by the VM runner")
        if self.allow_lan:
            raise ValueError("VM access to the host LAN is forbidden")


@dataclass(frozen=True, slots=True)
class Suite:
    name: str
    base_image: str
    domain_template: str
    profile: str
    resources: Resources
    network: Network
    steps: tuple[str | dict[str, Any], ...]
    allowed_skips: frozenset[str] = field(default_factory=frozenset)
    fail_on_unexpected_skip: bool = True
    timeout_minutes: int = 180

    def validate(self) -> None:
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", self.name):
            raise ValueError(f"invalid suite name: {self.name}")
        self.resources.validate()
        self.network.validate()
        if not 5 <= self.timeout_minutes <= 360:
            raise ValueError("timeout_minutes must be between 5 and 360")
        for step in self.steps:
            if isinstance(step, str):
                continue
            if not isinstance(step, dict) or len(step) != 1:
                raise ValueError(
                    f"suite step must be a string or one-key map: {step!r}"
                )


@dataclass(frozen=True, slots=True)
class ImageDefinition:
    name: str
    url: str
    sha256: str | None
    checksum_url: str | None
    signature_url: str | None
    signature_required: bool
    keyring: str
    repository_snapshot: str | None = None


def _load_yaml(path: Path) -> dict[str, Any]:
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"cannot load configuration: {path}",
            {"error": str(error)},
        ) from error
    if not isinstance(value, dict):
        raise VMError(FailureCategory.HARNESS_ERROR, f"invalid mapping: {path}")
    return value


def load_suite(name: str, paths: RuntimePaths | None = None) -> Suite:
    paths = paths or RuntimePaths.discover()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        raise VMError(FailureCategory.HARNESS_ERROR, f"invalid suite name: {name}")
    path = paths.project / "suites" / f"{name}.yaml"
    data = _load_yaml(path)
    resources = Resources(**data["resources"])
    network = Network(**data.get("network", {}))
    suite = Suite(
        name=data["name"],
        base_image=data["base_image"],
        domain_template=data["domain_template"],
        profile=data["profile"],
        resources=resources,
        network=network,
        steps=tuple(data["steps"]),
        allowed_skips=frozenset(data.get("allowed_skips", [])),
        fail_on_unexpected_skip=bool(data.get("fail_on_unexpected_skip", True)),
        timeout_minutes=int(data.get("timeout_minutes", 180)),
    )
    try:
        suite.validate()
    except (KeyError, TypeError, ValueError) as error:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"invalid suite: {path}",
            {"error": str(error)},
        ) from error
    if suite.name != name:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"suite filename and name differ: {name} != {suite.name}",
        )
    return suite


def load_images(paths: RuntimePaths | None = None) -> dict[str, ImageDefinition]:
    paths = paths or RuntimePaths.discover()
    data = _load_yaml(paths.project / "images" / "manifest.yaml")
    images: dict[str, ImageDefinition] = {}
    for name, raw in data.get("images", {}).items():
        snapshot = raw.get("repository_snapshot")
        if snapshot is not None and not re.fullmatch(
            r"[0-9]{4}/[0-9]{2}/[0-9]{2}", str(snapshot)
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"invalid repository snapshot for image: {name}",
            )
        images[name] = ImageDefinition(
            name=name,
            url=raw["url"],
            sha256=raw.get("sha256"),
            checksum_url=raw.get("checksum_url"),
            signature_url=raw.get("signature_url"),
            signature_required=raw.get("signature", "required") == "required",
            keyring=raw.get("keyring", "/usr/share/pacman/keyrings/archlinux.gpg"),
            repository_snapshot=snapshot,
        )
    return images
