# Course 03 — Solving the 1 Billion Row Challenge

**Context**: We've built the [knowledge foundation](./01_knowledge_foundation.md) and [optimized our file generator](./02_from_47s_to_2s.md). Now we solve the actual challenge: read the measurements file, compute min/mean/max per city, print sorted results.

This course follows the same approach as Course 02 — start with the simplest thing that works, measure, then optimize one bottleneck at a time.

Machine: macOS, 10 cores (schedulers) | Elixir 1.19.1

---

## The Challenge

**Input**: `data/measurements.1000000000.txt` (~14 GB, 1 billion lines)

```
Tokyo;15.4
Paris;-2.3
Lima;22.1
...
```

**Output** (sorted alphabetically):

```
{Abha=-31.1/18.0/66.5, Abidjan=-25.9/26.0/74.6, ...}
```

Per city: `min/mean/max`, all rounded to 1 decimal place. There are 413 unique cities.

---

## The Results

```
Baseline:       |████████████████████████████████████████████████| 6,004ms
Binary parsing: |██████████████████████████████████|               4,316ms
ETS:            |██████████████████████████████████████████|       5,324ms
Parallel:       |███████████████|                                  1,965ms
Combined:       |███████|                                            934ms
+ Rounding:     |████████|                                           990ms
+ Byte ranges:  |████|                                               536ms
+ Fast parser:  |█████|                                              584ms
+ Key copy:     |████|                                               534ms
+ Proc dict:    |███|                                                383ms
+ Dynamic queue:|███|                                                411ms
```

| Step | Strategy | 10M rows | vs baseline |
|---|---|---|---|
| 1 | Baseline — Stream + Map + String ops | 6,004 ms | — |
| 2 | Binary parsing — `:binary.split` + integer temps | 4,316 ms | **x1.4** |
| 3 | ETS — in-place updates, no HAMT copies | 5,324 ms | **x1.1** |
| 4 | Parallel — chunked reading, all 10 cores | 1,965 ms | **x3.1** |
| 5 | Combined — all optimizations together | 934 ms | **x6.4** |
| 6 | + Integer rounding, no floats in formatting | 990 ms | **x6.1** |
| 7 | + Pre-calculated byte-range workers | 536 ms | **x11.2** |
| 8 | + Single-pass binary pattern parser | 584 ms | **x10.3** |
| 9 | + `:binary.copy(key)` avoids sub-binary retention | 534 ms | **x11.2** |
| 10 | + Process dictionary instead of Maps | 383 ms | **x15.7** |
| 11 | + Dynamic work queue + `:prim_file.pread` | 411 ms | **x14.6** |

Sections 1-5 each isolate a single optimization. Sections 6-11 build incrementally on top of Section 5, pushing toward peak performance.

Sections 1-6 use wall clock (`time`). Sections 7-11 use self-reported elapsed (computation only, excludes ~450ms Elixir startup). Relative comparisons within each group are valid.

**1 Billion rows** (full challenge): Step 10 (proc-dict) completes in **67.6 seconds** — down from the projected ~10 minutes of the baseline.

---

## Section 1 — Make It Work: Stream + Map

The first rule of optimization: **have something correct to optimize**. Before we think about performance, we need a solution that produces the right output.

### The problem, decomposed

Four steps:

1. **Read** — get each line from the file
2. **Parse** — extract city name and temperature
3. **Aggregate** — track min, max, sum, count per city
4. **Format** — sort and print the result

### Design decisions

Each step has multiple approaches. Here's what we chose for the baseline, and why.

**Reading — `File.stream!()`**

We need to process a 14 GB file. From [Course 01](./01_knowledge_foundation.md#enum-vs-stream--eager-vs-lazy), we know:

| Strategy | Memory | Risk |
|---|---|---|
| `File.read!` → load everything | ~14 GB in RAM | OOM on most machines |
| `File.stream!` → line by line | ~64 KB buffer | Constant memory |

`File.stream!` reads the file in 64 KB chunks internally, splits into lines, and yields them one at a time through the pipeline. The file never lives entirely in memory.

**Parsing — `String.split` + `Float.parse`**

Each line looks like `"Tokyo;15.4\n"`. We need to extract the city name and convert the temperature to a number.

```elixir
[city, temp_str] = String.split(String.trim_trailing(line, "\n"), ";")
{temp, ""} = Float.parse(temp_str)
```

`String.split` is the simplest way to separate city from temperature. `Float.parse` converts the string to a float. Both are unicode-aware, which we don't need for ASCII data — but correctness first, speed later.

**Aggregating — `Map.update/4` with a tuple**

We need four values per city: min, max, count, sum (mean = sum / count). A tuple `{min, max, count, sum}` stores all four.

From [Course 01](./01_knowledge_foundation.md#maps--how-a-hashmap-works), we know maps give us O(log n) lookup via HAMT. With only 413 cities, the tree is ~9 levels deep — each lookup touches ~9 nodes. That's effectively constant.

`Map.update/4` does insert-or-update in a single call:

```elixir
Map.update(acc, city, {temp, temp, 1, temp}, fn {min, max, count, sum} ->
  {min(min, temp), max(max, temp), count + 1, sum + temp}
end)
```

- First time seeing `"Tokyo"` → inserts `{15.4, 15.4, 1, 15.4}` (min=max=sum=temp, count=1)
- Next time → updates: new min/max, count + 1, sum + temp

Why not a list of `{city, stats}` tuples? As we covered in [Course 01](./01_knowledge_foundation.md#why-it-matters-choosing-the-wrong-complexity), that would be O(n) per lookup — scanning up to 413 entries every line. At 1 billion lines: 413B comparisons vs ~9B node lookups. The map is ~46x less work.

**Processing — `Enum.reduce/3`**

The entire aggregation happens in a single pass over the stream. `Enum.reduce` carries the map as an accumulator — each line updates it, and at the end we have the final result. No intermediate collections, no second pass.

From [Course 01](./01_knowledge_foundation.md#the-reduce-pattern): reduce is the fundamental pattern for processing large data with constant memory. The accumulator (our map) grows to 413 entries and stays there.

### The code

`git checkout solve/baseline`

```elixir
# lib/solve.exs

# Parse args
{opts, _} = OptionParser.parse!(System.argv(), strict: [file: :string])
file = opts[:file] || "data/measurements.1000000000.txt"

# Stream → reduce into a Map
result =
  file
  |> File.stream!()
  |> Enum.reduce(%{}, fn line, acc ->
    # Parse: "Tokyo;15.4\n"
    [city, temp_str] = String.split(String.trim_trailing(line, "\n"), ";")
    {temp, ""} = Float.parse(temp_str)

    Map.update(acc, city, {temp, temp, 1, temp}, fn {min, max, count, sum} ->
      {min(min, temp), max(max, temp), count + 1, sum + temp}
    end)
  end)

# Format output
output =
  result
  |> Enum.sort_by(fn {city, _} -> city end)
  |> Enum.map(fn {city, {min, max, count, sum}} ->
    mean = Float.round(sum / count, 1)
    "#{city}=#{Float.round(min, 1)}/#{Float.round(mean, 1)}/#{Float.round(max, 1)}"
  end)
  |> Enum.join(", ")

IO.puts("{#{output}}")
```

30 lines. No dependencies, no modules, no configuration.

### What happens at runtime

Let's trace what the BEAM does for each of the 1 billion lines:

```
For line "Tokyo;15.4\n":

1. File.stream! yields the line              ← already in memory (from 64KB chunk)
2. String.trim_trailing(line, "\n")          ← scan for trailing \n, allocate new binary
3. String.split(trimmed, ";")               ← unicode scan for ";", allocate list + 2 binaries
4. Float.parse(temp_str)                     ← parse "15.4" → {15.4, ""}, allocate tuple
5. Map.update(acc, "Tokyo", ...)             ← HAMT lookup (~9 nodes), update or insert
6. Return updated map as new accumulator
```

Steps 2-5 happen **1 billion times**. Let's estimate the per-line cost using what we learned in [Course 01](./01_knowledge_foundation.md#part-3-what-costs-what-on-a-real-machine):

| Operation | Estimated cost |
|---|---|
| `String.trim_trailing` | ~100-200 ns |
| `String.split` (unicode) | ~500 ns |
| `Float.parse` | ~200-300 ns |
| `Map.update` (HAMT, 413 keys) | ~250-350 ns |
| Overhead (GC, function calls) | ~100-200 ns |
| **Total per line** | **~1,200-1,500 ns** |

At 1,500 ns × 1 billion lines = **~1,500 seconds** (~25 minutes). That's our theoretical estimate. Let's see how close reality is.

### Baseline measurements

```bash
# 1K rows — verify correctness
mix run lib/solve.exs --file data/measurements.1000.txt

# 1M rows — baseline timing
time mix run lib/solve.exs --file data/measurements.1000000.txt
```

| Rows | Time | Per line |
|---|---|---|
| 1,000 | instant | — |
| 1,000,000 | ~960 ms | ~960 ns |
| 10,000,000 | ~6,004 ms | ~600 ns |

The per-line cost decreases at larger sizes because the BEAM startup cost (~400 ms for `mix run`) becomes a smaller fraction. Extrapolating from 10M rows: 600 ns × 1B = **~600 seconds** (~10 minutes) for the full file.

### Memory profile

The beauty of Stream + Reduce: memory stays constant regardless of file size.

```
Fixed:
  - The map: 413 entries × ~200 bytes = ~80 KB
  - File.stream! buffer: 64 KB

Per-line (temporary, GC'd quickly):
  - Trimmed string: ~20 bytes
  - Split result: 2 binaries + list
  - Float.parse tuple
  - Updated map path: ~9 HAMT nodes

Total: ~200 KB steady state
```

This solution can process a **100 GB file** with the same ~200 KB of working memory. The file size doesn't matter — only the number of unique cities determines the map size.

### What's slow and why

The dominant cost: **`String.split`**. It's doing unicode-aware scanning on ASCII data. From [Course 01](./01_knowledge_foundation.md#string--binary-operations):

| Operation | Cost |
|---|---|
| `String.split(s, ";")` | ~500 ns — unicode scan + allocations |
| `:binary.split(s, ";")` | ~100-200 ns — raw byte scan |
| Binary pattern match | ~50-100 ns — direct byte access |

We're paying for unicode safety we don't need.

The second cost: **`Map.update`**. Every update copies ~9 HAMT nodes. At 1 billion updates, that's ~9 billion node allocations that the garbage collector must clean up.

The third cost: **single core**. We're running on 1 of 10 available cores. The other 9 sit idle.

```
Core 1:  [████████████████████] processing all 1B lines
Core 2:  [                    ] idle
Core 3:  [                    ] idle
...
Core 10: [                    ] idle
```

### What this solution gets right

Despite being slow, this baseline makes several correct decisions:

| Decision | Why it's right |
|---|---|
| `File.stream!` not `File.read!` | Constant memory, can handle any file size |
| `Enum.reduce` not `Enum.map` → `Enum.group_by` | Single pass, no intermediate collections |
| `Map` not list of tuples | O(log n) lookup, not O(n) scan |
| `{min, max, count, sum}` tuple | All stats in one value, O(1) access |
| `Map.update/4` | Insert-or-update in one call, one HAMT traversal |

These decisions will survive into every optimized version. The **architecture** is correct — it's the **per-line operations** that are expensive.

---

## Section 2 — Faster Parsing: Binary Operations

### The bottleneck

From Section 1, the per-line cost breakdown shows `String.split` dominating. Both `String.split` and `Float.parse` are general-purpose functions designed for unicode text and arbitrary number formats. Our data is simpler than that:

- City names are UTF-8 but the **separator is ASCII** (`;`)
- Temperatures are always **exactly 1 decimal place** (e.g., `15.4`, `-2.3`)

We can exploit both of these facts.

### Change 1: `:binary.split` instead of `String.split`

`:binary.split/2` scans raw bytes without unicode awareness. The `;` separator is a single byte — no need to handle multi-byte graphemes.

```elixir
# Before: ~500 ns — unicode scan, allocates list + 2 new binaries
[city, temp_str] = String.split(String.trim_trailing(line, "\n"), ";")

# After: ~150 ns — raw byte scan, sub-binary references (no copy)
[city, temp_bin] = :binary.split(line, ";")
```

Bonus: `:binary.split` returns **sub-binaries** — pointers into the original line, not copies. As we learned in [Course 01](./01_knowledge_foundation.md#binaries--how-text-really-works), sub-binaries are nearly free to create because they reference the original data without allocating new memory.

### Change 2: Custom integer temperature parser

`Float.parse` is a full parser that handles scientific notation, leading zeros, whitespace, and more. We know our temperatures always look like: an optional `-`, 1-2 digits, a `.`, exactly 1 digit. We can write a specialized parser that works with **integers × 10** instead of floats:

```elixir
defmodule Parse do
  def temp(<<?-, rest::binary>>), do: -parse_digits(rest, 0)
  def temp(bin), do: parse_digits(bin, 0)

  defp parse_digits(<<?., d, _rest::binary>>, acc), do: acc * 10 + (d - ?0)
  defp parse_digits(<<d, rest::binary>>, acc), do: parse_digits(rest, acc * 10 + (d - ?0))
end
```

How it works:

```
"15.4\n"
 │
 ├── <<d, rest>> where d = ?1 (49)  →  acc = 0*10 + (49-48) = 1
 ├── <<d, rest>> where d = ?5 (53)  →  acc = 1*10 + (53-48) = 15
 ├── <<?., d, _>> where d = ?4      →  acc = 15*10 + (52-48) = 154
 └── done! Returns 154

"-2.3\n"
 ├── <<?-, rest>>                    →  negate the result
 ├── <<d, rest>> where d = ?2       →  acc = 0*10 + 2 = 2
 ├── <<?., d, _>> where d = ?3      →  acc = 2*10 + 3 = 23
 └── done! Returns -23
```

Two advantages:

1. **No float allocation** — integers are immediate values on the BEAM (no heap allocation for small ints)
2. **Binary pattern matching** — the fastest possible way to read bytes. No function call overhead, no intermediate strings. The BEAM compiles these patterns into direct byte comparisons.

We store everything as integers × 10 and only divide by 10 at the very end when formatting output. This means `min/max` comparisons use integer arithmetic too — faster than float comparisons.

### The code

`git checkout solve/binary-parsing`

```elixir
# lib/solve.exs

{opts, _} = OptionParser.parse!(System.argv(), strict: [file: :string])
file = opts[:file] || "data/measurements.1000000000.txt"

defmodule Parse do
  def temp(<<?-, rest::binary>>), do: -parse_digits(rest, 0)
  def temp(bin), do: parse_digits(bin, 0)

  defp parse_digits(<<?., d, _rest::binary>>, acc), do: acc * 10 + (d - ?0)
  defp parse_digits(<<d, rest::binary>>, acc), do: parse_digits(rest, acc * 10 + (d - ?0))
end

result =
  file
  |> File.stream!()
  |> Enum.reduce(%{}, fn line, acc ->
    [city, temp_bin] = :binary.split(line, ";")
    temp = Parse.temp(String.trim_trailing(temp_bin, "\n"))

    Map.update(acc, city, {temp, temp, 1, temp}, fn {min, max, count, sum} ->
      {min(min, temp), max(max, temp), count + 1, sum + temp}
    end)
  end)

output =
  result
  |> Enum.sort_by(fn {city, _} -> city end)
  |> Enum.map(fn {city, {min, max, count, sum}} ->
    mean = sum / count / 10
    "#{city}=#{Float.round(min / 10, 1)}/#{Float.round(mean, 1)}/#{Float.round(max / 10, 1)}"
  end)
  |> Enum.join(", ")

IO.puts("{#{output}}")
```

### What changed

| Component | Before | After |
|---|---|---|
| Split line | `String.split` (~500 ns) | `:binary.split` (~150 ns) |
| Parse temp | `Float.parse` (~200 ns) | `Parse.temp` binary match (~50 ns) |
| Internal type | Floats | Integers × 10 |
| `String.trim_trailing` | Still present | Still present (on temp only) |

### The numbers

| Rows | Baseline | Binary parsing | Speedup |
|---|---|---|---|
| 1,000,000 | ~960 ms | ~690 ms | **x1.39** |
| 10,000,000 | ~6,004 ms | ~4,316 ms | **x1.39** |

We saved ~169 ns per line by switching from unicode-safe String functions to raw binary operations. At 10M rows, that's ~1.7 seconds saved. At 1B rows, that projects to **~2.8 minutes saved**.

### Why only x1.4?

We optimized the parsing step, but `Map.update` (~250 ns) still runs unchanged, and `File.stream!` has its own overhead from the Elixir I/O server. Parsing was the biggest single cost, but it wasn't the *only* cost. The bottleneck has shifted — `Map.update` is now the largest remaining expense.

---

## Section 3 — Faster Storage: ETS

### The bottleneck

After optimizing parsing, `Map.update` is the next target. Every update to the accumulator map copies ~9 HAMT nodes (the path from root to the changed leaf). At 1 billion updates, that's ~9 billion node allocations — all of which the garbage collector must eventually clean up.

From [Course 01](./01_knowledge_foundation.md#ets--mutable-storage):

| Property | Map | ETS |
|---|---|---|
| Update cost | O(log n) — copies tree path | O(1) — direct write |
| GC pressure | Part of process heap | Not GC'd, manually managed |

ETS gives us **in-place mutation** — the thing immutability normally prevents. The trade-off: data must be copied when read into/out of ETS (serialization). But since we only read the full table once at the end, that cost is negligible.

### The change

Replace the Map accumulator with an ETS table. Instead of `Enum.reduce` building up an immutable map, we use `Enum.each` to write directly to ETS:

```elixir
# Before: Map.update creates a new map version each time
Map.update(acc, city, initial, &update_fn/1)

# After: ETS lookup + insert — mutates in place
case :ets.lookup(table, city) do
  [{^city, min, max, count, sum}] ->
    :ets.insert(table, {city, min(min, temp), max(max, temp), count + 1, sum + temp})
  [] ->
    :ets.insert(table, {city, temp, temp, 1, temp})
end
```

The ETS table lives **outside** the process heap. Updates don't trigger garbage collection. The process only holds a reference to the table, not the data itself.

### The code

`git checkout solve/ets`

```elixir
# lib/solve.exs

{opts, _} = OptionParser.parse!(System.argv(), strict: [file: :string])
file = opts[:file] || "data/measurements.1000000000.txt"

# ETS table for mutable in-place updates
table = :ets.new(:stats, [:set, :public])

file
|> File.stream!()
|> Enum.each(fn line ->
  [city, temp_str] = String.split(String.trim_trailing(line, "\n"), ";")
  {temp, ""} = Float.parse(temp_str)

  case :ets.lookup(table, city) do
    [{^city, min, max, count, sum}] ->
      :ets.insert(table, {city, min(min, temp), max(max, temp), count + 1, sum + temp})
    [] ->
      :ets.insert(table, {city, temp, temp, 1, temp})
  end
end)

output =
  :ets.tab2list(table)
  |> Enum.sort_by(fn {city, _, _, _, _} -> city end)
  |> Enum.map(fn {city, min, max, count, sum} ->
    mean = Float.round(sum / count, 1)
    "#{city}=#{Float.round(min, 1)}/#{Float.round(mean, 1)}/#{Float.round(max, 1)}"
  end)
  |> Enum.join(", ")

IO.puts("{#{output}}")
:ets.delete(table)
```

Note: this version keeps `String.split` + `Float.parse` from Section 1. We're isolating the ETS change to measure its impact alone.

### What changed

| Component | Before (Map) | After (ETS) |
|---|---|---|
| Storage | Immutable Map in process heap | Mutable ETS table, outside heap |
| Update | `Map.update` — copies ~9 HAMT nodes | `:ets.lookup` + `:ets.insert` — in-place |
| GC pressure | High — 9B node allocations | Low — only line-parsing temporaries |
| Read result | Map is already in memory | `:ets.tab2list` copies data once |

### The numbers

| Rows | Baseline | ETS | Speedup |
|---|---|---|---|
| 1,000,000 | ~960 ms | ~852 ms | **x1.13** |
| 10,000,000 | ~6,004 ms | ~5,324 ms | **x1.13** |

### Why is ETS only marginally faster?

Two reasons:

1. **ETS has its own overhead**: `:ets.lookup` + `:ets.insert` involves copying the tuple in and out of ETS storage. For small tuples (5 elements), this is fast — but it's not free. The BEAM serializes data across the process/ETS boundary.

2. **The parsing is still slow**: We kept `String.split` + `Float.parse` in this branch. Those ~700 ns per line dwarf the ~100 ns saved on storage. ETS shines more when combined with fast parsing (Section 5).

The lesson: **optimizing storage alone doesn't help much when parsing dominates**. This is the same pattern we saw in Course 02 — fixing the second bottleneck only shows its full impact after the first bottleneck is gone.

---

## Section 4 — Parallelism: Chunked File Reading

### The bottleneck

Sections 2 and 3 reduced per-line cost. But we're still running on **1 core out of 10**. From [Course 02](./02_from_47s_to_2s.md#step-3--async-stream-parallelize-across-all-cores), we know the fix: split work across processes using `Task.async_stream`.

But there's a problem. `File.stream!` reads line by line through Elixir's I/O server — a single process. We can't parallelize consumption of a stream that's bottlenecked on one process producing lines.

### The approach: binary chunk reading

Instead of `File.stream!`, we read the file in raw **1 MB binary chunks** using `:file.read/2` (Erlang's file API with `:raw` mode — bypasses the I/O server entirely). Each chunk is a batch of lines that can be processed by a separate Task.

The challenge: chunk boundaries don't align with line boundaries. A 1 MB chunk might cut a line in half:

```
Chunk 1: "...Paris;12.3\nTokyo;1"    ← "Tokyo;1" is incomplete
Chunk 2: "5.4\nLima;22.1\n..."       ← "5.4" is the rest of the cut line
```

Solution: keep the last partial line as **leftover** and prepend it to the next chunk.

### The chunker

```elixir
defmodule Chunker do
  def stream(path, chunk_size) do
    Stream.resource(
      fn ->
        {:ok, fd} = :file.open(path, [:read, :raw, :binary])
        {fd, ""}
      end,
      fn {fd, leftover} ->
        case :file.read(fd, chunk_size) do
          {:ok, data} ->
            combined = leftover <> data
            lines = :binary.split(combined, "\n", [:global])
            {complete, [rest]} = Enum.split(lines, -1)
            {[complete], {fd, rest}}

          :eof when leftover == "" ->
            {:halt, {fd, ""}}

          :eof ->
            {[[leftover]], {fd, ""}}
        end
      end,
      fn {fd, _} -> :file.close(fd) end
    )
  end
end
```

How `Stream.resource` works:

1. **Init**: open the file with `:raw` and `:binary` flags (bypasses I/O server, returns raw bytes)
2. **Next**: read a chunk, combine with leftover from previous chunk, split on `\n`, keep the last partial line
3. **Cleanup**: close the file descriptor

Each yield produces a **list of complete lines** — one chunk's worth. `Task.async_stream` then picks these up and processes them in parallel.

```
:file.read(fd, 1MB) → "...Paris;12.3\nTokyo;15.4\nLima"
                                                      ↑
leftover from prev: ""                         leftover for next: "Lima"
                         ↓
complete lines: ["...Paris;12.3", "Tokyo;15.4"]
```

### Parallel processing with merge

Each Task processes its chunk into a **local Map**. At the end, we merge all local maps:

```elixir
Chunker.stream(file, chunk_size)
|> Task.async_stream(fn lines ->
  Enum.reduce(lines, %{}, fn line, acc ->
    # ... parse and aggregate into local map
  end)
end, max_concurrency: System.schedulers_online(), ordered: false, timeout: :infinity)
|> Enum.reduce(%{}, fn {:ok, chunk_map}, acc ->
  Map.merge(acc, chunk_map, fn _city, {min1, max1, c1, s1}, {min2, max2, c2, s2} ->
    {min(min1, min2), max(max1, max2), c1 + c2, s1 + s2}
  end)
end)
```

The flow:

```
File (14 GB)
  │
  ├── Chunk 1 (1 MB) ──→ Task 1 (Core 1) ──→ local Map₁ ──┐
  ├── Chunk 2 (1 MB) ──→ Task 2 (Core 2) ──→ local Map₂ ──┤
  ├── Chunk 3 (1 MB) ──→ Task 3 (Core 3) ──→ local Map₃ ──┤ merge
  │   ... up to 10 concurrent tasks ...                     │
  └── Chunk N          ──→ Task N          ──→ local Mapₙ ──┘
                                                            ↓
                                                      Final result
```

`Map.merge/3` combines two maps, resolving conflicts with a function. For our stats: take the min of mins, max of maxes, add counts, add sums. Each merge handles ~413 entries — trivial work.

### The code

`git checkout solve/parallel`

```elixir
# lib/solve.exs

{opts, _} = OptionParser.parse!(System.argv(), strict: [file: :string])
file = opts[:file] || "data/measurements.1000000000.txt"

chunk_size = 1_048_576  # 1 MB

defmodule Chunker do
  def stream(path, chunk_size) do
    Stream.resource(
      fn ->
        {:ok, fd} = :file.open(path, [:read, :raw, :binary])
        {fd, ""}
      end,
      fn {fd, leftover} ->
        case :file.read(fd, chunk_size) do
          {:ok, data} ->
            combined = leftover <> data
            lines = :binary.split(combined, "\n", [:global])
            {complete, [rest]} = Enum.split(lines, -1)
            {[complete], {fd, rest}}

          :eof when leftover == "" ->
            {:halt, {fd, ""}}

          :eof ->
            {[[leftover]], {fd, ""}}
        end
      end,
      fn {fd, _} -> :file.close(fd) end
    )
  end
end

result =
  Chunker.stream(file, chunk_size)
  |> Task.async_stream(
    fn lines ->
      Enum.reduce(lines, %{}, fn line, acc ->
        [city, temp_str] = String.split(String.trim_trailing(line, "\n"), ";")
        {temp, ""} = Float.parse(temp_str)

        Map.update(acc, city, {temp, temp, 1, temp}, fn {min, max, count, sum} ->
          {min(min, temp), max(max, temp), count + 1, sum + temp}
        end)
      end)
    end,
    max_concurrency: System.schedulers_online(),
    ordered: false,
    timeout: :infinity
  )
  |> Enum.reduce(%{}, fn {:ok, chunk_map}, acc ->
    Map.merge(acc, chunk_map, fn _city, {min1, max1, c1, s1}, {min2, max2, c2, s2} ->
      {min(min1, min2), max(max1, max2), c1 + c2, s1 + s2}
    end)
  end)

output =
  result
  |> Enum.sort_by(fn {city, _} -> city end)
  |> Enum.map(fn {city, {min, max, count, sum}} ->
    mean = Float.round(sum / count, 1)
    "#{city}=#{Float.round(min, 1)}/#{Float.round(mean, 1)}/#{Float.round(max, 1)}"
  end)
  |> Enum.join(", ")

IO.puts("{#{output}}")
```

Note: this version keeps `String.split` + `Float.parse` to isolate the parallelism change.

### What changed

| Component | Before | After |
|---|---|---|
| File reading | `File.stream!` (I/O server, 64 KB) | `:file.read` raw binary (1 MB) |
| Processing | Single process, single core | `Task.async_stream`, all cores |
| Aggregation | One Map, sequential | Per-chunk local Maps, merged |
| CPU utilization | ~100% (1 core) | ~680% (7 cores effective) |

### The numbers

| Rows | Baseline | Parallel | Speedup |
|---|---|---|---|
| 1,000,000 | ~960 ms | ~755 ms | **x1.27** |
| 10,000,000 | ~6,004 ms | ~1,965 ms | **x3.1** |

At 1M rows, the speedup is modest because BEAM startup (~400 ms) and task spawning overhead dominate at small scales. At 10M rows, parallelism shows its power — **681% CPU utilization**, meaning ~7 cores doing useful work.

### Why x3.1 and not x10?

Same story as [Course 02 Step 3](./02_from_47s_to_2s.md#why-x49-and-not-x10):

1. **File reading is sequential** — one process reads chunks from disk. The SSD delivers data at a finite rate.
2. **Task coordination** — spawning ~14 tasks (14 MB / 1 MB chunks for 10M rows), message passing, and merging results all take time.
3. **Merge is sequential** — the final `Enum.reduce` to merge all chunk maps runs on one core.

At larger file sizes (1B rows = ~14,000 chunks), the parallel processing phase dominates and the coordination overhead becomes proportionally smaller. The speedup improves with scale.

---

## Section 5 — Combined: All Optimizations Together

### The idea

Sections 2-4 each optimized one thing in isolation:

| Section | What it optimized | Isolated speedup (10M) |
|---|---|---|
| 2 | Parsing (binary ops) | x1.4 |
| 3 | Storage (ETS) | x1.1 |
| 4 | Parallelism (multi-core) | x3.1 |

Do they multiply? Let's combine the best ideas:

- **Binary parsing** from Section 2 (`:binary.split` + integer temps)
- **Parallel chunked reading** from Section 4 (`Stream.resource` + `Task.async_stream`)
- **Per-chunk local Maps** merged at the end (Section 4's approach, not ETS)

Why not ETS in the combined version? Because with parallelism, each task already has its own local Map. ETS would add serialization overhead at the process boundary for no benefit — the local Map approach avoids contention entirely.

### The code

`git checkout solve/combined`

```elixir
# lib/solve.exs

{opts, _} = OptionParser.parse!(System.argv(), strict: [file: :string])
file = opts[:file] || "data/measurements.1000000000.txt"

chunk_size = 1_048_576  # 1 MB

defmodule Parse do
  def temp(<<?-, rest::binary>>), do: -parse_digits(rest, 0)
  def temp(bin), do: parse_digits(bin, 0)

  defp parse_digits(<<?., d, _rest::binary>>, acc), do: acc * 10 + (d - ?0)
  defp parse_digits(<<d, rest::binary>>, acc), do: parse_digits(rest, acc * 10 + (d - ?0))
end

defmodule Chunker do
  def stream(path, chunk_size) do
    Stream.resource(
      fn ->
        {:ok, fd} = :file.open(path, [:read, :raw, :binary])
        {fd, ""}
      end,
      fn {fd, leftover} ->
        case :file.read(fd, chunk_size) do
          {:ok, data} ->
            combined = leftover <> data
            lines = :binary.split(combined, "\n", [:global])
            {complete, [rest]} = Enum.split(lines, -1)
            {[complete], {fd, rest}}

          :eof when leftover == "" ->
            {:halt, {fd, ""}}

          :eof ->
            {[[leftover]], {fd, ""}}
        end
      end,
      fn {fd, _} -> :file.close(fd) end
    )
  end
end

result =
  Chunker.stream(file, chunk_size)
  |> Task.async_stream(
    fn lines ->
      Enum.reduce(lines, %{}, fn line, acc ->
        [city, temp_bin] = :binary.split(line, ";")
        temp = Parse.temp(temp_bin)

        Map.update(acc, city, {temp, temp, 1, temp}, fn {min, max, count, sum} ->
          {min(min, temp), max(max, temp), count + 1, sum + temp}
        end)
      end)
    end,
    max_concurrency: System.schedulers_online(),
    ordered: false,
    timeout: :infinity
  )
  |> Enum.reduce(%{}, fn {:ok, chunk_map}, acc ->
    Map.merge(acc, chunk_map, fn _city, {min1, max1, c1, s1}, {min2, max2, c2, s2} ->
      {min(min1, min2), max(max1, max2), c1 + c2, s1 + s2}
    end)
  end)

output =
  result
  |> Enum.sort_by(fn {city, _} -> city end)
  |> Enum.map(fn {city, {min, max, count, sum}} ->
    mean = sum / count / 10
    "#{city}=#{Float.round(min / 10, 1)}/#{Float.round(mean, 1)}/#{Float.round(max / 10, 1)}"
  end)
  |> Enum.join(", ")

IO.puts("{#{output}}")
```

80 lines. Still a single file, no external dependencies.

### What this combines

Each line processed by a Task now does:

```
For line "Tokyo;15.4\n":

1. :binary.split(line, ";")           ← ~150 ns  (was ~500 ns with String.split)
2. Parse.temp(temp_bin)               ← ~50 ns   (was ~200 ns with Float.parse)
3. Map.update(local_map, city, ...)   ← ~250 ns  (unchanged — local per-task map)

Total: ~450 ns per line              (was ~960 ns in baseline)
```

And this runs on **10 cores simultaneously** instead of 1.

### The numbers

| Rows | Baseline | Combined | Speedup |
|---|---|---|---|
| 1,000,000 | ~960 ms | ~468 ms | **x2.1** |
| 10,000,000 | ~6,004 ms | ~934 ms | **x6.4** |

At 10M rows: **354% CPU utilization**, ~0.93 seconds wall time.

### Do the speedups multiply?

In theory: x1.4 (binary) × x3.1 (parallel) = **x4.3**. We got **x6.4** — actually *better* than the product. Why?

Two reasons:

1. **Faster parsing feeds parallelism better**. With cheaper per-line work, the Tasks finish faster and the pipeline stays saturated. Less time waiting for slow Tasks means better core utilization.

2. **No ETS contention**. Each Task owns its local Map — no shared mutable state, no locking, no serialization overhead. This is the ideal parallel pattern: fully independent work units.

### The full picture

```
Baseline:       |████████████████████████████████████████████████| 6,004ms  (1 core, String ops)
Binary parsing: |██████████████████████████████████|               4,316ms  (1 core, binary ops)
ETS:            |██████████████████████████████████████████|       5,324ms  (1 core, ETS storage)
Parallel:       |███████████████|                                  1,965ms  (10 cores, String ops)
Combined:       |███████|                                            934ms  (10 cores, binary ops)
```

### Projected times for 1 billion rows

| Version | 10M time | Projected 1B time |
|---|---|---|
| Baseline | 6,004 ms | ~10 minutes |
| Combined | 934 ms | ~1.6 minutes |

---

## Sections 6-11 — Beyond Combined: Incremental Optimizations

Sections 1-5 followed a "one optimization at a time" approach, isolating each technique. From here, we switch to **incremental improvements** — each section builds on top of the previous one, compounding gains toward peak performance.

The base for all subsequent sections is `solve/combined` (Section 5).

---

## Section 6 — Integer Rounding: Eliminate All Floats

### The bottleneck

Section 5 stores temperatures as integers × 10, but the **formatting step** converts back to floats for output:

```elixir
mean = sum / count / 10
"#{city}=#{Float.round(min / 10, 1)}/#{Float.round(mean, 1)}/#{Float.round(max / 10, 1)}"
```

Each `Float.round/2` allocates a float on the heap. With 413 cities, that's 1,239 float allocations just for formatting. More importantly, `Float.round` can produce surprising results with IEEE 754 rounding — integer rounding is both faster and more predictable.

### The change

`git checkout solve/rounding`

Replace `Float.round` with integer-only rounding and formatting:

```elixir
defmodule Format do
  # Round numerator / denominator to nearest integer, ties away from zero.
  def round_div(numerator, denominator) when numerator >= 0 do
    div(numerator * 2 + denominator, denominator * 2)
  end

  def round_div(numerator, denominator) do
    -div(abs(numerator) * 2 + denominator, denominator * 2)
  end

  # Format a value stored in tenths as "x.y" without floats.
  def tenths(value) do
    sign = if value < 0, do: "-", else: ""
    abs_value = abs(value)
    "#{sign}#{div(abs_value, 10)}.#{rem(abs_value, 10)}"
  end
end
```

The mean is now computed as `Format.round_div(sum, count)` — pure integer division with correct rounding, no float allocation.

### The numbers

| Rows | Combined | + Rounding | Speedup |
|---|---|---|---|
| 10,000,000 | 934 ms | 990 ms | **~x1.0** |

No measurable speedup at 10M rows — the formatting step runs once per city (413 times), so it's negligible compared to the 10 million parse-and-aggregate iterations. The value of this change is **correctness** (deterministic rounding) and **setting the stage** for a fully float-free pipeline.

---

## Section 7 — Byte-Range Workers: Pre-Calculated Parallel Partitions

### The bottleneck

Section 5 uses `Stream.resource` + `Task.async_stream` — a producer/consumer model where one process reads chunks and feeds them to worker tasks. The reader is a sequential bottleneck: workers must wait for the next chunk to be read and dispatched.

### The change

`git checkout solve/byte-ranges`

Instead of streaming chunks, **pre-calculate byte ranges** at startup. Divide the file into N equal-sized regions (one per worker), then scan forward to the next newline to find exact boundaries:

```elixir
defmodule ParallelSolver do
  def solve(path, chunk_size, workers) do
    size = File.stat!(path).size
    ranges = partition_ranges(path, size, workers)

    ranges
    |> Task.async_stream(
      fn {start_pos, stop_pos} ->
        solve_range(path, start_pos, stop_pos, chunk_size)
      end,
      max_concurrency: workers, ordered: false, timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, chunk_map}, acc ->
      Map.merge(acc, chunk_map, &merge_stats/3)
    end)
  end
end
```

Each worker opens its own file descriptor and reads its assigned byte range using `:file.pread/3` — no shared reader, no coordination during processing.

```
Before (stream-based):
  Reader ──chunk──→ Task 1
         ──chunk──→ Task 2     (sequential dispatch)
         ──chunk──→ Task 3
         ...

After (byte-range):
  Task 1 ──pread──→ [0, 14MB)      (parallel, independent)
  Task 2 ──pread──→ [14MB, 28MB)
  Task 3 ──pread──→ [28MB, 42MB)
  ...
```

### The numbers

| Rows | Combined | + Byte ranges | Speedup |
|---|---|---|---|
| 10,000,000 | 934 ms | 536 ms | **x1.74** |

At 10M rows, the byte-range approach already shows a clear improvement by eliminating the sequential reader bottleneck. Each worker opens its own file descriptor and reads independently — no coordination during processing.

---

## Section 8 — Single-Pass Binary Parser

### The bottleneck

Each line is currently processed in two steps: `:binary.split(line, ";")` to separate city from temperature, then `Parse.temp/1` on the temperature portion. The split allocates a 2-element list and creates sub-binaries.

### The change

`git checkout solve/fast-parser`

Replace the split-then-parse approach with a **single-pass parser** that scans the binary once, extracting both the city key and temperature in one traversal:

```elixir
defmodule FastParser do
  defp parse_station(orig, <<";", temp_bin::binary>>, key_size) do
    <<key::binary-size(key_size), ?;, _::binary>> = orig

    case parse_temp_with_nl(temp_bin) do
      {:ok, temp, rest} -> {:ok, key, temp, rest}
      :incomplete -> :incomplete
    end
  end

  defp parse_station(orig, <<_c, rest::binary>>, key_size),
    do: parse_station(orig, rest, key_size + 1)
end
```

The parser walks through the binary byte by byte, counting characters until it hits `;`. Then it extracts the key as a sized sub-binary and parses the temperature from the remaining bytes — all without creating intermediate lists or extra sub-binaries.

It also processes the **entire chunk** as a continuous binary instead of splitting into lines first — no `:binary.split(combined, "\n", [:global])` call.

### The numbers

| Rows | + Byte ranges | + Fast parser | Speedup |
|---|---|---|---|
| 10,000,000 | 536 ms | 584 ms | **x0.92** |

The single-pass approach eliminates the list allocation from `:binary.split` and avoids scanning the binary twice (once for newlines, once for semicolons). At this scale, the parser change is slightly slower — the overhead of the byte-by-byte scan outweighs the allocation savings for small files.

---

## Section 9 — Key Copy: Avoiding Sub-Binary Retention

### The bottleneck

When we extract a city name with `<<key::binary-size(key_size), ...>>`, the BEAM creates a **sub-binary** — a pointer into the original 8 MB chunk. If this sub-binary is stored as a Map key, the entire 8 MB chunk stays alive in memory until the sub-binary is garbage collected. With 413 cities across 10 workers, that's potentially hundreds of retained chunks.

From [Course 01](./01_knowledge_foundation.md#binaries--how-text-really-works): sub-binaries are cheap to create but expensive to retain when they keep large parent binaries alive.

### The change

`git checkout solve/key-copy`

Use `:binary.copy/1` when inserting a **new** city key. For updates to existing keys, the key is already copied:

```elixir
defp update(acc, key, temp) do
  case acc do
    %{^key => {min, max, count, sum}} ->
      %{acc | key => {min(min, temp), max(max, temp), count + 1, sum + temp}}

    _ ->
      Map.put(acc, :binary.copy(key), {temp, temp, 1, temp})
  end
end
```

`:binary.copy/1` creates a standalone binary — no reference to the parent chunk. This happens at most 413 times (once per unique city), so the copy cost is negligible. The benefit: 8 MB chunks can be garbage collected as soon as processing finishes, rather than being retained by tiny sub-binary references.

### The numbers

| Rows | + Fast parser | + Key copy | Speedup |
|---|---|---|---|
| 10,000,000 | 584 ms | 534 ms | **x1.09** |

Small but consistent improvement. The real win is **memory**: without `:binary.copy`, peak memory could be 10× higher as workers retain chunks through sub-binary references.

---

## Section 10 — Process Dictionary: O(1) Mutable Storage

### The bottleneck

`Map.update` on an immutable HAMT still copies ~9 nodes per update. At 10M rows across 10 workers, that's ~9 million node allocations per worker — all fodder for the garbage collector.

### The change

`git checkout solve/proc-dict`

Replace the immutable Map accumulator with the **process dictionary** — a mutable hash table private to each process:

```elixir
defp update(key, temp) do
  case :erlang.get(key) do
    :undefined ->
      :erlang.put(:binary.copy(key), {temp, temp, 1, temp})

    {min, max, count, sum} ->
      :erlang.put(key, {min(min, temp), max(max, temp), count + 1, sum + temp})
  end
end
```

`:erlang.get/1` and `:erlang.put/2` operate on a per-process hash table with **O(1) amortized lookup and update**. No HAMT path copying, no node allocations, minimal GC pressure.

After processing, convert back to a Map for merging:

```elixir
def to_map do
  :erlang.get()
  |> Enum.reduce(%{}, fn
    {key, {min, max, count, sum}}, acc when is_binary(key) ->
      Map.put(acc, key, {min, max, count, sum})
    _, acc -> acc
  end)
end
```

### The numbers

| Rows | + Key copy | + Proc dict | Speedup |
|---|---|---|---|
| 10,000,000 | 534 ms | 383 ms | **x1.39** |
| 1,000,000,000 | — | 67,611 ms | — |

**The biggest single improvement** in this entire series. Eliminating HAMT overhead saves ~151 ms at 10M rows — 28% of the total time. The process dictionary is the fastest mutable storage available on the BEAM.

### Why not use the process dictionary from the start?

The process dictionary is a pragmatic shortcut, not idiomatic Elixir. It breaks the functional programming model — data mutates in place, invisible to other processes. In concurrent code, this can lead to subtle bugs.

In our case, it's safe because each worker Task has its own process dictionary. No sharing, no races. But it's the kind of optimization you reach for **after** profiling shows Map updates are the bottleneck — not before.

---

## Section 11 — Dynamic Work Queue + `:prim_file`

### The idea

Section 7's byte-range approach divides the file into N equal regions (one per worker). But if some workers finish faster than others (due to CPU scheduling, memory pressure, or varying line lengths), cores sit idle while stragglers finish.

A **dynamic work queue** splits the file into many small chunks (hundreds), and workers pull the next chunk when they finish the current one — a work-stealing pattern:

```
Manager (queue of 200+ chunks)
  │
  ├── Worker 1: "give me work" → chunk 1 → "give me work" → chunk 5 → ...
  ├── Worker 2: "give me work" → chunk 2 → "give me work" → chunk 6 → ...
  └── Worker 3: "give me work" → chunk 3 → "give me work" → chunk 4 → ...
```

### The change

`git checkout solve/dynamic-queue`

Two changes:

1. **Work queue manager**: A lightweight process holding a `:queue` of byte ranges. Workers send `{:need_work, self()}`, manager replies with `{:work, start, stop}` or `:done`.

2. **`:prim_file`** instead of `:file`: The lowest-level file API in Erlang, bypassing the file server process entirely. Each worker calls `:prim_file.pread/3` directly.

```elixir
defp solve_worker(path, manager_pid, chunk_size) do
  {:ok, fd} = :prim_file.open(path, [:raw, :binary, :read])

  try do
    worker_loop(fd, manager_pid, chunk_size)
    FastParser.to_map()
  after
    :prim_file.close(fd)
  end
end

defp worker_loop(fd, manager_pid, chunk_size) do
  send(manager_pid, {:need_work, self()})

  receive do
    {:work, start_pos, stop_pos} ->
      reduce_range(fd, start_pos, stop_pos, chunk_size, "")
      worker_loop(fd, manager_pid, chunk_size)

    :done -> :ok
  end
end
```

### The numbers

| Rows | + Proc dict | + Dynamic queue | Speedup |
|---|---|---|---|
| 10,000,000 | 383 ms | 411 ms | **x0.93** |
| 1,000,000,000 | 67,611 ms | 88,943 ms | **x0.76** |

### Why is this slower?

The dynamic queue is **slower** than the simpler fixed-partition approach. Two reasons:

1. **Coordination overhead**: Each chunk requires a message to the manager and a reply. At hundreds of chunks, that's hundreds of message round-trips. The fixed-partition approach has zero coordination after startup.

2. **`:prim_file` trade-offs**: While `:prim_file` bypasses the Erlang file server, it loses the file server's read-ahead buffering. For sequential reads within a worker's range, `:file.pread` can be faster because the file server batches reads.

The lesson: **more sophisticated is not always faster**. The fixed-partition approach (Section 7) is simpler, has less coordination overhead, and leverages the file server's buffering. Work-stealing helps when task sizes vary wildly — but our chunks are uniform, so there's little straggler problem to solve.

---

## Summary of Incremental Optimizations

```
Combined:        |████████████████████████████████████████████████|  934ms  (Section 5 — our starting point)
+ Byte ranges:   |███████████████████████████|                      536ms  (Section 7 — pre-calc partitions)
+ Fast parser:   |██████████████████████████████|                   584ms  (Section 8 — single-pass parser)
+ Key copy:      |███████████████████████████|                      534ms  (Section 9 — binary.copy keys)
+ Proc dict:     |████████████████████|                             383ms  (Section 10 — process dictionary)
+ Dynamic queue: |█████████████████████|                            411ms  (Section 11 — work queue, slower)
```

| Step | 10M time | vs Combined | Key change |
|---|---|---|---|
| 5 — Combined | 934 ms | — | Binary parse + parallel |
| 7 — Byte ranges | 536 ms | x1.74 | Pre-calculated worker ranges |
| 8 — Fast parser | 584 ms | x1.60 | Single-pass binary scanner |
| 9 — Key copy | 534 ms | x1.75 | `:binary.copy` for map keys |
| 10 — Proc dict | 383 ms | **x2.44** | Process dictionary storage |
| 11 — Dynamic queue | 411 ms | x2.27 | Work-stealing + `:prim_file` |

Note: Sections 7-11 use self-reported elapsed (computation only, excludes ~450ms Elixir startup), while Section 5 uses wall clock. The "vs Combined" ratios compare wall clock to self-reported, so they reflect the improvement in total time including the measurement method change.

**Best result**: Section 10 (proc-dict) — **383 ms** for 10M rows, **67.6 seconds** for 1 billion rows.

The peak performance comes from **Section 10**, not Section 11. The process dictionary eliminates the last major overhead (HAMT copies), while the dynamic work queue adds coordination cost that outweighs its load-balancing benefit.

### What didn't make the table

**Section 6 (rounding)** changes output formatting only — no performance impact. It's included in all subsequent branches but isn't benchmarked separately.

**Step 2 (profiling infrastructure)** from the codex branches added a `Prof` module for timing and memory diagnostics. It's infrastructure, not optimization — no separate `solve/` branch.

---

## Key Takeaways

### The optimization layers

Each section targeted a different layer, just like Course 02:

| Section | Layer | What we fixed |
|---|---|---|
| 2 | Per-operation cost | Unicode overhead → raw binary ops |
| 3 | Data structure | Immutable HAMT copies → mutable ETS |
| 4 | CPU utilization | 1 core → 10 cores |
| 5 | All combined | Faster ops + more cores = multiplicative gains |
| 7-8 | I/O + parsing | Sequential reads → pread; two-pass → single-pass |
| 9 | Memory | Sub-binary retention → `:binary.copy` |
| 10 | Data structure | HAMT Map → process dictionary (O(1)) |
| 11 | Architecture | Fixed partitions → work-stealing (negative result) |

### The pattern repeats

```
Course 02 (file generation):    47s → 13.6s → 2.7s     (x17.3)
Course 03 (solving, 10M):       6.0s → 0.93s → 0.38s   (x15.7)
Course 03 (solving, 1B):        ~10min → ~68s            (x8.8)
```

Same three levers: **batch I/O**, **reduce per-operation cost**, **parallelize**. Then a fourth lever: **eliminate allocation overhead** (process dictionary).

### What we learned

1. **Isolate changes** — one optimization per branch lets you measure each contribution
2. **Binary > String for ASCII** — `:binary.split` and pattern matching bypass unicode overhead
3. **Integers > Floats** — avoid float allocation by working with integers × 10
4. **Local Maps > shared ETS** — in parallel code, per-task local state avoids contention
5. **Chunked raw reads > File.stream!** — `:file.read` with `:raw` bypasses the I/O server bottleneck
6. **Speedups compound** — fixing different bottlenecks gives compounding improvement
7. **Process dictionary is the fastest Map** — O(1) mutable storage, safe when each Task owns its own
8. **`:binary.copy` prevents memory leaks** — sub-binaries retain parent binaries; copy keys on first insert
9. **Simpler can beat cleverer** — the dynamic work queue (Section 11) was slower than fixed partitions due to coordination overhead. Not every "improvement" improves performance
10. **Measure before and after** — Section 7 (byte ranges) was slower at 10M rows but would improve at larger scales. Context matters

### How to reproduce

Each `solve/` branch contains a standalone `lib/solve.exs` script. Sections 7-11 report their own elapsed time to stderr.

```bash
# Generate data files (if needed)
elixir lib/create_measurements.exs --rows 1000        # 1K — correctness check
elixir lib/create_measurements.exs --rows 10000000    # 10M — benchmarks
elixir lib/create_measurements.exs --rows 1000000000  # 1B — full challenge

# ──────────────────────────────────────────────────────
# Sections 1-5: Isolated optimizations (use `time` for timing)
# ──────────────────────────────────────────────────────

git checkout solve/baseline        && time elixir lib/solve.exs --file data/measurements.10000000.txt
git checkout solve/binary-parsing  && time elixir lib/solve.exs --file data/measurements.10000000.txt
git checkout solve/ets             && time elixir lib/solve.exs --file data/measurements.10000000.txt
git checkout solve/parallel        && time elixir lib/solve.exs --file data/measurements.10000000.txt
git checkout solve/combined        && time elixir lib/solve.exs --file data/measurements.10000000.txt

# ──────────────────────────────────────────────────────
# Sections 6-11: Incremental optimizations (report elapsed to stderr)
# ──────────────────────────────────────────────────────

git checkout solve/rounding        && elixir lib/solve.exs --file data/measurements.10000000.txt
git checkout solve/byte-ranges     && elixir lib/solve.exs --file data/measurements.10000000.txt
git checkout solve/fast-parser     && elixir lib/solve.exs --file data/measurements.10000000.txt
git checkout solve/key-copy        && elixir lib/solve.exs --file data/measurements.10000000.txt
git checkout solve/proc-dict       && elixir lib/solve.exs --file data/measurements.10000000.txt
git checkout solve/dynamic-queue   && elixir lib/solve.exs --file data/measurements.10000000.txt

# ──────────────────────────────────────────────────────
# Full challenge (1B rows) — run on best versions
# ──────────────────────────────────────────────────────

git checkout solve/proc-dict       && elixir lib/solve.exs --file data/measurements.1000000000.txt
git checkout solve/dynamic-queue   && elixir lib/solve.exs --file data/measurements.1000000000.txt

# ──────────────────────────────────────────────────────
# Verify correctness: diff any branch against baseline
# ──────────────────────────────────────────────────────

# Run baseline
git show solve/combined:lib/solve.exs > /tmp/solve_baseline.exs
elixir /tmp/solve_baseline.exs --file data/measurements.1000.txt > /tmp/baseline.txt 2>/dev/null

# Run any branch
git show solve/proc-dict:lib/solve.exs > /tmp/solve_test.exs
elixir /tmp/solve_test.exs --file data/measurements.1000.txt > /tmp/test.txt 2>/dev/null

# Compare (Sections 6+ use integer rounding, so small mean differences are expected)
diff /tmp/baseline.txt /tmp/test.txt

# ──────────────────────────────────────────────────────
# Automated benchmark script (3 runs each, best time)
# ──────────────────────────────────────────────────────

for branch in solve/combined solve/rounding solve/byte-ranges solve/fast-parser \
              solve/key-copy solve/proc-dict solve/dynamic-queue; do
  echo "=== $branch ==="
  for i in 1 2 3; do
    git show "$branch:lib/solve.exs" > /tmp/bench_solve.exs 2>/dev/null
    elixir /tmp/bench_solve.exs --file data/measurements.10000000.txt 2>&1 1>/dev/null \
      | grep "Elapsed:" | head -1
  done
done
```

**Benchmarking tips**:
- Close other CPU-intensive apps during benchmarks
- Run 3+ iterations and take the best time (coldest cache = worst time)
- Sections 7-11 print `Elapsed: NNN ms` to stderr — this measures computation only, excluding Elixir startup
- For Sections 1-5, use `time` — the wall clock includes ~2s of Elixir/mix startup overhead
- The `--profile` flag (Sections 7-11) prints detailed memory and GC stats

---

**Previous**: [Course 02 — From 47s to 2.7s](./02_from_47s_to_2s.md)
