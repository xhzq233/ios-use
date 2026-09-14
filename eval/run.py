#!/usr/bin/env python3
"""One fresh codex exec task, or offline collection of its original JSONL evidence.

No device setup, navigation helpers, model retries, grading, or authentication.
Run artifacts are private. See README.md before using the run subcommand.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time


def events(path):
    with Path(path).open() as stream:
        for line in stream:
            if line.strip():
                yield json.loads(line)


def collect(exec_path, transcript=None):
    result = {"thread_id": None, "model": {}, "timing": {}, "tokens": {},
              "completed": False, "tools": {"calls": 0, "failed": 0}}
    exec_usage = None
    for event in events(exec_path):
        if event["type"] == "thread.started":
            result["thread_id"] = event["thread_id"]
        elif event["type"] == "turn.completed":
            result["completed"] = True
            exec_usage = event.get("usage")
        elif event["type"] == "item.completed":
            item = event["item"]
            if item["type"] in ("command_execution", "mcp_tool_call"):
                result["tools"]["calls"] += 1
                result["tools"]["failed"] += item.get("status") == "failed"

    session_usage = None
    if transcript:
        result["transcript"] = str(transcript)
        for event in events(transcript):
            payload = event.get("payload", {})
            if event["type"] == "session_meta":
                result["model"].update(provider=payload.get("model_provider"),
                                       codex_version=payload.get("cli_version"))
            elif event["type"] == "turn_context":
                result["model"].update(observed=payload.get("model"),
                                       effort=payload.get("effort"))
            elif event["type"] == "event_msg":
                if payload.get("type") == "token_count" and payload.get("info"):
                    session_usage = payload["info"].get("total_token_usage")
                elif payload.get("type") == "task_complete":
                    result["timing"] = {
                        "agent_duration_ms": payload.get("duration_ms"),
                        "time_to_first_token_ms": payload.get("time_to_first_token_ms"),
                    }
    usage = session_usage or exec_usage
    if usage is not None:
        result["tokens"] = dict(usage)
        result["tokens"]["total_tokens"] = usage["input_tokens"] + usage["output_tokens"]
    result["usage_sources_match"] = (
        all(exec_usage.get(key) == session_usage.get(key)
            for key in exec_usage) if exec_usage and session_usage else None
    )
    return result


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def run(args):
    codex_home, cwd, output = (p.expanduser().resolve()
                                for p in (args.codex_home, args.cwd, args.output))
    # A new artifact directory prevents accidental replacement of an earlier run.
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    prompt = args.prompt.read_text().strip()
    command = [args.codex, "exec", "--json", "--sandbox", "danger-full-access",
               "--model", args.model, "-c", f'model_reasoning_effort="{args.effort}"',
               "-C", str(cwd), "--skip-git-repo-check", "-o", str(output / "final.txt"),
               prompt]
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["CODEX_MODEL"] = args.model
    save(output / "request.json", {
        "command": command, "cwd": str(cwd), "codex_home": str(codex_home),
        "model": args.model, "effort": args.effort, "timeout_seconds": args.timeout,
        "python_version": sys.version.split()[0],
        "host": {"os": platform.system(), "version": platform.mac_ver()[0],
                 "architecture": platform.machine()},
    })
    transcript = None
    thread_id = None
    checked_context = False
    termination = None
    exec_path = output / "exec.jsonl"
    started = time.monotonic()
    with exec_path.open("w") as stdout, (output / "stderr.log").open("w") as stderr:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            while process.poll() is None:
                # Inspect actual context early; requested effort alone is insufficient.
                if not checked_context:
                    if not thread_id:
                        with exec_path.open() as stream:
                            first = stream.readline()
                        if first.endswith("\n"):
                            event = json.loads(first)
                            if event.get("type") == "thread.started":
                                thread_id = event["thread_id"]
                    if thread_id and not transcript:
                        transcript = next((codex_home / "sessions").glob(
                            f"**/*{thread_id}.jsonl"), None)
                    if transcript:
                        with transcript.open() as stream:
                            for line in stream:
                                if not line.endswith("\n"):
                                    break
                                event = json.loads(line)
                                if event.get("type") == "turn_context":
                                    context = event["payload"]
                                    checked_context = True
                                    observed = (context.get("model"), context.get("effort"))
                                    print(f"Observed model / effort: {observed}", flush=True)
                                    if observed != (args.model, args.effort):
                                        termination = "model_or_effort_mismatch"
                                        stop(process)
                                    break
                if time.monotonic() - started >= args.timeout:
                    termination = "timeout"
                    stop(process)
                if process.poll() is None:
                    try:
                        process.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        pass
        except KeyboardInterrupt:
            termination = "interrupted"
            stop(process)
        finally:
            stop(process)
    wall_ms = round((time.monotonic() - started) * 1000)
    # Transcript lookup can finish after a very short process has already exited.
    if not transcript:
        thread_id = collect(exec_path)["thread_id"]
        if thread_id:
            transcript = next((codex_home / "sessions").glob(f"**/*{thread_id}.jsonl"), None)
    summary = collect(exec_path, transcript)
    summary["timing"]["process_wall_time_ms"] = wall_ms
    summary.update(exit_code=process.returncode, termination=termination,
                   actual_context_observed_while_running=checked_context)
    save(output / "summary.json", summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    # Missing evidence remains unknown. Completion is not a quality verdict.
    return 0 if process.returncode == 0 and not termination and summary["completed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    launch = commands.add_parser("run", help="Start one paid model task; no automatic retries")
    launch.add_argument("--codex-home", type=Path, required=True)
    launch.add_argument("--cwd", type=Path, required=True)
    launch.add_argument("--output", type=Path, required=True, help="New private artifact directory")
    launch.add_argument("--prompt", type=Path,
                        default=Path(__file__).parent / "prompts/settings.txt")
    launch.add_argument("--codex", default="codex")
    launch.add_argument("--model", default="gpt-6-astra")
    launch.add_argument("--effort", default="low")
    launch.add_argument("--timeout", type=float, default=1800)
    summary = commands.add_parser("summarize", help="Read evidence offline; no model or device calls")
    summary.add_argument("exec_jsonl", type=Path)
    summary.add_argument("--transcript", type=Path)
    args = parser.parse_args()
    if args.action == "summarize":
        print(json.dumps(collect(args.exec_jsonl, args.transcript), ensure_ascii=False, indent=2))
        return 0
    os.umask(0o077)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
