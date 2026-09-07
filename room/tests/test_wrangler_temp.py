"""Bounded wrangler --temporary: job 内に閉じ、claim URL をツール戻り値に出さない。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from mihari_room.contracts import CreateJobRequest, JobSource
from mihari_room.events import EventJournal
from mihari_room.store.file_store import FileJobStore
from mihari_room.worker.wrangler_temp import (
    WRANGLER_TMP_DIRNAME,
    TempDeployError,
    cloudflare_temp_deploy_impl,
    make_temp_deploy_handler,
    parse_wrangler_output,
    resolve_workdir,
    run_temp_deploy,
    temp_deploys_for,
)

SAMPLE_OUT = """
Continuing means you accept Cloudflare's Terms of Service.
Temporary account ready:
  Account:        example-name (created)
  Claim within:   60 minutes
  Claim URL:      https://dash.cloudflare.com/claim-preview?claimToken=SECRETCLAIM
Uploaded example-worker
Deployed example-worker triggers
  https://example-worker.example-name.workers.dev
"""


def _job(tmp_path: Path):
    store = FileJobStore(tmp_path)
    return store.create(CreateJobRequest(title="t", body="b", source=JobSource.PET))


def test_parse_wrangler_output_picks_preview_and_claim() -> None:
    parsed = parse_wrangler_output(SAMPLE_OUT)
    assert parsed["preview_url"] == "https://example-worker.example-name.workers.dev"
    assert parsed["claim_url"].endswith("claimToken=SECRETCLAIM")


def test_resolve_workdir_stays_inside_job(tmp_path: Path) -> None:
    job = _job(tmp_path)
    inner = job.directory / "worker"
    inner.mkdir()
    assert resolve_workdir(job.directory, "worker") == inner.resolve()
    with pytest.raises(TempDeployError):
        resolve_workdir(job.directory, "../escape")
    with pytest.raises(TempDeployError):
        resolve_workdir(job.directory, "/tmp")


def test_resolve_workdir_missing_dir_lists_job_contents(tmp_path: Path) -> None:
    job = _job(tmp_path)
    with pytest.raises(TempDeployError, match="このジョブ直下"):
        resolve_workdir(job.directory, "worker")


def test_run_temp_deploy_surfaces_wrangler_stderr(tmp_path: Path) -> None:
    job = _job(tmp_path)

    def runner(argv, *, cwd, env, timeout):
        return 1, "", "Could not detect a directory containing static files"

    with pytest.raises(TempDeployError, match="static files"):
        run_temp_deploy(job.directory, runner=runner)


def test_run_temp_deploy_uses_isolated_env_and_job_cwd(tmp_path: Path) -> None:
    job = _job(tmp_path)
    seen: dict[str, object] = {}

    def runner(argv, *, cwd, env, timeout):
        seen["argv"] = argv
        seen["cwd"] = Path(cwd)
        seen["env"] = dict(env)
        seen["timeout"] = timeout
        return 0, SAMPLE_OUT, ""

    record = run_temp_deploy(job.directory, runner=runner)
    assert seen["cwd"] == job.directory.resolve()
    env = seen["env"]
    assert isinstance(env, dict)
    assert "CLOUDFLARE_API_TOKEN" not in env
    assert env["XDG_CONFIG_HOME"].endswith(WRANGLER_TMP_DIRNAME)
    assert Path(env["XDG_CONFIG_HOME"]).is_relative_to(job.directory.resolve())
    assert "--temporary" in seen["argv"]
    assert "WRANGLER_LOG" not in env
    assert record["preview_url"].endswith(".workers.dev")
    assert "SECRETCLAIM" in record["claim_url"]


def test_tool_result_omits_claim_and_journal_has_no_token(tmp_path: Path) -> None:
    job = _job(tmp_path)

    def runner(argv, *, cwd, env, timeout):
        return 0, SAMPLE_OUT, ""

    payload = json.loads(cloudflare_temp_deploy_impl(job, runner=runner))
    assert payload["success"] is True
    assert "workers.dev" in payload["preview_url"]
    blob = json.dumps(payload)
    assert "claimToken" not in blob
    assert "SECRETCLAIM" not in blob
    stored = temp_deploys_for(job.directory)
    assert stored[-1]["claim_url"].endswith("SECRETCLAIM")
    events = EventJournal.for_job(job.directory).events()
    texts = " ".join(str(e.get("text") or "") for e in events)
    assert "SECRETCLAIM" not in texts
    assert "claimToken" not in texts
    assert "workers.dev" in texts


def test_hermes_positional_args_dict_does_not_typeerror(tmp_path: Path) -> None:
    job = _job(tmp_path)

    def runner(argv, *, cwd, env, timeout):
        return 0, SAMPLE_OUT, ""

    handler = make_temp_deploy_handler(job, runner=runner)
    payload = json.loads(handler({"subdir": "."}))
    assert payload["success"] is True
    assert "workers.dev" in payload["preview_url"]
    again = json.loads(handler(subdir="."))
    assert again["success"] is True


def test_parses_workers_dev_from_wrangler_log_when_stdout_quiet(tmp_path: Path) -> None:
    job = _job(tmp_path)
    log_dir = job.directory / WRANGLER_TMP_DIRNAME / ".wrangler" / "logs"
    log_dir.mkdir(parents=True)
    (log_dir / "wrangler-2026-09-07_00-00-00_000.log").write_text(
        "Deployed counter-temp triggers\n  https://counter-temp.example.workers.dev\n"
        "Claim URL:      https://dash.cloudflare.com/claim-preview?claimToken=SECRETCLAIM\n",
        encoding="utf-8",
    )

    def runner(argv, *, cwd, env, timeout):
        return 0, "", ""

    record = run_temp_deploy(job.directory, runner=runner)
    assert record["preview_url"] == "https://counter-temp.example.workers.dev"
    assert record["claim_url"].endswith("SECRETCLAIM")
