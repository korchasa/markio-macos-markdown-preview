/**
 * `deno task viewbench` — what one document costs the Mac apps that open it,
 * this one and any other.
 *
 * Different question from `deno task bench`, which measures the parser in
 * process with no window involved. This one drives finished applications from
 * the outside, so a number about Markio beside a number about another viewer
 * came from the same procedure.
 *
 *     deno task viewbench docs <dir>          write the test documents
 *     deno task viewbench <plan.json> [out]   measure
 *
 * Release build only: a debug binary samples slowly enough to blur the very
 * intervals being measured.
 */

import { fail, run, section } from "./lib.ts";

async function main(): Promise<void> {
  const [first, ...rest] = Deno.args;

  if (!first) {
    fail(
      "usage: deno task viewbench docs <dir>\n" +
        "       deno task viewbench <plan.json> [out.json]\n" +
        "       see documents/viewbench.md",
    );
  }

  if (first === "docs") {
    const directory = rest[0];
    if (!directory) fail("usage: deno task viewbench docs <dir>");
    await writeDocuments(directory);
    return;
  }

  section("Building (release)");
  await run("swift", {
    args: ["build", "-c", "release", "--product", "markio-viewbench"],
  });

  section("Measuring");
  await run(".build/release/markio-viewbench", { args: [first, ...rest] });
}

/**
 * The documents every subject is asked to open.
 *
 * Shape matters more than size here. A wall of prose would ask nothing of the
 * part that separates these apps, so each document carries what a tool actually
 * writes: front matter, a heading tree, tables, fenced code, eight Mermaid
 * diagrams, a display formula and a terminal log with real escape bytes in it.
 * The diagram count stays the same as the size grows — a longer report has more
 * prose, not more flowcharts — so every subject draws the same eight.
 */
async function writeDocuments(directory: string): Promise<void> {
  await Deno.mkdir(directory, { recursive: true });
  const sizes: Array<[string, number]> = [
    ["warmup.md", 0.02],
    ["doc-1mb.md", 1],
    ["doc-8mb.md", 8],
    ["doc-32mb.md", 32],
  ];
  for (const [name, megabytes] of sizes) {
    const path = `${directory}/${name}`;
    const text = document(megabytes * 1024 * 1024);
    await Deno.writeTextFile(path, text);
    section(`${path} — ${(new TextEncoder().encode(text).length / 1048576).toFixed(2)} MB`);
  }
}

const WORDS =
  ("ledger service monolith queue payout checkout migration rollout cutover invariant idempotent " +
    "shard replica backfill throughput latency retry consumer producer boundary contract schema " +
    "column index transaction rollback snapshot audit reconcile settlement balance posting entry")
    .split(" ");

const DIAGRAMS = [
  "flowchart LR\n    A[Checkout] --> B[Monolith]\n    B --> C[(Ledger tables)]\n" +
  "    B --> D[Payout worker]\n    D --> C\n    C --> E{Reconciled?}\n" +
  "    E -->|yes| F[Settle]\n    E -->|no| G[Alert on-call]",
  "sequenceDiagram\n    participant C as Checkout\n    participant L as Ledger\n" +
  "    participant P as Payout\n    C->>L: POST /entries\n    L-->>C: 201 entry_id\n" +
  "    C->>P: enqueue(entry_id)\n    P->>L: GET /entries\n    L-->>P: entry\n    P->>P: settle",
  "stateDiagram-v2\n    [*] --> Draft\n    Draft --> Posted: submit\n" +
  "    Posted --> Settled: reconcile\n    Posted --> Reversed: dispute\n" +
  "    Settled --> [*]\n    Reversed --> [*]",
  "erDiagram\n    ACCOUNT ||--o{ ENTRY : holds\n    ENTRY }o--|| BATCH : grouped_in\n" +
  "    BATCH ||--o{ PAYOUT : produces\n    ACCOUNT {\n        uuid id\n" +
  "        string currency\n        int balance_minor\n    }",
  "classDiagram\n    class Ledger {\n        +post(Entry) EntryId\n" +
  "        +reverse(EntryId) void\n    }\n    class Entry\n    class Batch\n" +
  "    Ledger --> Entry\n    Batch o-- Entry",
  "gantt\n    title Cutover\n    dateFormat YYYY-MM-DD\n    section Prepare\n" +
  "    Backfill :a1, 2026-08-01, 6d\n    Dual write :a2, after a1, 5d\n" +
  "    section Switch\n    Read from new :b1, after a2, 3d",
  "mindmap\n  root((Ledger))\n    Writes\n      Direct call sites\n      Queue consumer\n" +
  "    Reads\n      Reports\n      Reconciliation\n    Risks\n      Double posting",
  'pie title Call sites by origin\n    "Ledger service" : 41\n    "Checkout direct" : 4\n' +
  '    "Payout worker" : 9\n    "Reports" : 12',
];

const SNIPPETS: Array<[string, string]> = [
  [
    "swift",
    "func post(_ entry: Entry) throws -> EntryId {\n" +
    "    guard entry.amountMinor != 0 else { throw LedgerError.zeroAmount }\n" +
    "    return try store.append(entry)\n}",
  ],
  [
    "python",
    "def reconcile(batch_id: str) -> Report:\n    entries = store.entries(batch_id)\n" +
    "    total = sum(e.amount_minor for e in entries)\n" +
    "    return Report(batch_id=batch_id, total=total, ok=total == 0)",
  ],
  [
    "sql",
    "SELECT account_id, SUM(amount_minor) AS balance\nFROM ledger_entries\n" +
    "WHERE posted_at >= now() - interval '24 hours'\nGROUP BY account_id;",
  ],
];

/** A deterministic generator, so two runs compare the same bytes. */
function makeRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 4294967296;
  };
}

function document(targetBytes: number): string {
  const random = makeRandom(20260815);
  const pick = <T>(items: T[]): T => items[Math.floor(random() * items.length)];

  const parts: string[] = [
    "---\ntask: extract the ledger from the monolith\nrun: 2026-08-15 09:14 -> 09:51\n" +
    "files read: 214\nfiles changed: 18\nstatus: needs your review\n---\n\n" +
    "# Refactor report — extracting the ledger\n\n" +
    "I read 214 files and changed 18 of them. The ledger now runs as its own\n" +
    "service, and the monolith calls it instead of writing the tables directly.\n\n",
  ];

  DIAGRAMS.forEach((diagram, index) => {
    parts.push(`## Diagram ${index + 1}\n\n\`\`\`mermaid\n${diagram}\n\`\`\`\n\n`);
  });

  parts.push(
    "## What the numbers say\n\nThe settlement error stays bounded:\n\n" +
      "$$\n\\sum_{i=1}^{n} \\frac{a_i - b_i}{\\sigma_i} \\leq \\varepsilon\n$$\n\n",
  );

  // Real escape bytes: written as literal text the block renders as the
  // characters "[32m" instead of a green word, and the colour claim is then
  // being measured against something that never happened.
  parts.push(
    "## Test run\n\n```ansi\n" +
      "\x1b[32mPASS\x1b[0m  LedgerTests.testDoublePostingRejected\n" +
      "\x1b[32mPASS\x1b[0m  LedgerTests.testReversalRestoresBalance\n" +
      "\x1b[33mSKIP\x1b[0m  LedgerTests.testShardRebalance\n" +
      "\x1b[31mFAIL\x1b[0m  PayoutTests.testRetryAfterTimeout\n" +
      "\x1b[38;5;208m  expected\x1b[0m 3 attempts, got 1\n```\n\n",
  );

  parts.push(
    "## What is left\n\n- [x] Backfill the historical entries\n" +
      "- [x] Dual-write from checkout\n- [ ] Drop the old tables[^1]\n\n" +
      "[^1]: Only after two clean reconciliation runs.\n\n",
  );

  let size = parts.reduce((total, part) => total + part.length, 0);
  let section = 0;
  while (size < targetBytes) {
    section += 1;
    const chunk: string[] = [`## Section ${section} — ${pick(WORDS)} ${pick(WORDS)}\n\n`];
    for (let paragraph = 0; paragraph < 4; paragraph += 1) {
      const words: string[] = [];
      const length = 40 + Math.floor(random() * 50);
      for (let index = 0; index < length; index += 1) {
        const word = pick(WORDS);
        words.push(
          index % 17 === 5 ? `**${word}**` : index % 23 === 7 ? `*${word}*` : word,
        );
      }
      chunk.push(`${words.join(" ")}.\n\n`);
    }
    chunk.push("| Call site | Writes | Owner | Status |\n|---|---:|---|---|\n");
    for (let row = 0; row < 6; row += 1) {
      chunk.push(
        `| \`${pick(WORDS)}/${pick(WORDS)}.swift\` | ${Math.floor(random() * 900)} ` +
          `| ${pick(WORDS)} | ${pick(["migrated", "pending", "blocked"])} |\n`,
      );
    }
    chunk.push("\n");
    const [language, body] = pick(SNIPPETS);
    chunk.push(`\`\`\`${language}\n${body}\n\`\`\`\n\n`);
    const text = chunk.join("");
    parts.push(text);
    size += text.length;
  }
  return parts.join("");
}

if (import.meta.main) await main();
