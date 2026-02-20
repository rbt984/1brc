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
Baseline:       |████████████████████████████████████████████████| 5,931ms
Binary parsing: |████████████████████████████████████████|         4,867ms
ETS:            |██████████████████████████████████████████|       5,109ms
Parallel:       |███████████████|                                  1,874ms
Combined:       |████████|                                         1,087ms
```

| Step | Strategy | 10M rows | vs baseline |
|---|---|---|---|
| 1 | Baseline — Stream + Map + String ops | 5,931 ms | — |
| 2 | Binary parsing — `:binary.split` + integer temps | 4,867 ms | **x1.2** |
| 3 | ETS — in-place updates, no HAMT copies | 5,109 ms | **x1.2** |
| 4 | Parallel — chunked reading, all 10 cores | 1,874 ms | **x3.2** |
| 5 | Combined — all optimizations together | 1,087 ms | **x5.5** |

Each step isolates a single optimization. Section 5 combines them all.

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
| 10,000,000 | ~5,931 ms | ~593 ns |

The per-line cost decreases at larger sizes because the BEAM startup cost (~400 ms for `mix run`) becomes a smaller fraction. Extrapolating from 10M rows: 593 ns × 1B = **~593 seconds** (~10 minutes) for the full file.

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
| 1,000,000 | ~960 ms | ~765 ms | **x1.25** |
| 10,000,000 | ~5,931 ms | ~4,867 ms | **x1.22** |

We saved ~200 ns per line by switching from unicode-safe String functions to raw binary operations. At 10M rows, that's ~2 seconds saved. At 1B rows, that projects to **~3.3 minutes saved**.

### Why only x1.25?

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
| 1,000,000 | ~960 ms | ~783 ms | **x1.23** |
| 10,000,000 | ~5,931 ms | ~5,109 ms | **x1.16** |

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
| 1,000,000 | ~960 ms | ~720 ms | **x1.33** |
| 10,000,000 | ~5,931 ms | ~1,874 ms | **x3.2** |

At 1M rows, the speedup is modest because BEAM startup (~400 ms) and task spawning overhead dominate at small scales. At 10M rows, parallelism shows its power — **681% CPU utilization**, meaning ~7 cores doing useful work.

### Why x3.2 and not x10?

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
| 2 | Parsing (binary ops) | x1.22 |
| 3 | Storage (ETS) | x1.16 |
| 4 | Parallelism (multi-core) | x3.2 |

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
| 10,000,000 | ~5,931 ms | ~1,087 ms | **x5.5** |

At 10M rows: **354% CPU utilization**, ~1.1 seconds wall time.

### Do the speedups multiply?

In theory: x1.22 (binary) × x3.2 (parallel) = **x3.9**. We got **x5.5** — actually *better* than the product. Why?

Two reasons:

1. **Faster parsing feeds parallelism better**. With cheaper per-line work, the Tasks finish faster and the pipeline stays saturated. Less time waiting for slow Tasks means better core utilization.

2. **No ETS contention**. Each Task owns its local Map — no shared mutable state, no locking, no serialization overhead. This is the ideal parallel pattern: fully independent work units.

### The full picture

```
Baseline:       |████████████████████████████████████████████████| 5,931ms  (1 core, String ops)
Binary parsing: |████████████████████████████████████████|         4,867ms  (1 core, binary ops)
ETS:            |██████████████████████████████████████████|       5,109ms  (1 core, ETS storage)
Parallel:       |███████████████|                                  1,874ms  (10 cores, String ops)
Combined:       |████████|                                         1,087ms  (10 cores, binary ops)
```

### Projected times for 1 billion rows

| Version | 10M time | Projected 1B time |
|---|---|---|
| Baseline | 5,931 ms | ~10 minutes |
| Combined | 1,087 ms | ~1.8 minutes |

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

### The pattern repeats

```
Course 02 (file generation):    47s → 13.6s → 2.7s    (x17.3)
Course 03 (solving):            5.9s → 4.9s → 1.1s    (x5.5)
```

Same three levers: **batch I/O**, **reduce per-operation cost**, **parallelize**.

### What we learned

1. **Isolate changes** — one optimization per branch lets you measure each contribution
2. **Binary > String for ASCII** — `:binary.split` and pattern matching bypass unicode overhead
3. **Integers > Floats** — avoid float allocation by working with integers × 10
4. **Local Maps > shared ETS** — in parallel code, per-task local state avoids contention
5. **Chunked raw reads > File.stream!** — `:file.read` with `:raw` bypasses the I/O server bottleneck
6. **Speedups multiply** — fixing different bottlenecks gives compounding improvement

### How to reproduce

```bash
# Section 1 — Baseline
git checkout solve/baseline   && time mix run lib/solve.exs --file data/measurements.10000000.txt

# Section 2 — Binary parsing
git checkout solve/binary-parsing && time mix run lib/solve.exs --file data/measurements.10000000.txt

# Section 3 — ETS
git checkout solve/ets        && time mix run lib/solve.exs --file data/measurements.10000000.txt

# Section 4 — Parallel
git checkout solve/parallel   && time mix run lib/solve.exs --file data/measurements.10000000.txt

# Section 5 — Combined
git checkout solve/combined   && time mix run lib/solve.exs --file data/measurements.10000000.txt
```

---

**Previous**: [Course 02 — From 47s to 2.7s](./02_from_47s_to_2s.md)
