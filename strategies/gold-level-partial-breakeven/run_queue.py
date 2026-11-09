"""Run backtests from a job file with at most N processes at once.

    python run_queue.py 3 results/queue_dev.txt

Each non-empty, non-# line of the job file holds run_matrix.py arguments.
Every run logs to results/logs/<args>.log.
"""
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).parent
PY = r"C:\Users\V\Nautilus trading\.venv\Scripts\python.exe"


def main() -> None:
    max_procs = int(sys.argv[1])
    jobs = [ln.split() for ln in Path(sys.argv[2]).read_text().splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]
    logs = ROOT / "results" / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    running = []
    t_all = time.time()
    while jobs or running:
        while jobs and len(running) < max_procs:
            args = jobs.pop(0)
            tag = "_".join(a.lstrip("-").replace("=", "-") for a in args)
            log = open(logs / f"{tag}.log", "w")
            p = subprocess.Popen([PY, "-W", "ignore", "run_matrix.py", *args], cwd=ROOT,
                                 stdout=log, stderr=subprocess.STDOUT)
            running.append((p, tag, log, time.time()))
            print(f"start {tag}", flush=True)
        for item in running[:]:
            p, tag, log, t0 = item
            if p.poll() is not None:
                log.close()
                running.remove(item)
                print(f"done  {tag}  exit={p.returncode}  {time.time() - t0:.0f}s", flush=True)
        time.sleep(5)
    print(f"all done in {time.time() - t_all:.0f}s", flush=True)


if __name__ == "__main__":
    main()
