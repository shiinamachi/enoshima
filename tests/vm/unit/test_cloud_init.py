from __future__ import annotations

import subprocess

import pytest

from enoshima_vm.cloud_init import CloudInitBuilder
from enoshima_vm.config import RuntimePaths
from enoshima_vm.errors import FailureCategory, VMError


def test_host_tool_failure_is_infrastructure(tmp_path, monkeypatch) -> None:
    builder = CloudInitBuilder(RuntimePaths.discover())
    monkeypatch.setattr(
        "enoshima_vm.cloud_init.run",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            subprocess.CalledProcessError(1, ["ssh-keygen"])
        ),
    )

    with pytest.raises(VMError) as raised:
        builder.build(tmp_path, "run-123456789abc", "kentakang")

    assert raised.value.category is FailureCategory.HOST_INFRA_ERROR
