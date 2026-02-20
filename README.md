# The One Billion Row Challenge (in Elixir)

1BRC is a challenge, [originally in Java](https://github.com/gunnarmorling/1brc), to process a text file of weather station names and temperatures, and for each weather station, print out the minimum, mean, and maximum.

It sounds simple, but the catch is that the file contains **one billion rows**.

```
Tokyo;15.4
Paris;-2.3
Lima;22.1
Ankara;12.0
...
(1,000,000,000 lines)
```

Expected output:

```
{Abha=-31.1/18.0/66.5, Abidjan=-25.9/26.0/74.6, ...}
```

---

## Setting Up This Repo

**Prerequisites**: Elixir 1.19+ and Erlang/OTP 27+

```bash
git clone <repo-url> && cd onebtc
mix deps.get
```

---

## Available Commands

### Creating measurements

Generate the test data file. The file is written to `data/measurements.<count>.txt`.

```bash
# Generate 1,000 rows (quick test)
mix run lib/create_measurements.exs -c 1000

# Generate 10 million rows (~150 MB)
mix run lib/create_measurements.exs -c 10000000

# Generate 1 billion rows (~14 GB) — takes a few minutes
mix run lib/create_measurements.exs -c 1000000000
```

### Benchmarks

Compare different write strategies on 10M rows:

```bash
# Step 1 — Naive: one IO.puts per line
git checkout bench/naive        && mix run lib/create_measurements.exs -c 10000000

# Step 2 — Chunked: batch 10K lines per write (iolists)
git checkout bench/chunked      && mix run lib/create_measurements.exs -c 10000000

# Step 3 — Async stream: parallelize across all cores
git checkout bench/async-stream && mix run lib/create_measurements.exs -c 10000000
```

Data access benchmark (module attribute vs file read):

```bash
mix run scripts/bench_data_access.exs -c 10000000
```

### CPU concurrency demo

Visually proves concurrency on your machine. Open Activity Monitor while it runs to see cores light up.

```bash
elixir scripts/cpu_demo.exs
```

---

## Performance Traces

Machine: macOS, 10 cores | Elixir 1.19.1

### File generation — 10M rows

| Step | Strategy | Time | Speedup |
|---|---|---|---|
| 1 | Naive (1 write per line) | 47,808 ms | baseline |
| 2 | Chunked (10K lines per write) | 13,641 ms | **x3.5** |
| 3 | Async stream (10 cores) | 2,771 ms | **x17.3** |

```
Naive:        |████████████████████████████████████████████████| 47,808ms
Chunked:      |█████████████|                                   13,641ms
Async stream: |██|                                               2,771ms
```

### Data access — 10M iterations

| Strategy | Time | Ratio |
|---|---|---|
| Module attribute (compile-time) | 6,537 ms | baseline |
| File read (runtime parsing) | 10,996 ms | **x1.7 slower** |

### CPU demo — 5M computations

| Workers | Time | Speedup |
|---|---|---|
| 1 | ~5,300 ms | x1.0 |
| 2 | ~2,700 ms | x1.9 |
| 4 | ~1,500 ms | x3.5 |
| 10 | ~980 ms | x5.4 |
| 20+ | ~980 ms | x5.4 (plateau) |

---

## Courses

Step-by-step learning material covering the concepts needed to tackle the challenge:

1. [Knowledge Foundation](courses/01_knowledge_foundation.md) — Big O, linked lists, hashmaps, binaries, streams, syscalls, CPU concurrency, BEAM processes, and a hands-on demo
2. [From 47s to 2.7s](courses/02_from_47s_to_2s.md) — How we optimized our file generator step by step: syscalls, iolists, and parallelism
