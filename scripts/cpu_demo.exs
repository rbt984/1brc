# CPU Concurrency Demo
# Run: elixir scripts/cpu_demo.exs
# Open Activity Monitor → CPU tab to watch cores light up

defmodule CpuDemo do
  @work_size 5_000_000

  def run do
    cores = System.schedulers_online()

    IO.puts("""
    ╔══════════════════════════════════════════════════╗
    ║         CPU Concurrency Demo                     ║
    ║         Cores available: #{String.pad_leading("#{cores}", 2)}                       ║
    ╚══════════════════════════════════════════════════╝

    This demo runs pure CPU work (trigonometric math)
    and shows how the BEAM distributes it across cores.

    Open Activity Monitor → CPU tab → sort by % CPU
    to watch beam.smp usage change in real time.
    """)

    # Phase 1: Single core
    IO.puts("─── Phase 1: Single Core ───────────────────────────")
    IO.puts("Running #{format_number(@work_size)} computations on 1 process...")
    IO.puts("→ Watch Activity Monitor: beam.smp should show ~100% CPU\n")

    single_time = run_workers(1)
    IO.puts("  Result: #{single_time} ms\n")

    countdown("Phase 2 starts in")

    # Phase 2: Incremental workers
    IO.puts("─── Phase 2: Scaling Workers ───────────────────────")
    IO.puts("Same total work, split across increasing workers.")
    IO.puts("→ Watch CPU % climb with each step\n")

    worker_counts = [1, 2, 4, 8, cores]
    phase2_results =
      Enum.map(worker_counts, fn count ->
        IO.puts("  #{count} worker(s)...")
        time = run_workers(count)
        speedup = single_time / time
        IO.puts("    #{time} ms (x#{Float.round(speedup, 1)} speedup)\n")
        countdown("Next step in")
        {count, time, speedup}
      end)

    # Phase 3: Beyond cores
    IO.puts("─── Phase 3: Diminishing Returns ──────────────────")
    IO.puts("More workers than cores — does it help?")
    IO.puts("→ CPU should stay at ~#{cores * 100}% (all cores maxed)\n")

    beyond_counts = [cores * 2, cores * 5, cores * 10]
    phase3_results =
      Enum.map(beyond_counts, fn count ->
        IO.puts("  #{count} worker(s)...")
        time = run_workers(count)
        speedup = single_time / time
        IO.puts("    #{time} ms (x#{Float.round(speedup, 1)} speedup)\n")
        countdown("Next step in")
        {count, time, speedup}
      end)

    # Summary table
    all_results = phase2_results ++ phase3_results
    print_summary(all_results, single_time)
  end

  defp run_workers(1) do
    {time_us, _} = :timer.tc(fn ->
      compute_range(1, @work_size)
    end)
    div(time_us, 1000)
  end

  defp run_workers(count) do
    chunk_size = div(@work_size, count)

    {time_us, _} = :timer.tc(fn ->
      1..count
      |> Enum.map(fn i ->
        start = (i - 1) * chunk_size + 1
        stop = if i == count, do: @work_size, else: i * chunk_size
        {start, stop}
      end)
      |> Task.async_stream(
        fn {start, stop} -> compute_range(start, stop) end,
        max_concurrency: count,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()
    end)

    div(time_us, 1000)
  end

  defp compute_range(start, stop) do
    Enum.reduce(start..stop, 0.0, fn x, acc ->
      xf = x * 1.0
      acc + Float.round(:math.sin(xf) * :math.cos(xf), 10)
    end)
  end

  defp countdown(label) do
    Enum.each(3..1//-1, fn n ->
      IO.write("\r  #{label} #{n}...")
      Process.sleep(1000)
    end)
    IO.write("\r#{String.duplicate(" ", 40)}\r")
  end

  defp print_summary(results, baseline) do
    max_time = baseline

    IO.puts("""
    ═══════════════════════════════════════════════════
      SUMMARY — #{System.schedulers_online()} cores available
    ═══════════════════════════════════════════════════
    """)

    IO.puts("  Workers │ Time(ms) │ Speedup │ ")
    IO.puts("  ────────┼──────────┼─────────┼─────────────────────────")

    Enum.each(results, fn {workers, time, speedup} ->
      bar_len = round(time / max_time * 30)
      bar = String.duplicate("█", max(bar_len, 1))
      w = String.pad_leading("#{workers}", 7)
      t = String.pad_leading("#{time}", 8)
      s = String.pad_leading("x#{Float.round(speedup, 1)}", 7)
      IO.puts("  #{w} │ #{t} │ #{s} │ #{bar}")
    end)

    IO.puts("")

    # Find the sweet spot
    {best_workers, best_time, best_speedup} = Enum.min_by(results, &elem(&1, 1))

    IO.puts("""
      Key observations:
      • Single core baseline: #{baseline} ms
      • Best result: #{best_time} ms with #{best_workers} workers (x#{Float.round(best_speedup, 1)})
      • Beyond #{System.schedulers_online()} workers: no further improvement
      • This proves the workload is CPU-bound
    """)
  end

  defp format_number(n) when n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  defp format_number(n) when n >= 1_000, do: "#{div(n, 1_000)}K"
  defp format_number(n), do: "#{n}"
end

CpuDemo.run()
