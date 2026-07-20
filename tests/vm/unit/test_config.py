from __future__ import annotations

from pathlib import Path

import pytest

from enoshima_vm.config import (
    MAX_DISK_GIB,
    MAX_MEMORY_MIB,
    MAX_VCPUS,
    Network,
    Resources,
    RuntimePaths,
    load_images,
    load_suite,
)


def test_repository_suites_obey_resource_and_network_boundaries() -> None:
    paths = RuntimePaths.discover()
    for name in (
        "smoke",
        "converge",
        "reboot",
        "desktop",
        "login",
        "boot-security",
    ):
        suite = load_suite(name, paths)
        assert suite.resources.vcpus <= MAX_VCPUS
        assert suite.resources.memory_mib <= MAX_MEMORY_MIB
        assert suite.resources.disk_gib <= MAX_DISK_GIB
        assert suite.network.mode == "isolated-user"
        assert suite.network.allow_lan is False


@pytest.mark.parametrize(
    "resources",
    [
        Resources(MAX_VCPUS + 1, 8192, 64),
        Resources(4, MAX_MEMORY_MIB + 1, 64),
        Resources(4, 8192, MAX_DISK_GIB + 1),
    ],
)
def test_resource_limits_are_enforced(resources: Resources) -> None:
    with pytest.raises(ValueError):
        resources.validate()


def test_lan_network_is_rejected() -> None:
    with pytest.raises(ValueError, match="LAN"):
        Network(allow_lan=True).validate()


def test_manifest_has_signed_reproducible_and_latest_images() -> None:
    images = load_images()
    assert set(images) == {"arch-cloud-reproducible", "arch-cloud-latest"}
    assert all(image.signature_required for image in images.values())
    assert images["arch-cloud-reproducible"].sha256
    assert images["arch-cloud-reproducible"].repository_snapshot == "2026/07/15"
    assert images["arch-cloud-latest"].checksum_url
    assert images["arch-cloud-latest"].repository_snapshot is None


def test_suite_name_cannot_escape_suite_root(tmp_path: Path) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    with pytest.raises(Exception, match="invalid suite name"):
        load_suite("../secret", paths)
