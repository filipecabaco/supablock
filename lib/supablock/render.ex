defmodule Supablock.Render do
  @moduledoc """
  Deterministic rendering of API values into file bodies.

  JSON is pretty-printed with keys sorted recursively and a trailing newline,
  so the same resource always renders to byte-identical output — stable
  `stat` sizes and clean `diff`s across projects.
  """

  @doc "Render a decoded JSON value as sorted, pretty JSON with trailing newline."
  @spec json(term) :: binary
  def json(value) do
    Jason.encode!(sort_keys(value), pretty: true) <> "\n"
  end

  @doc """
  Render the health endpoint response as one line per service
  (`db: healthy`). Falls back to sorted JSON when the shape is unexpected.
  """
  @spec health(term) :: binary
  def health(services) when is_list(services) do
    if Enum.all?(services, &per_service?/1) do
      services
      |> Enum.map(fn service ->
        "#{service["name"]}: #{service_status(service)}\n"
      end)
      |> Enum.sort()
      |> Enum.join()
    else
      json(services)
    end
  end

  def health(other), do: json(other)

  @doc """
  Render the analytics logs response as NDJSON — one compact JSON object per
  line, in chronological order (oldest first, newest last). This makes
  `tail -n N` show the N most-recent entries and `tail -f` extend naturally.

  Sorts by `timestamp` ascending rather than trusting the API's order, so the
  chronological guarantee holds even if rows come back out of order. Returns a
  lone newline when the response shape is unexpected or empty.
  """
  @spec logs(term) :: binary
  def logs(%{"result" => rows}) when is_list(rows) do
    rows
    |> Enum.sort_by(& &1["timestamp"])
    |> Enum.map_join("\n", &Jason.encode!/1)
    |> then(&if(&1 == "", do: "\n", else: &1 <> "\n"))
  end

  def logs(_other), do: "\n"

  defp per_service?(%{"name" => name}) when is_binary(name), do: true
  defp per_service?(_other), do: false

  defp service_status(%{"healthy" => true}), do: "healthy"

  defp service_status(%{"healthy" => false} = service) do
    case service do
      %{"status" => status} when is_binary(status) -> "unhealthy (#{status})"
      _other -> "unhealthy"
    end
  end

  defp service_status(%{"status" => status}) when is_binary(status),
    do: String.downcase(status)

  defp service_status(_service), do: "unknown"

  defp sort_keys(%{} = map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {key, sort_keys(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other
end
