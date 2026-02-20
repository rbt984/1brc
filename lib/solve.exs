# Parse args
{opts, _} = OptionParser.parse!(System.argv(), strict: [file: :string, profile: :boolean, workers: :integer])
file = opts[:file] || "data/measurements.1000000000.txt"
profile? = opts[:profile] || false
workers = max(opts[:workers] || System.schedulers_online(), 1)
started_at = System.monotonic_time()

chunk_size = 8_388_608  # 8 MB chunks

defmodule Prof do
  def now, do: System.monotonic_time()

  def elapsed_ms(started_at), do: elapsed_ms_between(started_at, System.monotonic_time())

  def elapsed_ms_between(started_at, finished_at),
    do: System.convert_time_unit(finished_at - started_at, :native, :millisecond)

  def snapshot do
    %{
      gc: :erlang.statistics(:garbage_collection),
      mem_total: :erlang.memory(:total),
      mem_processes: :erlang.memory(:processes),
      mem_binary: :erlang.memory(:binary)
    }
  end

  def mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 2)
end

# Parse temperature from binary — avoids Float.parse overhead
# Input: "15.4" or "-2.3" — always exactly 1 decimal place
# Returns integer × 10 (e.g., "15.4" → 154, "-2.3" → -23)
defmodule Parse do
  def temp(<<?-, rest::binary>>), do: -parse_digits(rest, 0)
  def temp(bin), do: parse_digits(bin, 0)

  defp parse_digits(<<?., d, _rest::binary>>, acc), do: acc * 10 + (d - ?0)
  defp parse_digits(<<d, rest::binary>>, acc), do: parse_digits(rest, acc * 10 + (d - ?0))
end

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
    whole = div(abs_value, 10)
    frac = rem(abs_value, 10)
    "#{sign}#{whole}.#{frac}"
  end
end

defmodule ParallelSolver do
  def solve(path, chunk_size, workers) do
    size = File.stat!(path).size

    ranges =
      partition_ranges(path, size, workers)
      |> Enum.filter(fn {start_pos, stop_pos} -> start_pos < stop_pos end)

    ranges
    |> Task.async_stream(
      fn {start_pos, stop_pos} -> solve_range(path, start_pos, stop_pos, chunk_size) end,
      max_concurrency: workers,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, chunk_map}, acc ->
      Map.merge(acc, chunk_map, fn _city, {min1, max1, c1, s1}, {min2, max2, c2, s2} ->
        {min(min1, min2), max(max1, max2), c1 + c2, s1 + s2}
      end)
    end)
  end

  defp partition_ranges(_path, 0, _workers), do: []

  defp partition_ranges(path, size, workers) do
    step = div(size + workers - 1, workers)

    {:ok, fd} = :file.open(path, [:read, :raw, :binary])

    boundaries =
      try do
        mids =
          if workers > 1 do
            for i <- 1..(workers - 1) do
              raw = min(i * step, size)
              find_next_line_start(fd, raw, size)
            end
          else
            []
          end

        [0 | mids] ++ [size]
      after
        :file.close(fd)
      end
      |> Enum.uniq()
      |> Enum.sort()

    boundaries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [start_pos, stop_pos] -> {start_pos, stop_pos} end)
  end

  defp find_next_line_start(_fd, pos, size) when pos >= size, do: size

  defp find_next_line_start(fd, pos, size) do
    scan(fd, pos, size)
  end

  defp scan(_fd, pos, size) when pos >= size, do: size

  defp scan(fd, pos, size) do
    len = min(65_536, size - pos)

    case :file.pread(fd, pos, len) do
      {:ok, data} ->
        case :binary.match(data, "\n") do
          {idx, 1} -> pos + idx + 1
          :nomatch -> scan(fd, pos + len, size)
        end

      :eof ->
        size
    end
  end

  defp solve_range(path, start_pos, stop_pos, chunk_size) do
    {:ok, fd} = :file.open(path, [:read, :raw, :binary])

    try do
      reduce_range(fd, start_pos, stop_pos, chunk_size, "", %{})
    after
      :file.close(fd)
    end
  end

  defp reduce_range(_fd, pos, stop_pos, _chunk_size, leftover, acc) when pos >= stop_pos do
    maybe_add_line(leftover, acc)
  end

  defp reduce_range(fd, pos, stop_pos, chunk_size, leftover, acc) do
    len = min(chunk_size, stop_pos - pos)

    case :file.pread(fd, pos, len) do
      {:ok, data} ->
        combined = leftover <> data
        lines = :binary.split(combined, "\n", [:global])
        {complete, [rest]} = Enum.split(lines, -1)

        acc2 =
          Enum.reduce(complete, acc, fn line, map ->
            maybe_add_line(line, map)
          end)

        reduce_range(fd, pos + byte_size(data), stop_pos, chunk_size, rest, acc2)

      :eof ->
        maybe_add_line(leftover, acc)
    end
  end

  defp maybe_add_line("", acc), do: acc

  defp maybe_add_line(line, acc) do
    case :binary.split(line, ";") do
      [city, temp_bin] when city != "" and temp_bin != "" ->
        temp = Parse.temp(temp_bin)

        Map.update(acc, city, {temp, temp, 1, temp}, fn {min, max, count, sum} ->
          {min(min, temp), max(max, temp), count + 1, sum + temp}
        end)

      _ ->
        acc
    end
  end
end

# Process chunks in parallel, each returns a local map, merge at end
profile_before = if profile?, do: Prof.snapshot(), else: nil
compute_started_at = Prof.now()

result = ParallelSolver.solve(file, chunk_size, workers)

# Format output
compute_finished_at = Prof.now()
format_started_at = compute_finished_at

output =
  result
  |> Enum.sort_by(fn {city, _} -> city end)
  |> Enum.map(fn {city, {min, max, count, sum}} ->
    mean = Format.round_div(sum, count)
    "#{city}=#{Format.tenths(min)}/#{Format.tenths(mean)}/#{Format.tenths(max)}"
  end)
  |> Enum.join(", ")

format_finished_at = Prof.now()
compute_ms = Prof.elapsed_ms_between(compute_started_at, compute_finished_at)
format_ms = Prof.elapsed_ms_between(format_started_at, format_finished_at)

IO.puts("{#{output}}")

elapsed_ms =
  Prof.elapsed_ms(started_at)

IO.puts(:stderr, "Elapsed: #{elapsed_ms} ms")

if profile? do
  profile_after = Prof.snapshot()

  IO.puts(:stderr, "Profile:")
  IO.puts(:stderr, "  workers: #{workers}")
  IO.puts(:stderr, "  chunk_size_mb: #{Prof.mb(chunk_size)}")
  IO.puts(:stderr, "  compute_and_merge_ms: #{compute_ms}")
  IO.puts(:stderr, "  sort_and_format_ms: #{format_ms}")
  IO.puts(:stderr, "  total_ms: #{elapsed_ms}")
  IO.puts(:stderr, "  memory_total_mb_before: #{Prof.mb(profile_before.mem_total)}")
  IO.puts(:stderr, "  memory_total_mb_after: #{Prof.mb(profile_after.mem_total)}")
  IO.puts(:stderr, "  memory_processes_mb_before: #{Prof.mb(profile_before.mem_processes)}")
  IO.puts(:stderr, "  memory_processes_mb_after: #{Prof.mb(profile_after.mem_processes)}")
  IO.puts(:stderr, "  memory_binary_mb_before: #{Prof.mb(profile_before.mem_binary)}")
  IO.puts(:stderr, "  memory_binary_mb_after: #{Prof.mb(profile_after.mem_binary)}")
  IO.puts(:stderr, "  gc_before: #{inspect(profile_before.gc)}")
  IO.puts(:stderr, "  gc_after: #{inspect(profile_after.gc)}")
end
