from __future__ import annotations

import os
import select
import subprocess
from pathlib import Path

import pytest

from enoshima_vm.config import RuntimePaths
from enoshima_vm.errors import VMError
from enoshima_vm.libvirt_backend import DomainSpec, LibvirtBackend
from enoshima_vm.process import CommandResult


def test_virsh_overrides_noncanonical_inherited_session_environment(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    captured: dict[str, object] = {}

    def fake_run(argv, **kwargs):
        captured["argv"] = tuple(argv)
        captured["env"] = kwargs["env"]
        return CommandResult(tuple(str(value) for value in argv), 0, "", "")

    monkeypatch.setenv("XDG_RUNTIME_DIR", "/tmp/wrong-session")
    monkeypatch.setenv("XDG_CACHE_HOME", "/tmp/wrong-cache")
    monkeypatch.setenv("XDG_CONFIG_HOME", "/tmp/wrong-config")
    monkeypatch.setattr("enoshima_vm.libvirt_backend.run", fake_run)

    backend.virsh(["list", "--all", "--name"])

    environment = captured["env"]
    assert isinstance(environment, dict)
    assert environment["XDG_RUNTIME_DIR"] == f"/run/user/{os.getuid()}"
    assert environment["XDG_CACHE_HOME"] == str(Path.home() / ".cache")
    assert environment["XDG_CONFIG_HOME"] == str(Path.home() / ".config")


def test_type_text_waits_for_each_qemu_key_release(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    calls: list[tuple[tuple[str, ...], int]] = []
    waits: list[float] = []
    domain_uuid = "12345678-1234-5678-1234-567812345678"

    monkeypatch.setattr(
        backend,
        "send_keys",
        lambda _domain, _domain_uuid, keys, *, hold_milliseconds=100: calls.append(
            (tuple(keys), hold_milliseconds)
        ),
    )
    monkeypatch.setattr("enoshima_vm.libvirt_backend.time.sleep", waits.append)

    backend.type_text("enoshima-test-run-012345abcdef", domain_uuid, "a 7")

    assert calls == [
        (("KEY_A",), 80),
        (("KEY_SPACE",), 80),
        (("KEY_7",), 80),
        (("KEY_ENTER",), 100),
    ]
    assert waits == [0.12, 0.12, 0.12]


def test_type_serial_text_uses_libvirt_console_without_argv_secret(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    calls: list[tuple[str, ...]] = []
    processes: list[object] = []
    waits: list[float] = []
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    monkeypatch.setattr(backend, "owned_state", lambda *_args: "running")

    class FakeProcess:
        def __init__(self, argv, *, stdin, stdout, **_kwargs) -> None:
            calls.append(tuple(argv))
            self.console = os.dup(stdin)
            self.returncode: int | None = None
            self.received = b""
            os.write(stdout, b"Connected to domain fixture\nEscape character is ^]\n")
            processes.append(self)

        def poll(self):
            return self.returncode

        def wait(self, *, timeout):
            chunks = []
            while select.select([self.console], [], [], 0)[0]:
                chunks.append(os.read(self.console, 128))
            self.received = b"".join(chunks)
            os.close(self.console)
            self.returncode = 0
            return self.returncode

        def terminate(self):
            self.returncode = 0

        def kill(self):
            self.returncode = -9

    monkeypatch.setattr("enoshima_vm.libvirt_backend.subprocess.Popen", FakeProcess)
    monkeypatch.setattr("enoshima_vm.libvirt_backend.time.sleep", waits.append)

    backend.type_serial_text(
        "enoshima-test-run-012345abcdef",
        domain_uuid,
        "disposable-recovery-key",
    )

    assert calls == [
        (
            "virsh",
            "--connect",
            "qemu:///session",
            "console",
            domain_uuid,
            "--safe",
        )
    ]
    assert "disposable-recovery-key" not in calls[0]
    assert processes[0].received == b"disposable-recovery-key\r\x1d"
    assert waits == [0.5]


def test_read_serial_text_uses_the_managed_log_and_reboot_offset(tmp_path) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    log = paths.state / "runs" / "run-012345abcdef" / "serial.log"
    log.parent.mkdir(parents=True)
    log.write_text("old boot output\n", encoding="utf-8")
    offset = backend.serial_log_size("enoshima-test-run-012345abcdef")
    log.write_text(
        "old boot output\nPlease enter passphrase for cryptroot: ", encoding="utf-8"
    )

    assert (
        backend.read_serial_text("enoshima-test-run-012345abcdef", start_offset=offset)
        == "Please enter passphrase for cryptroot: "
    )


def test_type_serial_text_rejects_an_unmanaged_domain(tmp_path) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    with pytest.raises(ValueError):
        backend.type_serial_text(
            "unmanaged-domain",
            "12345678-1234-5678-1234-567812345678",
            "disposable-recovery-key",
        )


def test_pointer_events_use_the_absolute_qemu_tablet(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    calls: list[tuple[str, ...]] = []
    ownership_checks: list[tuple[str, str]] = []
    domain = "enoshima-test-run-012345abcdef"
    recorded_uuid = "12345678-1234-5678-ABCD-567812345678"
    canonical_uuid = "12345678-1234-5678-abcd-567812345678"

    def owned_state(candidate_domain, candidate_uuid):
        ownership_checks.append((candidate_domain, candidate_uuid))
        return "running"

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        return CommandResult(tuple(str(value) for value in args), 0, "", "")

    monkeypatch.setattr(backend, "owned_state", owned_state)
    monkeypatch.setattr(backend, "virsh", virsh)

    backend.pointer_move_absolute(domain, recorded_uuid, 100, 200)
    backend.pointer_button(domain, recorded_uuid, "left", True)

    assert calls[0][:2] == (
        "qemu-monitor-command",
        canonical_uuid,
    )
    assert '"type":"abs"' in calls[0][2]
    assert '"axis":"x","value":100' in calls[0][2]
    assert '"axis":"y","value":200' in calls[0][2]
    assert '"button":"left"' in calls[1][2]
    assert '"down":true' in calls[1][2]
    assert ownership_checks == [
        (domain, recorded_uuid),
        (domain, recorded_uuid),
    ]


def test_power_controls_target_the_recorded_uuid(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    calls: list[tuple[tuple[str, ...], int]] = []
    ownership_checks: list[tuple[str, str]] = []
    domain = "enoshima-test-run-012345abcdef"
    recorded_uuid = "12345678-1234-5678-ABCD-567812345678"
    canonical_uuid = "12345678-1234-5678-abcd-567812345678"

    def owned_state(candidate_domain, candidate_uuid):
        ownership_checks.append((candidate_domain, candidate_uuid))
        return "running"

    def virsh(args, *, timeout=120, **_kwargs):
        calls.append((tuple(args), timeout))
        return CommandResult(tuple(str(value) for value in args), 0, "", "")

    monkeypatch.setattr(backend, "owned_state", owned_state)
    monkeypatch.setattr(backend, "virsh", virsh)

    backend.reboot(domain, recorded_uuid)
    backend.reset(domain, recorded_uuid)
    backend.poweroff(domain, recorded_uuid)

    assert calls == [
        (("reboot", canonical_uuid, "--mode", "agent"), 30),
        (("reset", canonical_uuid), 30),
        (("shutdown", canonical_uuid, "--mode", "agent"), 30),
    ]
    assert ownership_checks == [
        (domain, recorded_uuid),
        (domain, recorded_uuid),
        (domain, recorded_uuid),
    ]


def test_wait_guest_agent_targets_the_recorded_uuid(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    recorded_uuid = "12345678-1234-5678-ABCD-567812345678"
    canonical_uuid = "12345678-1234-5678-abcd-567812345678"
    calls: list[tuple[str, ...]] = []

    monkeypatch.setattr(backend, "owned_state", lambda *_args: "running")

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        return CommandResult(tuple(str(value) for value in args), 0, "", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    backend.wait_guest_agent(domain, recorded_uuid, 1)

    assert calls == [("qemu-agent-command", canonical_uuid, '{"execute":"guest-ping"}')]


def test_send_keys_targets_the_recorded_uuid(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    recorded_uuid = "12345678-1234-5678-ABCD-567812345678"
    canonical_uuid = "12345678-1234-5678-abcd-567812345678"
    calls: list[tuple[str, ...]] = []

    monkeypatch.setattr(backend, "owned_state", lambda *_args: "running")

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        return CommandResult(tuple(str(value) for value in args), 0, "", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    backend.send_keys(domain, recorded_uuid, ["KEY_LEFTCTRL", "KEY_C"])

    assert calls == [
        ("send-key", canonical_uuid, "--holdtime", "100", "KEY_LEFTCTRL", "KEY_C")
    ]


@pytest.mark.parametrize(
    "invoke",
    [
        pytest.param(
            lambda backend, domain, domain_uuid: backend.wait_guest_agent(
                domain, domain_uuid, 1
            ),
            id="guest-agent",
        ),
        pytest.param(
            lambda backend, domain, domain_uuid: backend.reboot(domain, domain_uuid),
            id="reboot",
        ),
        pytest.param(
            lambda backend, domain, domain_uuid: backend.reset(domain, domain_uuid),
            id="reset",
        ),
        pytest.param(
            lambda backend, domain, domain_uuid: backend.poweroff(domain, domain_uuid),
            id="poweroff",
        ),
        pytest.param(
            lambda backend, domain, domain_uuid: backend.send_keys(
                domain, domain_uuid, ["KEY_ENTER"]
            ),
            id="send-keys",
        ),
        pytest.param(
            lambda backend, domain, domain_uuid: backend.pointer_move_absolute(
                domain, domain_uuid, 100, 200
            ),
            id="pointer-move",
        ),
        pytest.param(
            lambda backend, domain, domain_uuid: backend.pointer_button(
                domain, domain_uuid, "left", True
            ),
            id="pointer-button",
        ),
    ],
)
def test_domain_operations_reject_a_same_name_replacement(
    tmp_path, monkeypatch, invoke
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    recorded_uuid = "12345678-1234-5678-1234-567812345678"
    replacement_uuid = "87654321-4321-8765-4321-876543218765"
    calls: list[tuple[str, ...]] = []

    monkeypatch.setattr(backend, "_uuid_state", lambda _uuid: "running")

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        return CommandResult(tuple(args), 0, f"{replacement_uuid}\n", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    with pytest.raises(VMError, match="UUID does not match"):
        invoke(backend, domain, recorded_uuid)

    assert calls == [("domuuid", domain)]


def test_domain_operations_reject_an_undefined_recorded_uuid(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"

    monkeypatch.setattr(backend, "owned_state", lambda *_args: "undefined")
    monkeypatch.setattr(
        backend,
        "virsh",
        lambda *_args, **_kwargs: pytest.fail("undefined UUID reached virsh"),
    )

    with pytest.raises(VMError, match="recorded managed domain is undefined"):
        backend.reboot(domain, domain_uuid)


def test_state_requires_a_successful_domain_list_before_reporting_undefined(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    calls: list[tuple[str, ...]] = []

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        return CommandResult(tuple(args), 0, "other-domain\n", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    assert backend.state("enoshima-test-run-012345abcdef") == "undefined"
    assert calls == [("list", "--all", "--name")]


def test_state_rejects_a_failed_domstate_for_a_listed_domain(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    responses = iter(
        (
            CommandResult(("list",), 0, f"{domain}\n", ""),
            CommandResult(("domstate",), 1, "", "transient failure"),
            CommandResult(("list",), 0, f"{domain}\n", ""),
        )
    )
    monkeypatch.setattr(backend, "virsh", lambda *_args, **_kwargs: next(responses))

    with pytest.raises(VMError, match="cannot query managed domain state"):
        backend.state(domain)


def test_define_and_start_targets_the_recorded_uuid(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    spec = DomainSpec(
        run_id="run-012345abcdef",
        domain="enoshima-test-run-012345abcdef",
        domain_uuid="12345678-1234-5678-1234-567812345678",
        overlay=tmp_path / "root.qcow2",
        seed=tmp_path / "seed.iso",
        ssh_host_port=22022,
        xml=tmp_path / "domain.xml",
    )
    calls: list[tuple[tuple[str | Path, ...], float]] = []

    def virsh(args, *, timeout=60, **_kwargs):
        calls.append((tuple(args), timeout))
        return CommandResult(tuple(str(value) for value in args), 0, "", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    backend.define_and_start(spec)

    assert calls == [
        (("define", spec.xml), 60),
        (("start", spec.domain_uuid), 60),
    ]


def test_destroy_rejects_a_failed_stop_before_undefine(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    calls: list[tuple[str, ...]] = []
    monkeypatch.setattr(backend, "_uuid_state", lambda _domain: "running")

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        if args[0] == "domuuid":
            return CommandResult(tuple(args), 0, f"{domain_uuid}\n", "")
        return CommandResult(tuple(args), 1, "", "stop failed")

    monkeypatch.setattr(backend, "virsh", virsh)

    with pytest.raises(VMError, match="cannot stop managed domain"):
        backend.destroy(domain, domain_uuid)
    assert calls == [("domuuid", domain), ("destroy", domain_uuid)]


def test_destroy_timeout_continues_only_when_recorded_uuid_is_shut_off(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    calls: list[tuple[str, ...]] = []
    states = iter(("running", "shut off", "undefined"))
    monkeypatch.setattr(backend, "_uuid_state", lambda _uuid: next(states))
    monkeypatch.setattr(backend, "state", lambda _domain: "undefined")

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        if args[0] == "domuuid":
            return CommandResult(tuple(args), 0, f"{domain_uuid}\n", "")
        if args[0] == "destroy":
            raise subprocess.TimeoutExpired(tuple(args), 30)
        return CommandResult(tuple(args), 0, "", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    backend.destroy(domain, domain_uuid)

    assert calls == [
        ("domuuid", domain),
        ("destroy", domain_uuid),
        ("undefine", domain_uuid, "--nvram", "--tpm"),
    ]


def test_destroy_timeout_rejects_an_active_recorded_uuid(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    calls: list[tuple[str, ...]] = []
    states = iter(("running", "running"))
    monkeypatch.setattr(backend, "_uuid_state", lambda _uuid: next(states))

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        if args[0] == "domuuid":
            return CommandResult(tuple(args), 0, f"{domain_uuid}\n", "")
        if args[0] == "destroy":
            raise subprocess.TimeoutExpired(tuple(args), 30)
        raise AssertionError(f"unexpected mutation after failed stop: {args}")

    monkeypatch.setattr(backend, "virsh", virsh)

    with pytest.raises(VMError, match="recorded UUID remained active"):
        backend.destroy(domain, domain_uuid)

    assert calls == [("domuuid", domain), ("destroy", domain_uuid)]


def test_undefine_timeout_is_accepted_after_recorded_uuid_disappears(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    calls: list[tuple[str, ...]] = []
    states = iter(("shut off", "undefined"))
    monkeypatch.setattr(backend, "_uuid_state", lambda _uuid: next(states))
    monkeypatch.setattr(backend, "state", lambda _domain: "undefined")

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        if args[0] == "domuuid":
            return CommandResult(tuple(args), 0, f"{domain_uuid}\n", "")
        if args[:2] == ["undefine", domain_uuid]:
            raise subprocess.TimeoutExpired(tuple(args), 30)
        raise AssertionError(f"unexpected command: {args}")

    monkeypatch.setattr(backend, "virsh", virsh)

    backend.destroy(domain, domain_uuid)

    assert calls == [
        ("domuuid", domain),
        ("undefine", domain_uuid, "--nvram", "--tpm"),
    ]


def test_undefine_timeout_rejects_a_remaining_recorded_uuid(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    calls: list[tuple[str, ...]] = []
    monkeypatch.setattr(backend, "_uuid_state", lambda _uuid: "shut off")

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        if args[0] == "domuuid":
            return CommandResult(tuple(args), 0, f"{domain_uuid}\n", "")
        if args[0] == "undefine":
            raise subprocess.TimeoutExpired(tuple(args), 30)
        raise AssertionError(f"unexpected command: {args}")

    monkeypatch.setattr(backend, "virsh", virsh)

    with pytest.raises(VMError, match="cannot undefine managed domain"):
        backend.destroy(domain, domain_uuid)

    assert calls == [
        ("domuuid", domain),
        ("undefine", domain_uuid, "--nvram", "--tpm"),
        ("undefine", domain_uuid, "--nvram"),
    ]


def test_destroy_requires_undefine_and_final_absence(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    states = iter(("shut off", "shut off"))
    monkeypatch.setattr(backend, "_uuid_state", lambda _domain: next(states))
    monkeypatch.setattr(backend, "state", lambda _domain: "undefined")

    def virsh(args, **_kwargs):
        stdout = f"{domain_uuid}\n" if args[0] == "domuuid" else ""
        return CommandResult(tuple(args), 0, stdout, "")

    monkeypatch.setattr(backend, "virsh", virsh)

    with pytest.raises(VMError, match="still exists after cleanup"):
        backend.destroy(domain, domain_uuid)


def test_destroy_rejects_both_undefine_failures(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    monkeypatch.setattr(backend, "_uuid_state", lambda _domain: "shut off")

    def virsh(args, **_kwargs):
        if args[0] == "domuuid":
            return CommandResult(tuple(args), 0, f"{domain_uuid}\n", "")
        return CommandResult(tuple(args), 1, "", "failed")

    monkeypatch.setattr(backend, "virsh", virsh)

    with pytest.raises(VMError, match="cannot undefine managed domain"):
        backend.destroy(domain, domain_uuid)


def test_destroy_rejects_a_same_name_domain_with_a_different_uuid(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    calls: list[tuple[str, ...]] = []

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        return CommandResult(
            tuple(args), 0, "87654321-4321-8765-4321-876543218765\n", ""
        )

    monkeypatch.setattr(backend, "virsh", virsh)

    with pytest.raises(VMError, match="UUID does not match"):
        backend.destroy(domain, "12345678-1234-5678-1234-567812345678")

    assert calls == [
        ("list", "--all", "--uuid"),
        ("domuuid", domain),
    ]


def test_destroy_tracks_recorded_uuid_when_domain_name_no_longer_resolves(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    calls: list[tuple[str, ...]] = []
    states = iter(("running", "shut off", "undefined"))
    monkeypatch.setattr(backend, "_uuid_state", lambda _uuid: next(states))
    monkeypatch.setattr(backend, "state", lambda _domain: "undefined")

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        if args[0] == "domuuid":
            return CommandResult(tuple(args), 1, "", "domain not found")
        return CommandResult(tuple(args), 0, "", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    backend.destroy(domain, domain_uuid)

    assert calls == [
        ("domuuid", domain),
        ("destroy", domain_uuid),
        ("undefine", domain_uuid, "--nvram", "--tpm"),
    ]


def test_destroy_targets_uuid_and_rejects_a_same_name_replacement(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    backend = LibvirtBackend(paths)
    domain = "enoshima-test-run-012345abcdef"
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    calls: list[tuple[str, ...]] = []
    states = iter(("shut off", "undefined"))
    monkeypatch.setattr(backend, "_uuid_state", lambda _uuid: next(states))
    monkeypatch.setattr(backend, "state", lambda _domain: "running")

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        if args[0] == "domuuid":
            value = (
                domain_uuid
                if len(calls) == 1
                else "87654321-4321-8765-4321-876543218765"
            )
            return CommandResult(tuple(args), 0, f"{value}\n", "")
        return CommandResult(tuple(args), 0, "", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    with pytest.raises(VMError, match="name was reused"):
        backend.destroy(domain, domain_uuid)

    assert ("undefine", domain_uuid, "--nvram", "--tpm") in calls
    assert all(call[:2] != ("undefine", domain) for call in calls)
