# Course 01 — Knowledge Foundation

**Context**: everything in this course is what you need to understand before tackling the **1 Billion Row Challenge** (1BRC) — read a ~14 GB file with 1,000,000,000 lines of `city;temperature`, compute min/avg/max per city, output sorted results.

At 1 billion rows, every micro-decision compounds. A 1 ns difference per row = **1 extra second**. A bad data structure choice = minutes of waste. This course explains why.

---

## Part 1: Big O — What Scales and What Explodes

Big O describes how an algorithm scales as input grows. It ignores constants — but at 1B rows, **constants matter too**.

### The common complexities

| Big O | Name | Example | 1K items | 1M items |
|---|---|---|---|---|
| O(1) | Constant | Map lookup `map[:key]` | 1 op | 1 op |
| O(log n) | Logarithmic | Binary search, HAMT tree lookup | 10 ops | 20 ops |
| O(n) | Linear | `Enum.map`, `Enum.filter`, list scan | 1K ops | 1M ops |
| O(n log n) | Linearithmic | `Enum.sort`, merge sort | 10K ops | 20M ops |
| O(n²) | Quadratic | Nested loops, naive duplicate check | 1M ops | 1T ops |

### Why it matters: choosing the wrong complexity

**O(1) vs O(n) per lookup** — picking the wrong data structure can silently destroy performance:

```elixir
# O(1) per lookup — map goes directly to the key
Map.update(acc, city, {temp, temp, temp, 1}, fn {min, max, sum, count} ->
  {min(min, temp), max(max, temp), sum + temp, count + 1}
end)

# O(n) per lookup — list scans every element to find the match
Enum.find(list_of_stats, fn {c, _} -> c == city end)
# With 500 entries × 1M lookups = 500M comparisons instead of 1M
```

**O(n²) — accidental nested loops** can turn seconds into years:

```elixir
# This would take mass extinction level time:
# 1B × 1B = 10^18 operations
for line_a <- lines, line_b <- lines, do: compare(line_a, line_b)
```

### The constant factor trap

Big O says `Enum.map` and a manual `reduce` are both O(n). But at 1B rows:

| Per-line cost | × 1B rows | Total |
|---|---|---|
| 100 ns | 1,000,000,000 | **100 seconds** |
| 50 ns | 1,000,000,000 | **50 seconds** |
| 10 ns | 1,000,000,000 | **10 seconds** |

Shaving 50 ns per line saves **50 seconds** on the full run. At this scale, constant factors dominate.

### Visual growth

```
Operations
│
│                                          ╱ O(n²)
│                                       ╱
│                                    ╱
│                                ╱
│                           ╱
│                      ╱ ╱── O(n log n)
│                ╱  ╱
│           ╱ ╱────────── O(n)
│       ╱╱
│   ╱╱ ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌ O(log n)
│╱━━━━━━━━━━━━━━━━━━━━━━ O(1)
└──────────────────────────────── Input size (n)
```

---

## Part 2: Elixir Data Structures — What's Fast and What's a Trap

Elixir is a **functional language**. All data is **immutable** — you never modify a value, you create a new one. This changes which operations are cheap and which are expensive.

### Lists are linked lists

An Elixir list is **not** an array. It's a singly linked list — a chain of cells, each holding a value and a pointer to the next cell.

```
[1, 2, 3, 4]

 ┌───┬───┐   ┌───┬───┐   ┌───┬───┐   ┌───┬───┐
 │ 1 │  ─┼──→│ 2 │  ─┼──→│ 3 │  ─┼──→│ 4 │ ∅ │
 └───┴───┘   └───┴───┘   └───┴───┘   └───┴───┘
  head                                  tail
```

You only have a pointer to the **head**. To reach element N, you walk N steps. There is no `list[3]` index jump.

### List operation costs

| Operation | Cost | Why |
|---|---|---|
| Prepend `[x \| list]` | **O(1)** | Create one new cell pointing to existing list |
| Append `list ++ [x]` | **O(n)** | Must copy every cell (immutable) |
| Access `Enum.at(list, i)` | **O(n)** | Walk i cells |
| Length `length(list)` | **O(n)** | Walk entire chain |
| Head `hd(list)` | **O(1)** | Just the pointer |

### Why immutability makes prepend free

When you prepend, you create **one new cell** pointing to the existing list. The old list is unchanged — other processes can still use it.

```elixir
list = [2, 3, 4]
new_list = [1 | list]
```

```
new_list ──→ ┌───┬───┐
             │ 1 │  ─┼──→ ┌───┬───┐   ┌───┬───┐   ┌───┬───┐
             └───┴───┘    │ 2 │  ─┼──→│ 3 │  ─┼──→│ 4 │ ∅ │
list ─────────────────────→└───┴───┘   └───┴───┘   └───┴───┘
```

Both `list` and `new_list` **share the same memory** for `[2, 3, 4]`. No copy. This is called **structural sharing** — the foundation of efficient immutable data structures.

### The `++` append trap

Since append must copy the entire left-hand list, using `++` inside a loop creates O(n²) total work:

```elixir
# BAD — O(n²) total! Each ++ copies the growing accumulator
result = Enum.reduce(items, [], fn item, acc ->
  acc ++ [transform(item)]
end)

# GOOD — O(n) total. Prepend is O(1), one final reverse is O(n)
result =
  items
  |> Enum.reduce([], fn item, acc -> [transform(item) | acc] end)
  |> Enum.reverse()
```

| Items | `acc ++ [x]` (O(n²)) | `[x \| acc]` + reverse (O(n)) |
|---|---|---|
| 1,000 | ~500K copies | ~2K ops |
| 100,000 | ~5B copies | ~200K ops |
| 1,000,000 | ~500B copies | ~2M ops |

`Enum.reverse` is O(n) — one pass. The pattern "prepend in reduce, reverse at the end" is the idiomatic approach. It's what `Enum.map` does internally.

### Maps — how a hashmap works

A **hashmap** (or hash table) is the most important data structure for key-value lookups. Understanding how it works explains why it's O(1) and when it isn't.

**The basic idea:**

1. You have an **array of buckets** (slots)
2. To store `key => value`, you compute a **hash** of the key: a number
3. That number tells you **which bucket** to put it in
4. To look up a key, hash it again → go directly to the right bucket

```
put("Tokyo", stats)
  → hash("Tokyo") = 738291
  → 738291 mod 8 = 3         (8 buckets)
  → store in bucket 3

get("Tokyo")
  → hash("Tokyo") = 738291
  → bucket 3 → found it!     O(1) — no scanning
```

```
Buckets:
  [0] ∅
  [1] "Paris" → {12.3, ...}
  [2] ∅
  [3] "Tokyo" → {15.4, ...}  ← hash("Tokyo") lands here
  [4] "Lima"  → {19.2, ...}
  [5] ∅
  [6] ∅
  [7] "Seoul" → {12.5, ...}
```

**Why it's O(1)**: hashing + array index access = constant time, no matter how many entries. You don't scan through all keys like you would with a list.

**Collisions**: when two keys hash to the same bucket, you get a collision. The bucket stores multiple entries and you must scan through them. With a good hash function and enough buckets, collisions are rare.

### BEAM maps — HAMT (Hash Array Mapped Trie)

Elixir/Erlang maps don't use a simple hash table. They use a **HAMT** — a tree-shaped hashmap designed for immutability.

**Why not a regular hash table?** Because data is immutable. In a regular hash table, `Map.put` would need to **copy the entire array** just to change one bucket. At 1000 entries, every update copies 1000 slots.

**HAMT solves this**: it organizes buckets into a **tree**. An update only copies the **path from root to the changed leaf** — typically O(log n) nodes.

```
Regular hash table — update copies everything:
  [0] [1] [2] [3] [4] [5] [6] [7]    ← copy all 8 slots
                ↑ changed

HAMT — update copies only the path (log n nodes):
           ┌─── Root ───┐
          ╱               ╲
      ┌─Node─┐         ┌─Node─┐      ← copy this path
      │      │         │      │
    Leaf   Leaf      Leaf   Leaf
                       ↑ changed

  Only 3 nodes copied instead of all entries
```

**BEAM map sizes and behavior:**

| Map size | Internal structure | Lookup | Update |
|---|---|---|---|
| ≤ 32 keys | Flat sorted list | O(n) but fast (small) | O(n) copy |
| > 32 keys | HAMT tree | O(log n) | O(log n) path copy |

For a few hundred entries, that's a HAMT ~9 levels deep. Each lookup/update touches ~9 nodes.

### ETS — mutable storage

**ETS** (Erlang Term Storage) is the BEAM's escape hatch from immutability. It's a mutable key-value table stored **outside** any process heap.

| Property | Map | ETS |
|---|---|---|
| Mutability | Immutable — update creates new version | Mutable — update in-place |
| Update cost | O(log n) — copies tree path | O(1) — direct write |
| Access | Same process, instant | Any process, data is copied in/out |
| GC pressure | Part of process heap | Not GC'd, manually managed |
| Concurrency | Must pass updated map between processes | Shared, concurrent reads/writes |

ETS is useful when you need many processes to read/write the same data, or when map copy overhead from frequent updates becomes a bottleneck.

### Tuples — fixed-size containers

Tuples are stored as **contiguous memory** (like a small array). Element access is O(1) by index.

```elixir
stats = {-5.2, 42.1, 1_500_000.0, 100_000}
#        min    max    sum           count

elem(stats, 0)  # -5.2 — O(1), direct index
```

**Trade-off**: updating a tuple copies the entire tuple. But for small tuples (3-5 elements), this is trivially fast.

| Size | Access | Update | Use when |
|---|---|---|---|
| 2-5 elements | O(1) | O(1)* | Fixed-shape records: `{min, max, sum, count}` |
| 100+ elements | O(1) | O(n) copy | Don't — use a map instead |

*\*Technically O(n) copy, but n ≤ 5 so it's effectively constant*

### Binaries — how text really works

In Elixir, strings are **binaries** — contiguous sequences of bytes in memory.

```elixir
"hello" == <<104, 101, 108, 108, 111>>
# Each character = 1 byte (ASCII)
```

Two representations exist in the BEAM:

| Type | Size | Storage | What happens |
|---|---|---|---|
| **Heap binary** | ≤ 64 bytes | On the process heap | Copied on message pass, GC'd normally |
| **Refc binary** | > 64 bytes | Shared binary heap | Reference counted, shared across processes |

**Why this matters**: when you read a large file chunk (say 1 MB), the BEAM stores it as a **refc binary**. If you extract a small piece with `binary_part` or pattern matching, you get a **sub-binary** — a pointer into the original large binary, not a copy. This is very efficient but means the large binary stays in memory as long as any sub-binary references it.

```elixir
# Reading a 1MB chunk → 1 refc binary
chunk = IO.binread(file, 1_000_000)

# Extracting a city name → sub-binary (pointer, no copy)
<<city::binary-size(5), _rest::binary>> = chunk
# "Tokyo" points into the 1MB chunk — no new allocation

# But: the 1MB chunk can't be GC'd until all sub-binaries are gone
```

To release the large binary, you can force a copy of the small piece:

```elixir
city = :binary.copy(city)  # now a small independent binary
```

### Enum vs Stream — eager vs lazy

Every `Enum` function processes the **entire collection** and builds a complete result:

```elixir
# Eager — builds 3 intermediate lists in memory
1..1_000_000
|> Enum.map(&(&1 * 2))       # builds list of 1M elements
|> Enum.filter(&(&1 > 100))  # builds another list
|> Enum.take(10)              # only needed 10!
```

`Stream` composes operations and processes elements **one at a time**:

```elixir
# Lazy — processes one element through the full pipeline
1..1_000_000
|> Stream.map(&(&1 * 2))
|> Stream.filter(&(&1 > 100))
|> Enum.take(10)  # stops after finding 10, doesn't touch the rest
```

| | Enum (eager) | Stream (lazy) |
|---|---|---|
| Memory | Full intermediate collections | One element at a time |
| Processing | Always processes everything | Can stop early |
| Speed (small data) | Faster (no wrapping overhead) | Slightly slower |
| Speed (huge data) | May OOM before finishing | Constant memory |

**When to use Stream**: whenever the data is too large to fit in memory, or when you want to process a pipeline without building intermediate collections. `File.stream!` itself returns a stream — it reads the file chunk by chunk as you consume elements.

### The reduce pattern

`Enum.reduce` is the most fundamental operation for processing large data. It walks through a collection once, carrying an **accumulator** that builds up the result:

```elixir
# Count words in a list — one pass, O(n), constant accumulator
Enum.reduce(["hello", "world", "hello"], %{}, fn word, counts ->
  Map.update(counts, word, 1, &(&1 + 1))
end)
# => %{"hello" => 2, "world" => 1}
```

Why it matters: `reduce` lets you process a stream of data **without storing it all**. You feed elements in one side, and only the accumulator (the result you're building) stays in memory.

### Data structure cheat sheet

| Structure | Lookup | Update | Best for |
|---|---|---|---|
| **List** | O(n) scan | O(1) prepend | Sequential processing, pattern matching |
| **Map** | O(log n) | O(log n) | Key-value lookups and accumulation |
| **Tuple** | O(1) index | O(1)* small | Fixed-shape records (2-5 elements) |
| **Binary** | O(n) parse | Immutable | Raw data, text, file content |
| **ETS** | O(1) | O(1) | Shared mutable state across processes |
| **MapSet** | O(log n) | O(log n) | Unique collections, membership checks |

### Think about it

Now that you know how these data structures work, consider these scenarios:

**Question 1**: You have a file with 1 billion lines. You want to process each line and compute a result. What happens if you do this?

```elixir
lines = File.stream!(path) |> Enum.to_list()
```

<details>
<summary>Answer</summary>

This builds a **linked list of 1 billion elements** in memory. Each cell is ~40 bytes (value + pointer + overhead), so that's ~40 GB of RAM just to store the list — before you've done any processing. Then you'd iterate through it again, doubling the work. A linked list is the wrong structure when you don't need to keep every element around.

The key insight: if you only need to **walk through data once**, you don't need to store it all. Streams and `reduce` let you process one element at a time with constant memory.
</details>

**Question 2**: You're building up a result inside `Enum.reduce`. What's the difference between these two approaches?

```elixir
# Approach A
Enum.reduce(items, [], fn item, acc -> acc ++ [transform(item)] end)

# Approach B
items |> Enum.reduce([], fn item, acc -> [transform(item) | acc] end) |> Enum.reverse()
```

<details>
<summary>Answer</summary>

**Approach A is O(n²)**. Each `++` copies the entire accumulator. At iteration 1: copy 1 element. At iteration 1000: copy 1000 elements. Total copies: 1 + 2 + 3 + ... + n = n(n+1)/2. At 1M items, that's ~500 billion cell copies.

**Approach B is O(n)**. Each prepend `[x | acc]` is O(1) — just create one cell. The final `Enum.reverse` is one O(n) pass. Total: ~2n operations.

This is exactly what `Enum.map` does internally — prepend then reverse.
</details>

**Question 3**: You need to count occurrences of each word in a large dataset. Which is faster for lookups — a list of `{word, count}` tuples or a map `%{word => count}`?

<details>
<summary>Answer</summary>

The **map** is dramatically faster. Finding a word in a list of tuples requires scanning: O(n) per lookup, where n is the number of unique words. A map lookup is O(log n) via HAMT, or effectively O(1) for small-to-medium maps.

At 10,000 unique words with 1 billion lookups:
- List: ~10,000 comparisons per lookup × 1B = ~10 trillion comparisons
- Map: ~13 HAMT node lookups × 1B = ~13 billion lookups

That's ~770x fewer operations for the map.
</details>

---

## Part 3: What Costs What on a Real Machine

Not all operations are equal. At 1B rows, every operation on the hot path is multiplied a billion times. Understanding the actual cost of each operation lets you make informed decisions.

### CPU operations — nanoseconds

| Operation | Approx. cost | Notes |
|---|---|---|
| Integer add/multiply | ~1 ns | Single CPU instruction |
| Float arithmetic | ~5 ns | `Float.round`, `:math.sin` |
| Function call | ~5-10 ns | BEAM dispatch |
| Pattern match | ~5-20 ns | Compiled to efficient jumps |
| `:rand.uniform()` | ~30 ns | PRNG state update |
| `Enum.random(list)` | ~50 ns + O(n) | Traverses the list! |
| String interpolation | ~100-500 ns | Allocates new binary |

At 1B rows, even nanosecond-level operations add up: 1 ns × 1B = 1 second.

### String & binary operations

Elixir has two worlds for text: **String** (unicode-aware, safe) and **binary** (raw bytes, fast). They have very different costs.

| Operation | Approx. cost | What happens under the hood |
|---|---|---|
| `String.split(s, ";")` | ~500 ns | Unicode scan + list allocation + new binary allocation |
| `:binary.split(s, ";")` | ~100-200 ns | Raw byte scan, no unicode overhead |
| Binary pattern match | ~50-100 ns | Direct byte access, no allocation |
| `String.to_float/1` | ~200-400 ns | Full parser, handles scientific notation, edge cases |
| `Float.parse/1` | ~200-300 ns | Returns `{float, rest}` tuple |
| String concatenation `<>` | ~200 ns-1μs | Copies both sides |
| Iolist `[a, b, c]` | ~10 ns per element | No copy, just pointers |

**Why the difference matters**: `String.split` does a lot of work — it handles unicode graphemes, allocates a list, allocates new binary copies for each segment. Binary operations work directly on raw bytes. When your data is ASCII (like city names and numbers), you're paying for unicode safety you don't need.

```elixir
# String.split — safe, unicode-aware, allocates
[city, temp_str] = String.split(line, ";")

# :binary.split — faster, raw bytes, less allocation
[city, temp_bin] = :binary.split(line, ";")

# Binary pattern matching — fastest, zero allocation
# (you need to know the split position or scan for it)
```

**Float parsing**: `String.to_float` and `Float.parse` are general-purpose parsers. If you know your data format exactly (e.g., temperatures always have 1 decimal place), you can parse more efficiently — even avoid floats entirely by working with integers and dividing at the end.

### Memory operations

| Operation | Approx. cost | Notes |
|---|---|---|
| Map lookup `map[:key]` | ~50 ns | O(log n) in BEAM (HAMT tree) |
| Map put `Map.put(m, k, v)` | ~200-300 ns | Copies the path in the tree |
| `Map.update/4` | ~250-350 ns | Get + transform + put |
| Small list prepend `[h \| t]` | ~10 ns | O(1), one cell |
| `Map.new/1` from ~500 entries | ~50 μs | Builds the full tree |
| GC of short-lived process | ~1-10 μs | Per-process heap = cheap GC |
| `:ets.update_counter/3` | ~100-200 ns | Mutable storage, no structural copy |

**BEAM maps** use a Hash Array Mapped Trie (HAMT). Updates don't copy the whole map — they copy only the path from root to the changed leaf. With a few hundred entries, that's ~9 nodes. Still, at millions of updates, it adds up.

**ETS** (Erlang Term Storage) is a mutable key-value store outside the process heap. Updates are in-place — no structural copying. Trade-off: data must be copied in/out of ETS (serialization cost), and it's a shared resource.

### What's a syscall?

Your program runs in **user space**. It can do math, build strings, update maps — all without help. But the moment it needs to touch the outside world (read a file, write to disk, open a network connection), it must ask the **OS kernel** for help. This request is called a **syscall** (system call).

```
Your code (user space)           OS Kernel
──────────────────────           ─────────
IO.puts(file, data)
  │
  ├── 1. Package the request
  ├── 2. Context switch           ──→  3. Kernel receives request
  │     (user → kernel mode)           4. Kernel writes to disk buffer
  ├── 5. Context switch           ←──  6. Kernel returns "done"
  │     (kernel → user mode)
  └── Continue execution
```

Each context switch costs **~3-5 μs**. That's the fixed overhead of talking to the kernel — regardless of how much data you're sending. Writing 1 byte or 1 MB costs the same ~5 μs in overhead.

This means:
- **1 syscall to write 10,000 lines** = ~5 μs
- **10,000 syscalls to write 10,000 lines** = ~50,000 μs (50 ms)

Same data, same result, **10,000x more overhead**. The lesson: batch your I/O to minimize the number of round-trips to the kernel.

### I/O operation costs

| Operation | Approx. cost | Notes |
|---|---|---|
| Single syscall (read/write) | ~3-5 μs | Context switch overhead |
| `IO.puts` / `IO.read(:line)` | ~5 μs | 1 syscall per call |
| `IO.write` iolist (10K lines) | ~5 μs | Still just 1 syscall! |
| `File.open` / `File.close` | ~10-50 μs | Kernel file descriptor alloc |
| `File.read!` (15 KB) | ~20-50 μs | Cached in OS buffer |
| `File.read!` (100 MB) | ~50-100 ms | Depends on disk speed |

At scale: reading 100M lines one syscall each = 100M × 5 μs = **~8 minutes** of pure overhead. Reading the same data in large chunks = a few thousand syscalls = **milliseconds**.

### File reading strategies in Elixir

| Strategy | How it works | Syscalls for a large file |
|---|---|---|
| `IO.read(file, :line)` in a loop | One syscall per line | 1 per line |
| `File.stream!(path)` | Reads in 64 KB chunks, splits into lines | ~file size / 64KB |
| `File.stream!(path, chunk_size)` | Reads in custom-sized chunks | ~file size / chunk size |
| `:file.read(path)` | Reads entire file into memory | 1 |
| `:file.pread(fd, offset, length)` | Reads a specific byte range | 1 per call |

Each has trade-offs between memory usage, syscall count, and how easy it is to parallelize.

### Cost hierarchy — what to worry about first

```
1 ns     Integer add, comparison
10 ns    Function call, list prepend, iolist element
50 ns    Map lookup, binary match
200 ns   Map.update, string concat, float parse
500 ns   String.split
5 μs     One syscall (read, write)
```

At 1B iterations, multiply by 1,000,000,000:

```
1 ns  ×  1B  =    1 second       ← negligible
50 ns ×  1B  =   50 seconds      ← noticeable
500ns ×  1B  =  500 seconds      ← dominant
5 μs  ×  1B  = 5000 seconds      ← fatal
```

---

## Part 4: CPU & Concurrency

### Single core vs multi core

By default, Elixir code runs on a **single BEAM scheduler** (= 1 OS thread = 1 CPU core):

```elixir
# This runs on ONE core, no matter how many you have
Enum.map(1..10_000_000, fn x ->
  :math.sin(x) * :math.cos(x)
end)
```

Your machine has 10 cores. The code above uses 1. The other 9 sit idle.

### What the BEAM scheduler does

The BEAM VM starts **one scheduler per CPU core** (10 on this machine). Each scheduler:

1. Picks a process from its run queue
2. Gives it **~4,000 reductions** (roughly ~4,000 function calls)
3. Preempts it and picks the next process
4. Repeat

This is **preemptive scheduling** — no process can hog a core. But if you only have 1 process doing work, only 1 scheduler is busy.

```
Core 1:  [████████████████████] busy — your process
Core 2:  [                    ] idle
Core 3:  [                    ] idle
...
Core 10: [                    ] idle
```

To use all 10 cores, you need **at least 10 processes** doing work simultaneously:

```
Core 1:  [████████████████████] Process 1
Core 2:  [████████████████████] Process 2
Core 3:  [████████████████████] Process 3
...
Core 10: [████████████████████] Process 10
```

### BEAM processes vs OS threads

| Property | OS Thread (Java, Go) | BEAM Process (Elixir) |
|---|---|---|
| Memory | ~1 MB (stack) | ~2 KB (initial heap) |
| Creation time | ~50-100 μs | ~1-3 μs |
| Max practical count | ~1,000-10,000 | ~1,000,000+ |
| Scheduling | OS kernel | BEAM VM (userspace) |
| Context switch | ~1-10 μs (kernel mode) | ~0.1-0.5 μs (no kernel) |

**Key difference**: BEAM processes are **500x lighter** and **50x faster to create** than OS threads. You can spawn one per task without worrying about overhead.

```elixir
# Spawning 100,000 processes — totally fine in Elixir
processes = Enum.map(1..100_000, fn i ->
  spawn(fn -> do_work(i) end)
end)
# Memory: ~200 MB (100K × 2KB)
# Creation: ~200 ms (100K × 2μs)
```

### Scaling patterns

**Level 1: `spawn`** — fire and forget

```elixir
spawn(fn -> do_heavy_work() end)
# Returns immediately, no way to get the result back
```

Use when: you don't need the result (logging, side effects).

**Level 2: `Task.async` + `Task.await`** — parallel with result

```elixir
task1 = Task.async(fn -> compute_chunk_1() end)
task2 = Task.async(fn -> compute_chunk_2() end)

result1 = Task.await(task1)
result2 = Task.await(task2)
```

Use when: you have a **fixed number** of parallel jobs.

**Level 3: `Task.async_stream`** — parallel pipeline

```elixir
1..1000
|> Stream.chunk_every(100)
|> Task.async_stream(fn chunk ->
  Enum.map(chunk, &heavy_compute/1)
end, max_concurrency: System.schedulers_online())
|> Enum.reduce([], fn {:ok, result}, acc -> acc ++ result end)
```

Use when: you have a **stream of work** to distribute across cores.

Key options:
- `max_concurrency` — how many concurrent tasks (default: `System.schedulers_online()`)
- `ordered: false` — don't wait for slow tasks to return in order
- `timeout: :infinity` — disable the 5-second default timeout

| Pattern | Use case | Back-pressure |
|---|---|---|
| `spawn` | Fire-and-forget side effects | None |
| `Task.async/await` | Fixed parallel jobs (2-20) | Manual |
| `Task.async_stream` | Processing a stream in parallel | Built-in (max_concurrency) |

### When concurrency helps (and when it doesn't)

**CPU-bound work — concurrency helps:**

The work is pure computation. More cores = more throughput.

```elixir
# Each process does independent math — perfect parallelism
Task.async_stream(chunks, fn chunk ->
  Enum.map(chunk, fn x -> :math.sin(x) * :math.cos(x) end)
end, max_concurrency: 10)
```

Expected speedup: near-linear up to number of cores.

```
1 core:   10,000 ms
2 cores:   5,200 ms  (x1.9)
4 cores:   2,700 ms  (x3.7)
10 cores:  1,200 ms  (x8.3)
20 cores:  1,200 ms  (x8.3)  ← no more physical cores!
```

**I/O-bound, multiple targets — concurrency helps:**

```elixir
# 10 HTTP requests, each takes 100ms
# Sequential: 1,000 ms → Parallel (10 tasks): ~100 ms
urls
|> Task.async_stream(&HTTPClient.get/1, max_concurrency: 10)
|> Enum.to_list()
```

**I/O-bound, single target — concurrency does NOT help:**

```elixir
# 10 tasks all writing to the same file
# They serialize at the file descriptor level
# Concurrency adds overhead with zero benefit
```

---

## Part 5: Hands-On Demo — See Your Cores Light Up

### The script: `scripts/cpu_demo.exs`

This script makes concurrency **visible** on your machine. It runs pure CPU work (trigonometric math, no I/O) and shows the impact of adding workers.

### How to run

```bash
elixir scripts/cpu_demo.exs
```

### What to expect

**Phase 1 — Single core** (~3-5 seconds):
- Open **Activity Monitor** → CPU tab → sort by % CPU
- You'll see `beam.smp` using ~100% (1 core)
- Other cores remain idle

**Phase 2 — Incremental workers** (1, 2, 4, 8, 10 workers):
- Watch `beam.smp` CPU usage jump with each step
- 2 workers → ~200%, 4 workers → ~400%, 10 workers → ~1000%
- Timing decreases proportionally

**Phase 3 — Diminishing returns** (20, 50, 100 workers):
- CPU stays at ~1000% (can't exceed 10 cores × 100%)
- Timing stays flat — proves we're CPU-bound, not concurrency-limited

### What to look for in Activity Monitor

| Phase | Workers | Expected CPU % | Expected time |
|---|---|---|---|
| 1 | 1 | ~100% | baseline |
| 2 | 2 | ~200% | ~baseline/2 |
| 2 | 4 | ~400% | ~baseline/4 |
| 2 | 10 | ~1000% | ~baseline/8-10 |
| 3 | 20 | ~1000% | same as 10 workers |
| 3 | 100 | ~1000% | same as 10 workers |

### Summary table

The script prints a table like this at the end:

```
┌──────────┬──────────┬─────────┬─────────────────────────┐
│ Workers  │ Time(ms) │ Speedup │ Bar                     │
├──────────┼──────────┼─────────┼─────────────────────────┤
│        1 │   3200   │  x1.0   │ ████████████████████████ │
│        2 │   1650   │  x1.9   │ ████████████             │
│        4 │    850   │  x3.8   │ ██████                   │
│        8 │    480   │  x6.7   │ ████                     │
│       10 │    400   │  x8.0   │ ███                      │
│       20 │    390   │  x8.2   │ ███                      │
│       50 │    395   │  x8.1   │ ███                      │
│      100 │    400   │  x8.0   │ ███                      │
└──────────┴──────────┴─────────┴─────────────────────────┘
```

Notice: speedup plateaus at ~x8-9 (practical limit for 10 cores). Beyond 10 workers, **no improvement** — definitive proof that this is CPU-bound work.

---

## Summary

| Concept | Key insight |
|---|---|
| Big O | O(n) is fine — O(n²) is fatal at scale |
| Constants | 1 ns × 1B = 1 second. At this scale, constant factors dominate |
| Linked lists | Prepend O(1), append O(n). Never `++` in a loop |
| Hashmaps | Hash → bucket → O(1) lookup. BEAM uses HAMT for immutable efficiency |
| Structural sharing | Immutability enables safe sharing across processes |
| Streams | Lazy processing = constant memory. Eager = OOM on big data |
| Reduce | The fundamental pattern: process a stream with constant memory |
| Binaries | Heap (≤64B) vs refc (>64B). Sub-binaries are pointers, not copies |
| String vs binary | String operations pay for unicode safety you may not need |
| Syscalls | ~5 μs each — trivial once, catastrophic at scale. Batch I/O |
| Concurrency | 1 process = 1 core. BEAM processes are 500x lighter than OS threads |
| Scaling | `Task.async_stream` for parallel pipelines. Linear speedup up to core count |
| Know your bottleneck | CPU-bound → parallelize. I/O-bound single target → batch, don't parallelize |
| Measure first | Find the bottleneck before optimizing anything |

---

**Next**: [Course 02 — From 47s to 2.7s](./02_from_47s_to_2s.md) — how we optimized our file generator step by step, and what each optimization taught us.
