defmodule Superblock.Render do
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
