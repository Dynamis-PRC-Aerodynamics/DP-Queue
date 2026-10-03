# `dpq`

Run queue for the half-car personal case (`DP-case-half-car-personal-case`) on OpenFOAM v2512.

You add cases to a list. `dpq` runs them one after the other, checks every step, sends a notification when a case starts, ends or fails, and goes on with the next case when one fails. It is meant for a machine that several people use for their runs.

`dpq` runs the same commands as `runAll`, with the same log names, but it does not call `runAll`: that script asks two questions from the keyboard and keeps going when a command fails.

---

## Installation

On the machine that runs the simulations (Ubuntu, or Ubuntu inside WSL), with OpenFOAM v2512 already installed:

```bash
git clone <address of this repository> ~/OpenFOAM/dpq
bash ~/OpenFOAM/dpq/install.sh
```

`install.sh` does three things and prints what it did:

- creates `dpq.conf`, the configuration of this machine, from `dpq.conf.example`;
- picks a random name for the notification channel and writes it in `dpq.conf`;
- adds the `dpq` command to `~/.bashrc`.

Open a new terminal afterwards, so that the `dpq` command is available.

`dpq.conf` and the `state/` folder are not tracked by git: what is specific to a machine never ends up in the repository.

To update: `git pull` inside `~/OpenFOAM/dpq`. The configuration and the queue are kept.

---

## Notifications on the phone

The notifications travel through [ntfy](https://ntfy.sh), a free push notification service that needs no account. A channel is called a *topic*, and it is only a name: whoever subscribes to that name receives the messages.

1. Install the ntfy app on the phone (Android or iOS).
2. In the app, subscribe to the topic that `install.sh` printed. It is also in `dpq.conf`, on the `NTFY_TOPIC` line.
3. On the machine, run `dpq test-notify`: a test message must reach the phone.

**The topic name works like a password.** Anyone who knows it reads the messages, which contain case names, paths and pieces of log. Share it only with the people who must follow the queue, and never commit it. To change it, edit `NTFY_TOPIC` in `dpq.conf` and subscribe to the new name.

Messages sent:

| When | Title | Content |
|---|---|---|
| a case starts | `started <case>` | owner, cores, cases still queued |
| a case ends well | `DONE <case>` | duration by phase, iterations reached, warnings |
| a case fails | `FAILED <case>` | failed step, reason, list of all the steps, end of the log |
| a case is stopped by hand | `SKIPPED <case>` | same layout as a failure |
| the queue is over or stopped | `queue finished`, `queue stopped` | outcome of every case of the session |
| the disk is almost full | `queue PAUSED` | free space and what to do |

A failure looks like this. Every step of the run is listed with its outcome, so the point where it stopped is visible at a glance:

```
[PC-name] dpq: FAILED DP18_RH30
Owner: Mario
Failed at: snappyHexMesh (step 6 of 22) after 4m12s
Reason: FOAM FATAL ERROR in the log (exit code 1)
Next: DP18_RH35

✓ done   ✗ failed   · not run
MESH
✓ preProcess
✓ surfaceFeatureExtract
✓ blockMesh
✓ decomposePar (block mesh)
✓ checkMesh (block mesh)
✗ snappyHexMesh
· checkMesh
· reconstructParMesh
· reconstructPar (mesh fields)
· patchSummary
SOLVE
· decomposePar
· renumberMesh
· potentialFoam
· simpleFoam
POST
· postProcess (vorticity wallShearStress yPlus)
· postProcess (totalPressureIncompressible)
· postProcess (mag(vorticity))
· generate_surfaces.py
· postProcess (surfaces)
· reconstructPar
· reconstructPar (phi)
· final check

Log: /home/.../DP18_RH30/log_mesh/05_snappyHexMesh
--- end of the log ---
(last lines of that log)
```

Other channels can be switched on in `dpq.conf`, alone or together with ntfy:

- **Desktop pop-up** (`NOTIFY_DESKTOP=1`): needs a graphical session open on the machine. It does not work on WSL.
- **Telegram**: create a bot with `@BotFather` and put its token in `TELEGRAM_TOKEN`; send the bot a message, open `https://api.telegram.org/bot<TOKEN>/getUpdates` and put `chat.id` in `TELEGRAM_CHAT_ID`.
- **E-mail**: fill `MAIL_TO`, `SMTP_USER` and `SMTP_PASS`. With Gmail the password is an "app password", not the account password.

A channel that fails is written in the queue log and never stops the queue. Only ntfy has been tested on a real run; pop-up, Telegram and e-mail have been tested with simulated tools.

---

## Use

```bash
dpq add DP18_RH30 DP18_RH35     # cases inside run/, or any path
dpq add -o Mario DP18_RH40      # -o: who the run belongs to, shown in the notifications
dpq start                       # start the queue
dpq status                      # running case, current step, iteration, queue
```

| Command | What it does |
|---|---|
| `dpq add [-o owner] <case> ...` | Adds cases at the end of the queue. Works while the queue is running. |
| `dpq start` | Starts the queue in the background. |
| `dpq start --foreground` | Same, but attached to the terminal. `Ctrl+C` stops it. |
| `dpq status` | Running case, step, solver iteration, queued cases. |
| `dpq remove <name \| position>` | Takes a case out of the queue. |
| `dpq skip` | Stops the running case and goes on with the next one. |
| `dpq stop` | Stops the queue when the running case is over. |
| `dpq abort` | Stops the running case and the queue now. |
| `dpq history [N]` | Last finished cases with their outcome. |
| `dpq log [-f]` | Queue log. |
| `dpq test-notify` | Sends a test message on every configured channel. |

The queue ends when there are no cases left. Cases added afterwards wait for the next `dpq start`.

**A queued case is cleaned before it runs**: mesh, time folders, logs and `postProcessing` are deleted exactly as `runAll` does, without asking. `dpq add` prints a warning when the case already holds a mesh or results.

All the cases run under the user who started the queue. People who share the machine add their cases with that same user and mark them with `-o`.

---

## When a case counts as failed

Every command is checked as soon as it ends. A step fails when:

- its exit code is not 0 (the exit code is the number a program returns when it closes: 0 means it ended normally);
- its log contains `FOAM FATAL ERROR` or `FOAM FATAL IO ERROR`, the message OpenFOAM prints when it stops on an error;
- for `snappyHexMesh`, `potentialFoam` and `simpleFoam`, the log does not finish with `End`, the line OpenFOAM writes only when it reaches the end.

After the last step a final check looks for a reconstructed time folder with `U` and `p`, and for a non-empty `postProcessing`.

On the first failed step the case stops there, the notification goes out and the queue starts the next case. The failed case is left as it is. If the solver had already finished, the notification says so: fix the problem and run `./runPostProcess` in the case.

Three findings are reported as warnings in the final notification and in the queue log, and do not stop the case:

- a final `checkMesh` with failed checks (set `STOP_ON_MESH_CHECK_FAIL=1` to stop the case instead);
- a `snappyHexMesh` that ends with illegal faces;
- a library that `simpleFoam` could not load, such as `forceCoeffsModified.so`. OpenFOAM only prints a warning and goes on, so the run ends without the outputs of that library. The library has to be compiled on the machine, for the user who runs the queue.

Before a case starts:

- **Disk space.** Below `MIN_FREE_GB` the queue pauses and the case stays first in line. Free some space and run `dpq start`.
- **Cores.** A case whose `np` is larger than the physical cores of the machine fails at once, because `mpirun` would refuse it. Set `NP` in `dpq.conf` to impose the same value on every case.

---

## Requirements on the case

`dpq add` accepts a folder that holds `initialConditions` with a readable `np`, `orig0/`, and `system/` with `controlDict`, `blockMeshDict`, `snappyHexMeshDict` and `decomposeParDict`.

`runPreProcess` is called when present. `generate_surfaces.py` is taken from `postProcessor/` in the case, or from `AEROTOOLS_DIR` when the case has no such folder.

The `.obj` files in `constant/triSurface_0deg` must be real files, not symbolic links: the pre-processor copies that folder with `cp -a` and rewrites the copies in place, so a symbolic link makes it overwrite the file it points to. `dpq` refuses a case with symbolic links there.

The scripts of the case must have Unix line endings (LF). A case that went through Windows may have CRLF: `dpq` refuses it and asks for `dos2unix`.

---

## WSL

`dpq` runs inside WSL as on Ubuntu, with three differences:

- **Keep one terminal open while the queue runs.** When the last WSL terminal closes, Windows may shut the Linux environment down, and the queue with it. On Ubuntu the queue survives the terminal.
- **No desktop pop-up.** `install.sh` switches it off.
- **Cores.** WSL may show fewer physical cores than the machine has, and `np` is checked against what WSL shows. `MPI_OPTS="--use-hwthread-cpus"` in `dpq.conf` allows one process per hardware thread.

---

## Files

Everything `dpq` writes of its own goes in `state/`, next to the script:

| File | Content |
|---|---|
| `queue.tsv` | Queued cases: path, owner, time added. |
| `history.tsv` | Finished cases: time, outcome, path, owner, seconds, step, reason. |
| `worker.log` | Every step of every case, every warning and every notification sent. |
| `current.*` | Case and step running now. |

If the machine reboots during a run, the next `dpq start` reports that case as interrupted and goes on with the queue. The interrupted case is not restarted: add it again if needed.

---

## Maintenance

The commands of the run are in the `pipeline` function of `dpq`, and the list shown in the notifications is `STEP_PLAN`, at the top of the same file. If `runAll` changes, update both.

`test/` holds a kit that runs the queue against real OpenFOAM with small cases and checks every outcome: see `test/README.md`. Run it after any change to `dpq`.
