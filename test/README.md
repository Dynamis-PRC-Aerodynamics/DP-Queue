# `dpq` test kit

Runs the `dpq` queue against real OpenFOAM with small copies of the half-car personal case, checks every outcome and writes a report. Run it after any change to `dpq`.

## What it does

`run_test.sh` works inside `~/dpq_test` only: a private copy of `dpq`, a copy of the geometry and the test cases. The real `run/` folder, the installed `dpq` and its queue are not touched.

The test cases keep the structure and the geometry of the template case. `make_test_case.py` only edits `initialConditions`: every refinement level is lowered by 3 (porous and fan zones by 1), layers are set to zero and the solver stops at 30 iterations. With the DP18 geometry this gives about 380 thousand cells.

| Case | Defect planted | Expected outcome |
|---|---|---|
| `t1_ok` | none | OK |
| `t2_snappy_broken` | syntax error in `snappyHexMeshDict` | FAILED at `snappyHexMesh` |
| `t3_solver_broken` | unknown turbulence model | FAILED at `simpleFoam` |
| `t4_np_too_high` | `np 999` | FAILED at the pre-check |
| `t5_to_skip` | none, stopped with `dpq skip` during meshing | SKIPPED |
| `t6_added_late` | none, added while `t1_ok` is running | OK |
| `t7_left_in_queue` | none, `dpq stop` is sent before its turn | still queued |

The script ends with 20 checks, each `PASS` or `FAIL`.

## How to run it

1. Copy `test.conf.example` to `test.conf` and set:
   - `TEMPLATE`: a half-car personal case, used for its scripts and dictionaries;
   - `GEOMETRY`: a folder with the 19 `.obj` files for `constant/triSurface_0deg`;
   - `NTFY_TOPIC`: an ntfy topic to receive the notifications of the test, or leave it empty.
2. Run, as a normal user:

   ```bash
   bash test/run_test.sh
   ```

The number of cores is the number of physical cores, at most 8. To choose it: `bash test/run_test.sh 6`.

Leave the terminal open until `RESULT` is printed. `Ctrl+C` stops the test and the queue.

Measured duration: 19 minutes with 6 cores, 36 minutes with 2 cores. 15 GB of free disk are needed.

## What it leaves behind

- `test/reports/<date>_<time>/`: `report.txt` with the outcome of every check, the queue log and the environment, plus the tail of every OpenFOAM log of every case.
- `~/dpq_test/`: about 750 MB of geometry and one `run_<date>_<time>/` folder per test, about 5 GB each. Delete it when the tests are over.

Neither is tracked by git.
