# Benchmarks — Optimizing Elixir I/O at Scale

Machine: macOS, 10 schedulers (cores) | Elixir 1.19.1

---

## Part 1: Write Strategy — from 47s to 2.7s

Goal: generate 10M lines of `city;temperature` and write them to a file.

### Results

| Step | Strategy | 1M rows | 10M rows | Speedup vs naive |
|---|---|---|---|---|
| 1 | Naive | 3,869ms | 47,808ms | baseline |
| 2 | Chunked | 1,325ms | 13,641ms | **x3.5** |
| 3 | Async stream | 277ms | 2,771ms | **x17.3** |

### Step 1 — Naive: one write per line

```elixir
Enum.each(1..count, fn _ ->
  {city, avg} = Enum.random(cities)
  temp = avg - 10.0 + :rand.uniform() * 20.0
  IO.puts(file, "#{city};#{Float.round(temp, 1)}")
end)
```

**What happens:** every iteration calls `IO.puts` which triggers a syscall to the OS kernel. At 10M rows, that's **10,000,000 syscalls**.

**Why it's slow:** each syscall has overhead — context switch from user space to kernel space, buffer flush, return. The actual string generation is fast, but we're bottlenecked by I/O round-trips.

| Metric | Value |
|---|---|
| Syscalls | 10,000,000 |
| Time per syscall | ~4.7us |
| Total | 47,808ms |

### Step 2 — Chunked: batch 10k lines per write

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

**What changed:**
- `Stream.chunk_every(10_000)` — accumulates 10k lines lazily before writing
- `IO.write(file, &1)` — writes an **iolist** (list of strings), the BEAM sends it to the OS in one syscall without concatenating

**Why it's faster:** we reduced syscalls from 10M to 1,000 (10M / 10k). Each write is larger but the overhead per syscall is the same — so we eliminated 99.99% of the I/O overhead.

| Metric | Naive | Chunked | Improvement |
|---|---|---|---|
| Syscalls | 10,000,000 | 1,000 | **10,000x fewer** |
| Time | 47,808ms | 13,641ms | **x3.5 faster** |

**Why only x3.5 and not x10,000?** Because syscall overhead was only part of the cost. The remaining time is CPU-bound: `Enum.random`, `:rand.uniform`, `Float.round`, string interpolation — all still running on a **single core**.

### Step 3 — Async stream: parallelize across all cores

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

**What changed:**
- `Task.async_stream` — distributes chunks across 10 BEAM schedulers (= 10 CPU cores)
- `ordered: false` — don't wait for chunk 1 to finish before writing chunk 2's result
- `timeout: :infinity` — no task timeout for large datasets
- Generation is parallel, writing is sequential (results flow back to the main process in order of completion)

**Why it's faster:** the CPU-bound work (random, float math, string building) now runs on **10 cores simultaneously** instead of 1.

| Metric | Chunked | Async | Improvement |
|---|---|---|---|
| Cores used | 1 | 10 | **10x parallelism** |
| Time | 13,641ms | 2,771ms | **x4.9 faster** |

**Why x4.9 and not x10?** Task spawning overhead, scheduler coordination, and the sequential write step consume some of the parallel gains. In practice, you get ~50-70% of theoretical linear speedup.

### Full picture at 10M rows

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

---

## Part 2: Data Storage — compile time vs runtime

Goal: measure the cost of how we store and access the 413 cities map.

### Results

| Strategy | 1M iterations | 10M iterations | Ratio |
|---|---|---|---|
| Module attribute (`@city`) | 610ms | 6,537ms | x1.0 (baseline) |
| File read (JSON parse) | 1,008ms | 10,996ms | **x1.7 slower** |

### Module attribute — zero runtime cost

```elixir
defmodule Data do
  @city %{Tokyo: 15.4, Paris: 12.3, ...}
  def city, do: @city
end
```

**How it works:** `@city` is evaluated at **compile time**. The map is built once and embedded in the BEAM bytecode. `Data.city()` avoids file I/O and parsing, but the BEAM may still copy the data into the calling process's heap. For best performance, call once and reuse: `cities = Data.city()` outside the loop.

### File read — I/O + parsing on every call

```elixir
defmodule DataFile do
  def city do
    "./priv/cities.json"
    |> File.read!()        # disk I/O
    |> parse_json()        # string splitting + Float.parse per entry
  end
end
```

**What happens on every call:**
1. `File.read!` — syscall to read ~15KB from disk
2. `String.split(",\n")` — split into 413 entries
3. For each entry: `String.trim` + `String.trim("\"")` + `Float.parse` + `String.to_atom`
4. `Map.new` — build the map from scratch

That's **413 string operations + 1 file read** repeated every single call.

### The cost at scale

| | Module attr | File read | Wasted |
|---|---|---|---|
| 1M calls | 610ms | 1,008ms | **398ms** on I/O + parsing |
| 10M calls | 6,537ms | 10,996ms | **4,459ms** on I/O + parsing |

The x1.7 ratio is constant — every call pays the same fixed penalty. At 10M iterations, you're spending **4.5 seconds** just reading and parsing a file that never changes.

### When to use which

| Approach | Use when |
|---|---|
| Module attribute (`@city`) | Data is known at compile time and doesn't change at runtime |
| File read | Data changes between runs, comes from external source, or is too large for source code |

---

## How to reproduce

```bash
# Write strategy benchmarks
git checkout bench/naive        && mix run lib/create_measurements.exs -c 10000000
git checkout bench/chunked      && mix run lib/create_measurements.exs -c 10000000
git checkout bench/async-stream && mix run lib/create_measurements.exs -c 10000000

# Data access benchmark
mix run scripts/bench_data_access.exs -c 10000000
```

## Debugging tools used

- `:timer.tc/1` — measure any block in microseconds
- `System.monotonic_time/1` — wall clock for total elapsed
- `:counters` — atomic counter for tracking batch progress across tasks
- `System.schedulers_online/0` — verify how many cores are available
- `:observer.start/0` — visual dashboard to see scheduler (core) utilization in real time
