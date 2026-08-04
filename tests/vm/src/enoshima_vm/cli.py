from __future__ import annotations

import argparse
import json
from collections.abc import Callable
from typing import Any

from .errors import VMError
from .results import bound_verification_plan, summarize_run_list, summarize_run_record
from .service import VMService
from .verification import VALID_MODES


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="enoshima-vm")
    root.add_argument(
        "--libvirt-uri",
        help="libvirt connection URI (default: qemu:///session)",
    )
    commands = root.add_subparsers(dest="command", required=True)

    preflight = commands.add_parser("preflight")
    preflight.add_argument("suite", nargs="?", default="smoke")

    run = commands.add_parser("run")
    run.add_argument("suite")
    run.add_argument("--keep-on-failure", action="store_true")
    run.add_argument("--mode", choices=VALID_MODES[:2], default="checkpoint")
    run.add_argument("--base", default="origin/main")

    verification_plan = commands.add_parser("verification-plan")
    verification_plan.add_argument("--base", default="origin/main")
    verification_plan.add_argument("--mode", choices=VALID_MODES, default="checkpoint")

    check_affected = commands.add_parser("check-affected")
    check_affected.add_argument("--base", default="origin/main")
    check_affected.add_argument("--mode", choices=VALID_MODES, default="checkpoint")

    run_affected = commands.add_parser("run-affected")
    run_affected.add_argument("--base", default="origin/main")
    run_affected.add_argument("--mode", choices=VALID_MODES[:2], default="checkpoint")

    run_plan = commands.add_parser("run-plan")
    run_plan.add_argument("plan", nargs="?", default="release")
    run_plan.add_argument("--base", default="origin/main")

    create = commands.add_parser("create")
    create.add_argument("suite")

    wait = commands.add_parser("wait")
    wait.add_argument("run_id")
    wait.add_argument("--timeout", type=int, default=1200)

    upload = commands.add_parser("upload-worktree")
    upload.add_argument("run_id")

    status = commands.add_parser("status")
    status.add_argument("run_id")

    execute = commands.add_parser("exec")
    execute.add_argument("run_id")
    execute.add_argument("--timeout", type=int, default=300)
    execute.add_argument("argv", nargs=argparse.REMAINDER)

    reboot = commands.add_parser("reboot")
    reboot.add_argument("run_id")
    reboot.add_argument("--timeout", type=int, default=600)

    poweroff = commands.add_parser("poweroff")
    poweroff.add_argument("run_id")

    screenshot = commands.add_parser("screenshot")
    screenshot.add_argument("run_id")
    screenshot.add_argument("--name", default="desktop")
    screenshot.add_argument("--output")

    query = commands.add_parser("query-desktop")
    query.add_argument("run_id")

    collect = commands.add_parser("collect")
    collect.add_argument("run_id")

    destroy = commands.add_parser("destroy")
    destroy.add_argument("run_id")

    list_runs = commands.add_parser("list-runs")
    list_runs.add_argument("--cursor")
    list_runs.add_argument("--limit", type=int, default=20)
    commands.add_parser("clean")
    return root


def dispatch(service: VMService, args: argparse.Namespace) -> Any:
    actions: dict[str, Callable[[], Any]] = {
        "preflight": lambda: service.preflight(args.suite),
        "run": lambda: service.run_suite_result(
            args.suite,
            keep_on_failure=args.keep_on_failure,
            verification_mode=args.mode,
            base_ref=args.base,
        ),
        "verification-plan": lambda: bound_verification_plan(
            service.verification_plan(args.base, args.mode)
        ),
        "check-affected": lambda: service.check_affected(args.base, args.mode),
        "run-affected": lambda: service.run_affected(args.base, args.mode),
        "run-plan": lambda: service.run_plan(args.plan, base_ref=args.base),
        "create": lambda: summarize_run_record(service.create(args.suite)),
        "wait": lambda: summarize_run_record(service.wait(args.run_id, args.timeout)),
        "upload-worktree": lambda: service.upload_worktree(args.run_id),
        "status": lambda: summarize_run_record(service.status(args.run_id)),
        "exec": lambda: service.exec_bounded(
            args.run_id, args.argv, timeout_seconds=args.timeout
        ),
        "reboot": lambda: service.reboot(args.run_id, args.timeout),
        "poweroff": lambda: service.poweroff(args.run_id),
        "screenshot": lambda: service.screenshot(args.run_id, args.name, args.output),
        "query-desktop": lambda: service.query_desktop_bounded(args.run_id),
        "collect": lambda: service.collect(args.run_id),
        "destroy": lambda: service.destroy(args.run_id),
        "list-runs": lambda: summarize_run_list(
            service.list_runs(), cursor=args.cursor, limit=args.limit
        ),
        "clean": service.clean,
    }
    return actions[args.command]()


def main() -> None:
    args = parser().parse_args()
    service = VMService(libvirt_uri=args.libvirt_uri)
    try:
        result = dispatch(service, args)
    except VMError as error:
        print(
            json.dumps(
                {
                    "result": "failed",
                    "category": error.category,
                    "message": error.message,
                    "details": error.details,
                },
                indent=2,
            )
        )
        raise SystemExit(1) from error
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(
            json.dumps(
                {
                    "result": "failed",
                    "category": "HARNESS_ERROR",
                    "message": str(error),
                },
                indent=2,
            )
        )
        raise SystemExit(1) from error
    print(json.dumps(result, indent=2))
    if isinstance(result, dict) and result.get("result") in {"failed", "blocked"}:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
