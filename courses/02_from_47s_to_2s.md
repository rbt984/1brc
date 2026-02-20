# Course 02 — From 47s to 2.7s: Optimizing Step by Step

Generating 10M lines of `city;temperature` to a file. From 47s to 2.7s — **x17.3 speedup** — by fixing one bottleneck at a time.

Machine: macOS, 10 cores (schedulers) | Elixir 1.19.1

---

## The Goal

Generate a file with 10 million lines like this:

```
Tokyo;15.4
Paris;-2.3
Lima;22.1
...
```

Each line: pick a random city from 413 entries, generate a random temperature between avg - 10 and avg + 10, write it to a file.

---

## The Results

```
Naive:        |████████████████████████████████████████████████| 47,808ms
Chunked:      |█████████████|                                   13,641ms
Async stream: |██|                                               2,771ms
```

| Step | Strategy | 10M rows | Speedup vs naive |
|---|---|---|---|
| 1 | Naive — one write per line | 47,808 ms | baseline |
| 2 | Chunked — batch 10K lines per write | 13,641 ms | **x3.5** |
| 3 | Async stream — parallelize across 10 cores | 2,771 ms | **x17.3** |

Each step fixed a different bottleneck. Let's understand each one.

---

## Step 1 — Naive: one write per line

### The code

```elixir
Enum.each(1..count, fn _ ->
  {city, avg} = Enum.random(cities)
  temp = avg - 10.0 + :rand.uniform() * 20.0
  IO.puts(file, "#{city};#{Float.round(temp, 1)}")
end)
```

### What happens

Each iteration does two things:
1. **CPU work**: pick a random city, generate a random temperature, build a string
2. **I/O**: `IO.puts` sends a message to the file's I/O server process, which then performs a **syscall** — a context switch to the OS kernel to write bytes to disk

At 10M rows, that's **10,000,000 syscalls**. As we saw in [Course 01](./01_knowledge_foundation.md#whats-a-syscall), each syscall costs ~3-5 μs of fixed overhead regardless of data size. We know this is going to be expensive — but how expensive exactly? Let's measure.

### The numbers

| Metric | Value |
|---|---|
| Syscalls | 10,000,000 |
| Total time | 47,808 ms |
| Time per line | ~4.8 μs |

We know each line costs ~4.8 μs total, but we can't tell how much is CPU work and how much is I/O overhead — not from this step alone. We need to remove the I/O bottleneck first to find out. That's what Step 2 does.

---

## Step 2 — Chunked: batch 10K lines per write

### The idea

Instead of writing each line to disk immediately, collect 10,000 lines in memory first, then write them all in a single syscall.

### The code

```elixir
1..count
|> Stream.map(fn _ ->
  {city, avg} = Enum.random(cities)
  temp = avg - 10.0 + :rand.uniform() * 20.0
  "#{city};#{Float.round(temp, 1)}\n"
end)
|> Stream.chunk_every(10_000)
|> Enum.each(&IO.write(file, &1))
```

### What changed

Three things are different:

**1. `Stream.map` instead of `Enum.each` + `IO.puts`**

We separate **generation** from **writing**. Each line is built as a string and returned — not written immediately.

**2. `Stream.chunk_every(10_000)`**

Groups lines into batches of 10,000. This is lazy — it doesn't build all batches at once, it accumulates one batch, yields it, then starts the next.

**3. `IO.write(file, &1)` with a list of strings**

Note: each line is still built as a full binary via string interpolation (`"#{city};#{Float.round(temp, 1)}\n"`). But `IO.write` receives the **list of 10,000 strings** and writes them all in **one syscall**, without concatenating them into a single giant string first. This is where iolists come in:

### What's an iolist?

An iolist is a list (possibly nested) of strings and integers that can be written as a flat byte sequence. An iolist lets the BEAM write without concatenating everything into one big binary first — the runtime/file driver can write it efficiently (often using vectored writes like `writev`).

```elixir
# These produce the same output, but very different performance:

# String concat — copies and allocates at each step
result = "Tokyo" <> ";" <> "15.4" <> "\n"  # 3 copies, 3 allocations

# Iolist — no copying, just a list of references
result = ["Tokyo", ";", "15.4", "\n"]  # 0 copies, 1 list allocation
```

When you pass an iolist to `IO.write`, the BEAM doesn't need to build a single contiguous binary. It can walk the list and write the pieces efficiently without copying them together first.

```
String concat:  "Tokyo" + ";" → "Tokyo;" + "15.4" → "Tokyo;15.4" + "\n" → "Tokyo;15.4\n"
                copy 1          copy 2               copy 3
                5 bytes         10 bytes             14 bytes
                Total: 29 bytes copied

Iolist:         ["Tokyo", ";", "15.4", "\n"] → file driver → disk
                0 bytes copied into a single binary
```

At 10K lines per batch, avoiding that concatenation adds up.

### The numbers

| Metric | Naive | Chunked | Improvement |
|---|---|---|---|
| Syscalls | 10,000,000 | 1,000 | **10,000x fewer** |
| Time | 47,808 ms | 13,641 ms | **x3.5 faster** |

### Why only x3.5 and not x10,000?

We eliminated 99.99% of syscalls, but only got x3.5 faster. Why?

Because **the per-write overhead was only part of the cost**. Batching eliminated the fixed cost of 10M individual I/O server messages + syscalls. But the remaining 13.6 seconds is still a mix of CPU work (random, float math, string building) + the actual cost of writing ~150 MB to disk (kernel buffer copies, page cache). What we can say:

```
Step 1:  47,808 ms   dominated by per-line I/O overhead (10M messages + syscalls)
Step 2:  13,641 ms   dominated by CPU work + memory + bulk I/O
────────────────────
Saved:   34,167 ms   by removing per-write fixed costs
```

The bulk I/O cost (copying ~150 MB to kernel buffers) still exists in Step 2, but it's now a small fraction compared to the CPU work of generating 10M lines. The bottleneck has shifted to **CPU** — still running on a **single core**.

Our 10 cores sit idle. Only 1 is doing work. This brings us to step 3.

---

## Step 3 — Async stream: parallelize across all cores

### The idea

The CPU work (random city, random temp, string building) is **independent per line** — line 5 doesn't depend on line 4. As we covered in [Course 01 — CPU & Concurrency](./01_knowledge_foundation.md#part-4-cpu--concurrency), the BEAM starts one scheduler per CPU core, but a single process only uses one. To use all 10 cores, we need to split the work across multiple processes.

This is exactly what `Task.async_stream` does — it's the [Level 3 scaling pattern](./01_knowledge_foundation.md#scaling-patterns) we learned about.

### The code

```elixir
1..count
|> Stream.chunk_every(10_000)
|> Task.async_stream(fn chunk ->
  Enum.map(chunk, fn _ ->
    {city, avg} = Enum.random(cities)
    temp = avg - 10.0 + :rand.uniform() * 20.0
    "#{city};#{Float.round(temp, 1)}\n"
  end)
end, max_concurrency: System.schedulers_online(),
     ordered: false, timeout: :infinity)
|> Enum.each(fn {:ok, lines} -> IO.write(file, lines) end)
```

### What changed

`Task.async_stream` distributes chunks across 10 BEAM processes, each running on a different scheduler (= CPU core):

```
Main process creates chunks of 10K indices
    │
    ├──→ Task 1 (Core 1): generate 10K lines  ──→ returns iolist
    ├──→ Task 2 (Core 2): generate 10K lines  ──→ returns iolist
    ├──→ Task 3 (Core 3): generate 10K lines  ──→ returns iolist
    │    ... up to 10 concurrent tasks ...
    │
    └── Main process: receives iolists, writes to file (sequential)
```

**Generation is parallel, writing is sequential.** Each core builds its chunk independently. Results flow back to the main process, which writes them one at a time. The file is a single resource — as we saw in Course 01, [I/O-bound work on a single target can't be parallelized](./01_knowledge_foundation.md#when-concurrency-helps-and-when-it-doesnt).

### The numbers

| Metric | Chunked | Async | Improvement |
|---|---|---|---|
| Cores used | 1 | 10 | **10x parallelism** |
| Time | 13,641 ms | 2,771 ms | **x4.9 faster** |

### Why x4.9 and not x10?

Three sources of overhead:

1. **Task spawning**: creating and coordinating 1,000 tasks (10M / 10K per chunk) has a cost
2. **Scheduler coordination**: the BEAM must distribute work across 10 schedulers, handle message passing back to the main process
3. **Sequential write**: the main process still writes one chunk at a time — this serialization step can't be parallelized

In practice, you get **~50-70% of theoretical linear speedup** with `Task.async_stream`. Our x4.9 on 10 cores = ~49% efficiency, which is typical. The [CPU demo](./01_knowledge_foundation.md#part-5-hands-on-demo--see-your-cores-light-up) shows this plateau visually.

---

## The Full Picture

### What we fixed at each step

| Step | Bottleneck | Fix | What we learned |
|---|---|---|---|
| 1 → 2 | I/O: 10M syscalls | Batch into 1K writes | Syscalls have fixed overhead — reduce their count |
| 2 → 3 | CPU: single core | Parallelize across 10 cores | Independent work can be distributed |

### Peeling the onion

Each optimization **revealed the next bottleneck**:

```
Step 1: 47,808 ms
        ├── dominated by per-line I/O overhead     ← we fixed this
        └── CPU work + bulk I/O buried underneath

Step 2: 13,641 ms
        ├── per-line I/O overhead: gone             ← solved
        └── dominated by CPU work (single core)     ← we fixed this

Step 3: 2,771 ms
        ├── CPU work spread across 10 cores          ← parallelized
        └── coordination overhead (task spawning, message passing)
```

This pattern is universal: **the bottleneck shifts**. You can't know what's slow until you fix what's slowest. This is why you always measure first, optimize the top bottleneck, then measure again.

### Combined speedup

```
Naive:        |████████████████████████████████████████████████| 47,808ms
Chunked:      |█████████████|                                   13,641ms
Async stream: |██|                                               2,771ms
```

| Optimization | What it fixes | Speedup |
|---|---|---|
| Chunking (batch I/O) | Eliminates 99.99% of syscalls | x3.5 |
| Async stream (parallelism) | Uses all 10 CPU cores | x4.9 |
| **Combined** | **Both** | **x17.3** |

The speedups **multiply**: x3.5 × x4.9 ≈ x17.3. Each optimization is independent — they fix different bottlenecks.

---

## Bonus: Data Storage — Compile Time vs Runtime

We also benchmarked how we store and access the 413 cities map.

### The question

The city data (`%{"Tokyo" => 15.4, "Paris" => 12.3, ...}`) doesn't change. Should we read it from a file at runtime, or embed it in the code?

### Module attribute — compile-time embedding

```elixir
defmodule Data do
  @cities %{Tokyo: 15.4, Paris: 12.3, ...}
  def cities, do: @cities
end
```

`@cities` is evaluated at **compile time**. The map is built once, embedded in the BEAM bytecode. `Data.cities()` avoids file I/O and parsing — but it's not free: the BEAM may still copy the data into the calling process's heap on each call. For best performance, call it once and reuse: `cities = Data.cities()` outside the loop.

### File read — runtime parsing

```elixir
defmodule DataFile do
  def cities do
    "./priv/cities.json"
    |> File.read!()        # syscall: read ~15KB from disk
    |> parse_json()        # split into 413 entries, parse each float
  end
end
```

Every call: 1 file read + 413 string operations + build a new map from scratch.

### The numbers

| | Module attribute | File read | Wasted |
|---|---|---|---|
| 1M calls | 610 ms | 1,008 ms | **398 ms** on I/O + parsing |
| 10M calls | 6,537 ms | 10,996 ms | **4,459 ms** on I/O + parsing |

**x1.7 slower** — a constant penalty on every call. At 10M iterations, that's 4.5 seconds spent rebuilding data that never changes.

### The lesson

If data is **known at compile time and doesn't change**, embed it with a module attribute. Reserve file reads for data that genuinely changes between runs or comes from external sources.

---

## Key Takeaways

### The optimization mindset

1. **Measure first** — don't guess where the bottleneck is
2. **Fix the biggest one** — the top bottleneck hides everything below it
3. **Measure again** — the bottleneck shifts after each fix
4. **Repeat** — until you hit acceptable performance or diminishing returns

### The three layers we hit

```
Layer 1: I/O overhead      — how many times you talk to the kernel
Layer 2: CPU utilization    — how many cores are doing useful work
Layer 3: Per-operation cost — how many nanoseconds each operation takes
```

These layers exist in almost every data-intensive program. The order may differ, but the approach is the same.

### The techniques

| Technique | What it does | When to use |
|---|---|---|
| **Iolists** | Avoid string copying — pass lists of pointers to the kernel | Any I/O-heavy code |
| **Stream.chunk_every** | Batch operations to reduce syscalls | Writing/reading in loops |
| **Task.async_stream** | Distribute independent work across cores | CPU-bound, parallelizable work |
| **Module attributes** | Embed constant data at compile time | Static config, lookup tables |
| **:timer.tc** | Measure execution time in microseconds | Always — before and after each change |

### Tools we used

| Tool | What it does |
|---|---|
| `:timer.tc/1` | Measure any block in microseconds |
| `System.monotonic_time/1` | Wall clock for total elapsed time |
| `:counters` | Atomic counter for tracking progress across tasks |
| `System.schedulers_online/0` | Check how many CPU cores are available |
| `:observer.start/0` | Visual dashboard for scheduler (core) utilization |

---

## How to Reproduce

```bash
# Step 1 — Naive
git checkout bench/naive        && mix run lib/create_measurements.exs -c 10000000

# Step 2 — Chunked
git checkout bench/chunked      && mix run lib/create_measurements.exs -c 10000000

# Step 3 — Async stream
git checkout bench/async-stream && mix run lib/create_measurements.exs -c 10000000

# Data access benchmark
mix run scripts/bench_data_access.exs -c 10000000
```

---

**Previous**: [Course 01 — Knowledge Foundation](./01_knowledge_foundation.md)
