# viewbench — comparing viewers on the same document

`deno task bench` measures this parser in process: no window, no other app, no
operating system in the way. It cannot say anything about another program.
`deno task viewbench` answers the other question — what one document costs the
Mac applications that open it, this one and any other — by driving finished
applications from the outside, so a number about Markio beside a number about
another viewer came from the same procedure.

```bash
deno task viewbench docs /tmp/viewbench        # write the test documents
deno task viewbench plan.json report.json      # measure
```

## The plan

```json
{
  "subjects": [
    { "name": "Markio", "app": "/path/to/Markio.app" },
    { "name": "Other", "app": "/Applications/Other.app" }
  ],
  "documents": [
    { "name": "1mb", "path": "/tmp/viewbench/doc-1mb.md",
      "readyText": "extracting the ledger" }
  ],
  "warmup": "/tmp/viewbench/warmup.md",
  "rounds": 7,
  "probes": ["cpu-idle", "ax-ready"],
  "cooldownSeconds": 3
}
```

`readyText` is a line from the first screenful of the document. The `ax-ready`
probe waits for it to appear in the app's accessibility tree, which is how a
drawn document is told from a window that merely exists.

## What it measures

- **CPU time** — the work the document forced on the app, summed over its whole
  process tree. This is the number to trust when the machine is not perfectly
  quiet: contention stretches elapsed time without changing work done.
- **Peak footprint** — `phys_footprint`, the figure Activity Monitor shows, over
  the same tree. Resident size is not used: it counts shared pages once per
  process, so an app with three helpers looks heavier than it is.
- **Elapsed time**, under whichever probe was asked for.

## The two probes, and why there are two

`cpu-idle` needs no permission and measures the whole cost, but it can only see
work large enough to register: a document that costs a few milliseconds is
reported as **below floor**, with its CPU time, and no duration at all. That is
not a failure — it is the honest answer, and the harness never reports its own
give-up window as if it were the app's time.

`ax-ready` measures what a reader waits for. It needs Accessibility permission
for the terminal running the command, granted in System Settings under Privacy
& Security. It also has a cost that must be declared: attaching an
accessibility client makes a web view build an accessibility tree it would not
otherwise build, which is work a real reader never pays for. So the two probes
are run as separate passes and never combined into one number.

## What makes a reading admissible

A run is thrown away, not averaged in, when:

- the machine spent more than 15% of its capacity on other work during it;
- `CPU_Speed_Limit` was below 100, meaning the machine was throttling;
- the probe never fired inside the timeout.

Two things are deliberately not counted as other work. The harness's own cost
is part of the method and is paid identically for every subject, so charging it
as noise would have the expensive `ax-ready` probe rejecting the readings it
had just taken. And the busy-machine test is skipped below a second: the kernel
keeps its CPU totals in hundredths, so over a tenth of a second any passing
system activity looks like most of the machine.

The report carries the count of rejected runs beside every figure, along with
the median, the fastest run and the median absolute deviation. A benchmark that
prints one number and not its spread is asking to be believed rather than
checked.

## Fairness controls

Each is here because leaving it out biases the comparison:

- **Subjects are interleaved and shuffled.** All the runs of one app in a row
  would confound the app with whatever the machine was doing that hour.
- **A warmup document is opened first,** so launching the app is paid for
  outside the measurement.
- **The subject is never brought to the front,** because an hour of runs that
  each seize the keyboard makes the machine unusable while the benchmark is
  going. App Nap is switched off for each subject instead, its window is raised
  through accessibility — which, unlike activating the app, does not move the
  keyboard — and it is given the same position and size as every other subject,
  since how much of a document gets laid out depends on how big the window is.

  What that cannot fix is refused rather than believed. A window nothing can
  see is sent no display cycles, so the document is never laid out and the app
  reads as unable to open it; a run whose subject stayed more than 80% covered
  for three seconds after being raised is thrown out. A subject that has not
  shown a window *yet* is not thrown out — some take twenty seconds over a
  large document, and that is the reading, not a fault.

  Two states of the machine make every run impossible, and both are named
  rather than left to look like broken applications. **A locked screen** draws
  nothing at all; the benchmark waits for it, between runs as well as at the
  start, so a machine that locks itself halfway through an hour resumes instead
  of filling the report with zeroes. **A full-screen application** owns its
  Space outright, putting every subject window on another one, and the run
  stops before it starts with a note to leave full screen.
- **Saved application state is cleared,** and for a bundle that can be modified
  the harness runs a copy under a fresh bundle identifier, which the system has
  never seen and has nothing to restore into. Markio restores its previous
  session on purpose, and nothing on disk shows the restored set, so without
  this a run that looks like one document silently carries the twenty before it.
- **The bundle that launched is verified against the bundle that was asked
  for.** `open -a <path>` is a request, not a guarantee: when several copies
  share an identifier the system may bring a different one forward. The first
  run of this harness measured an old build in `/Applications` and reported a
  document that had never been opened.

## Before a run that is going to be quoted

- Mains power. On battery macOS trades speed for charge and the report says so.
- An unlocked screen for the whole hour, on an ordinary desktop rather than a
  full-screen app. Turn off the screen saver and display sleep first; the
  benchmark waits rather than lying, but a run that waits is a run not taken.
- Quit other applications, browsers first — every rejected run is a run wasted.
- Turn off Wi-Fi if any subject checks for updates on launch.
- Let the machine cool: check that the first runs are not rejected for
  throttling.

## When a probe finds nothing

```bash
.build/release/markio-viewbench dump <pid>
```

prints a running app's accessibility tree. A probe that cannot see and an app
that says nothing look identical from outside, and only the tree tells them
apart. It is what showed that this app's own document elements were answering
neither their role nor their text, because they were being rebuilt inside every
query and released before the next one arrived.

`MARKIO_VIEWBENCH_TRACE=1` prints every sample with the processes being charged
to the subject. A run that never ends looks the same from outside as a slow app,
and that listing is what tells the two apart.
