# Parse args
{opts, _} = OptionParser.parse!(System.argv(), strict: [file: :string])
file = opts[:file] || "data/measurements.1000000000.txt"

chunk_size = 1_048_576  # 1 MB chunks

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

# Read file in binary chunks, handle line boundaries
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

# Process chunks in parallel, each returns a local map, merge at end
result =
  Chunker.stream(file, chunk_size)
  |> Task.async_stream(
    fn lines ->
      Enum.reduce(lines, %{}, fn line, acc ->
        case :binary.split(line, ";") do
          [city, temp_bin] when city != "" and temp_bin != "" ->
            temp = Parse.temp(temp_bin)

            Map.update(acc, city, {temp, temp, 1, temp}, fn {min, max, count, sum} ->
              {min(min, temp), max(max, temp), count + 1, sum + temp}
            end)

          _ ->
            acc
        end
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

# Format output
output =
  result
  |> Enum.sort_by(fn {city, _} -> city end)
  |> Enum.map(fn {city, {min, max, count, sum}} ->
    mean = Format.round_div(sum, count)
    "#{city}=#{Format.tenths(min)}/#{Format.tenths(mean)}/#{Format.tenths(max)}"
  end)
  |> Enum.join(", ")

IO.puts("{#{output}}")
