defmodule Superblock.Database.Connections do
  @moduledoc """
  Lazily-started, reused Postgrex connections, one per project ref.

  Opening a Postgres connection is expensive, so the first query for a ref
  starts a small pool and every later query reuses it. Starts are serialized
  through this GenServer, so concurrent FUSE callbacks racing on the same ref
  cannot open duplicate pools. Connections are linked here; DBConnection
  handles its own reconnection, so a dropped socket does not need our help.
  """

  use GenServer

  require Logger

  alias Superblock.{Config, DbCredentials}

  @start_timeout 20_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Get (starting if needed) a Postgrex connection pid for `ref`.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec get(String.t()) :: {:ok, pid} | {:error, term}
  def get(ref) when is_binary(ref) do
    GenServer.call(__MODULE__, {:get, ref}, @start_timeout)
  end

  @doc "Stop and forget the connection for `ref` (e.g. after credentials change)."
  @spec forget(String.t()) :: :ok
  def forget(ref) when is_binary(ref) do
    GenServer.call(__MODULE__, {:forget, ref})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get, ref}, _from, state) do
    case Map.get(state, ref) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          start_and_reply(ref, Map.delete(state, ref))
        end

      nil ->
        start_and_reply(ref, state)
    end
  end

  @impl true
  def handle_call({:forget, ref}, _from, state) do
    case Map.pop(state, ref) do
      {pid, rest} when is_pid(pid) ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
        {:reply, :ok, rest}

      {nil, rest} ->
        {:reply, :ok, rest}
    end
  catch
    :exit, _reason -> {:reply, :ok, Map.delete(state, ref)}
  end

  defp start_and_reply(ref, state) do
    with {:ok, url} <- fetch_url(ref),
         {:ok, opts} <- __MODULE__.Opts.parse(url),
         {:ok, pid} <- Postgrex.start_link(opts) do
      {:reply, {:ok, pid}, Map.put(state, ref, pid)}
    else
      :missing -> {:reply, {:error, :not_configured}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_url(ref), do: DbCredentials.fetch(ref)

  defmodule Opts do
    @moduledoc false
    # Parse a `postgres://` URL into Postgrex.start_link/1 options. SSL is
    # driven by the `sslmode` query parameter (default `prefer`/`require`,
    # like libpq): `disable` turns SSL off; `verify-ca`/`verify-full` verify
    # the server against the OS trust store; anything else enables SSL
    # without verification (matching `sslmode=require`).

    @spec parse(String.t()) :: {:ok, keyword} | {:error, term}
    def parse(url) when is_binary(url) do
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} = uri
        when scheme in ["postgres", "postgresql"] and is_binary(host) and host != "" ->
          {:ok, build(uri)}

        _invalid ->
          {:error, :invalid_url}
      end
    end

    defp build(uri) do
      {user, pass} = userinfo(uri.userinfo)
      query = URI.decode_query(uri.query || "")

      base = [
        hostname: uri.host,
        port: uri.port || 5432,
        database: database(uri.path),
        pool_size: 2,
        timeout: Config.get("db_timeout_ms") || 15_000,
        connect_timeout: Config.get("db_timeout_ms") || 15_000
      ]

      base
      |> maybe_put(:username, user)
      |> maybe_put(:password, pass)
      |> Keyword.put(:ssl, ssl_opts(query["sslmode"], uri.host))
    end

    defp userinfo(nil), do: {nil, nil}

    defp userinfo(info) do
      case String.split(info, ":", parts: 2) do
        [user] -> {URI.decode(user), nil}
        [user, pass] -> {URI.decode(user), URI.decode(pass)}
      end
    end

    defp database(nil), do: "postgres"
    defp database("/"), do: "postgres"
    defp database("/" <> db), do: URI.decode(db)
    defp database(_other), do: "postgres"

    defp ssl_opts("disable", _host), do: false

    defp ssl_opts(mode, host) when mode in ["verify-ca", "verify-full"] do
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host),
        depth: 3
      ]
    end

    # prefer/require/allow/nil: encrypt but don't verify the certificate.
    defp ssl_opts(_mode, _host), do: [verify: :verify_none]

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, _key, ""), do: opts
    defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
  end
end
