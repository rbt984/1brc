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

defmodule Worker do
  def run(parent_pid) do
    send(parent_pid, {:give_work, self()})

    receive do
      {:do_work, chunk} ->
        parse_lines(chunk)
        run(parent_pid)

      :result ->
        result =
          :erlang.get()
          |> Enum.reduce(%{}, fn
            {key, {min, max, count, sum}}, acc when is_binary(key) ->
              Map.put(acc, key, {min, max, count, sum})

            _, acc ->
              acc
          end)

        send(parent_pid, {:result, self(), result})
    end
  end

  defp parse_lines(<<>>), do: :ok

  defp parse_lines(bin) do
    parse_station(bin, bin, 0)
  end

  defp parse_station(orig, <<";", temp_bin::binary>>, key_size) do
    <<key::binary-size(key_size), ";", _::binary>> = orig
    parse_temp(temp_bin, key)
  end

  defp parse_station(_orig, <<>>, _key_size), do: :ok

  defp parse_station(orig, <<_c, rest::binary>>, key_size) do
    parse_station(orig, rest, key_size + 1)
  end

  # -D.D\n
  defp parse_temp(<<?-, d1, ?., d2, ?\n, rest::binary>>, key) do
    update(key, -(digit(d1) * 10 + digit(d2)))
    parse_lines(rest)
  end

  # D.D\n
  defp parse_temp(<<d1, ?., d2, ?\n, rest::binary>>, key) do
    update(key, digit(d1) * 10 + digit(d2))
    parse_lines(rest)
  end

  # -DD.D\n
  defp parse_temp(<<?-, d1, d2, ?., d3, ?\n, rest::binary>>, key) do
    update(key, -(digit(d1) * 100 + digit(d2) * 10 + digit(d3)))
    parse_lines(rest)
  end

  # DD.D\n
  defp parse_temp(<<d1, d2, ?., d3, ?\n, rest::binary>>, key) do
    update(key, digit(d1) * 100 + digit(d2) * 10 + digit(d3))
    parse_lines(rest)
  end

  defp update(key, temp) do
    case :erlang.get(key) do
      :undefined ->
        :erlang.put(:binary.copy(key), {temp, temp, 1, temp})

      {min, max, count, sum} ->
        :erlang.put(key, {min(min, temp), max(max, temp), count + 1, sum + temp})
    end
  end

  defp digit(c), do: c - ?0
end

defmodule Solver do
  def solve(path, chunk_size, worker_count) do
    parent = self()

    wpids =
      for _ <- 1..worker_count do
        spawn_link(fn -> Worker.run(parent) end)
      end

    {:ok, fd} = :prim_file.open(path, [:raw, :binary, :read])
    :ok = dispatch_chunks(fd, chunk_size)
    :prim_file.close(fd)

    # Collect results from all workers
    wpids
    |> Enum.reduce(%{}, fn wpid, acc ->
      send(wpid, :result)

      receive do
        {:result, ^wpid, result} ->
          Map.merge(acc, result, fn _city, {min1, max1, c1, s1}, {min2, max2, c2, s2} ->
            {min(min1, min2), max(max1, max2), c1 + c2, s1 + s2}
          end)
      end
    end)
  end

  defp dispatch_chunks(fd, chunk_size) do
    case :prim_file.read(fd, chunk_size) do
      :eof ->
        :ok

      {:ok, data} ->
        # Read one more line to complete partial line at chunk boundary
        data =
          case :prim_file.read_line(fd) do
            {:ok, line} -> <<data::binary, line::binary>>
            :eof -> data
          end

        receive do
          {:give_work, wpid} ->
            send(wpid, {:do_work, data})
        end

        dispatch_chunks(fd, chunk_size)
    end
  end
end

# Process chunks in parallel
profile_before = if profile?, do: Prof.snapshot(), else: nil
compute_started_at = Prof.now()

result = Solver.solve(file, chunk_size, workers)

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
