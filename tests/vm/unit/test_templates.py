from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from enoshima_vm.config import RuntimePaths


def test_domain_templates_render_as_xml_without_host_mounts(tmp_path: Path) -> None:
    paths = RuntimePaths.discover()
    environment = Environment(
        loader=FileSystemLoader(paths.project / "templates"),
        autoescape=True,
        undefined=StrictUndefined,
    )
    context = {
        "domain": "enoshima-test-run-012345abcdef",
        "memory_mib": 8192,
        "vcpus": 4,
        "overlay": tmp_path / "root.qcow2",
        "boot_disk": tmp_path / "boot.qcow2",
        "seed": tmp_path / "seed.iso",
        "ssh_host_port": 22022,
        "run_dir": tmp_path,
    }
    for name in (
        "domain-fast.xml.j2",
        "domain-desktop.xml.j2",
        "domain-secure-boot.xml.j2",
    ):
        rendered = environment.get_template(name).render(**context)
        root = ET.fromstring(rendered)
        assert root.findtext("name") == context["domain"]
        assert root.findall(".//filesystem") == []
        assert "hostfwd=tcp:127.0.0.1:22022-:22" in rendered
        assert "/dev/" not in rendered.replace("/dev/urandom", "")
