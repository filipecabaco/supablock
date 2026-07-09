defmodule Supablock.Client do
  @moduledoc """
  Read-only HTTP client for the Supabase Management API.

  Hard rules honoured here:

    * only `GET` is ever issued;
    * every request runs under a hard deadline (`http_timeout_ms`, default
      8000ms) — the whole call, retries included, is killed when the budget
      runs out and the caller gets `{:error, :timeout}`;
    * a `429` is retried only if the server's `Retry-After` fits inside the
      remaining budget, otherwise `{:error, :rate_limited}` immediately;
    * the token never leaks: nothing here logs headers, and `redact/1`
      scrubs the token from anything that does get logged.
  """

  require Logger

  alias Supablock.Config

  @base_url "https://api.supabase.com"
  @ratelimit_table :supablock_ratelimit

  @type reason ::
          :unauthorized
          | :forbidden
          | :not_found
          | :rate_limited
          | :timeout
          | {:http, non_neg_integer}
          | {:transport, term}

  @spec get(String.t(), keyword) :: {:ok, term} | {:error, reason}
  def get(path, opts \\ []) do
    case fetch_token(opts) do
      {:ok, token} ->
        case get_with_token(path, token, opts) do
          {:error, :unauthorized} = error ->
            retry_after_refresh(path, token, opts, error)

          result ->
            result
        end

      :missing ->
        {:error, :unauthorized}
    end
  end

  # A stored OAuth token the API just rejected may simply have expired:
  # rotate it once (single-flight via TokenStore) and retry. Explicit tokens
  # and unauthenticated calls never retry.
  defp retry_after_refresh(path, failed_token, opts, error) do
    stored? =
      is_binary(failed_token) and opts[:token] == nil and
        not Keyword.get(opts, :unauthenticated, false)

    with true <- stored?,
         {:ok, new_token} when new_token != failed_token <-
           Supablock.TokenStore.after_401(failed_token) do
      get_with_token(path, new_token, opts)
    else
      _no_rotation -> error
    end
  end

  defp fetch_token(opts) do
    cond do
      Keyword.get(opts, :unauthenticated, false) ->
        {:ok, nil}

      is_binary(opts[:token]) and opts[:token] != "" ->
        {:ok, opts[:token]}

      true ->
        # TokenStore (not Credentials directly): OAuth credentials refresh
        # transparently, serialized through one process.
        Supablock.TokenStore.access_token()
    end
  end

  # Testing escape hatch only: the e2e suite points the release at a local
  # stub API. Real usage never sets either override.
  @doc false
  def base_url do
    case System.get_env("SUPABLOCK_API_URL") do
      url when is_binary(url) and url != "" ->
        url

      _unset ->
        Application.get_env(:supablock, :base_url, @base_url)
    end
  end

  defp get_with_token(path, token, opts) do
    budget_ms = Keyword.get(opts, :timeout_ms) || Config.get("http_timeout_ms") || 8_000
    deadline = System.monotonic_time(:millisecond) + budget_ms

    task = Task.async(fn -> run_request(path, token, budget_ms, deadline) end)

    case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.debug("supablock: request #{path} crashed: #{inspect(redact(reason, token))}")
        {:error, {:transport, :crashed}}

      nil ->
        Logger.debug("supablock: request #{path} exceeded #{budget_ms}ms deadline")
        {:error, :timeout}
    end
  end

  defp run_request(path, token, budget_ms, deadline) do
    req =
      Req.new(
        base_url: base_url(),
        url: path,
        receive_timeout: budget_ms,
        connect_options: connect_options(budget_ms),
        retry: &retry_decision(&1, &2, deadline),
        retry_log_level: false,
        max_retries: 3
      )
      |> then(fn req ->
        # nil = deliberately unauthenticated (the login polling endpoint).
        if token, do: Req.merge(req, auth: {:bearer, token}), else: req
      end)
      |> apply_test_plug()

    case Req.request(req) do
      {:ok, %Req.Response{} = resp} ->
        record_ratelimit(path, resp)
        interpret(resp)

      {:error, %{__exception__: true} = error} ->
        Logger.debug(
          "supablock: request #{path} failed: #{redact(Exception.message(error), token)}"
        )

        {:error, transport_reason(error)}
    end
  catch
    kind, error ->
      Logger.debug("supablock: request #{path} raised: #{inspect(redact({kind, error}, token))}")
      {:error, {:transport, kind}}
  end

  defp apply_test_plug(req) do
    case Application.get_env(:supablock, :req_plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug, retry: false)
    end
  end

  @doc false
  def connect_options(budget_ms) do
    base = [timeout: min(budget_ms, 5_000)]

    case proxy_from_env() do
      nil -> base
      proxy -> [{:proxy, proxy} | base]
    end
  end

  defp proxy_from_env do
    with url when is_binary(url) and url != "" <-
           System.get_env("HTTPS_PROXY") || System.get_env("https_proxy"),
         false <- proxy_excluded?(URI.parse(base_url()).host),
         %URI{host: host, port: port} when is_binary(host) and is_integer(port) <-
           URI.parse(url) do
      {:http, host, port, []}
    else
      _other -> nil
    end
  end

  # Standard NO_PROXY semantics, plus loopback never goes through a proxy.
  defp proxy_excluded?(nil), do: true
  defp proxy_excluded?(host) when host in ["localhost", "127.0.0.1", "::1"], do: true

  defp proxy_excluded?(host) do
    (System.get_env("NO_PROXY") || System.get_env("no_proxy") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.any?(fn entry ->
      suffix = String.trim_leading(entry, ".")
      entry != "" and (host == entry or String.ends_with?(host, "." <> suffix))
    end)
  end

  defp retry_decision(_req, %Req.Response{status: 429} = resp, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case retry_after_ms(resp) do
      wait_ms when is_integer(wait_ms) and wait_ms >= 0 and wait_ms < remaining ->
        {:delay, wait_ms}

      _too_late ->
        false
    end
  end

  defp retry_decision(_req, %Req.Response{status: status}, deadline)
       when status in [408, 500, 502, 503, 504] do
    transient_retry(deadline)
  end

  defp retry_decision(_req, %Req.Response{}, _deadline), do: false

  defp retry_decision(_req, %{__exception__: true}, deadline) do
    transient_retry(deadline)
  end

  defp transient_retry(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 500, do: {:delay, 200}, else: false
  end

  defp retry_after_ms(resp) do
    case Req.Response.get_header(resp, "retry-after") do
      [value | _rest] ->
        case Integer.parse(value) do
          {seconds, _rest} -> seconds * 1_000
          :error -> nil
        end

      [] ->
        case Req.Response.get_header(resp, "x-ratelimit-reset") do
          [value | _rest] ->
            case Integer.parse(value) do
              # Could be epoch seconds or delta seconds; treat small values
              # as deltas and anything else as "too far away".
              {seconds, _rest} when seconds < 3_600 -> seconds * 1_000
              _other -> nil
            end

          [] ->
            nil
        end
    end
  end

  defp interpret(%Req.Response{status: 200, body: body}), do: {:ok, decode_body(body)}
  defp interpret(%Req.Response{status: 401}), do: {:error, :unauthorized}
  defp interpret(%Req.Response{status: 403}), do: {:error, :forbidden}
  defp interpret(%Req.Response{status: 404}), do: {:error, :not_found}
  defp interpret(%Req.Response{status: 429}), do: {:error, :rate_limited}
  defp interpret(%Req.Response{status: status}), do: {:error, {:http, status}}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_body(body), do: body

  defp transport_reason(%{reason: :timeout}), do: :timeout
  defp transport_reason(%{reason: reason}), do: {:transport, reason}
  defp transport_reason(error), do: {:transport, error.__struct__}

  ## Rate limit bookkeeping

  defp record_ratelimit(path, resp) do
    remaining = first_int_header(resp, ["x-ratelimit-remaining", "ratelimit-remaining"])
    reset = first_int_header(resp, ["x-ratelimit-reset", "ratelimit-reset", "retry-after"])

    if remaining != nil and :ets.whereis(@ratelimit_table) != :undefined do
      :ets.insert(@ratelimit_table, {scope_for(path), remaining, reset})
    end

    :ok
  rescue
    _any -> :ok
  end

  defp first_int_header(resp, names) do
    Enum.find_value(names, fn name ->
      case Req.Response.get_header(resp, name) do
        [value | _rest] ->
          case Integer.parse(value) do
            {n, _rest} -> n
            :error -> nil
          end

        [] ->
          nil
      end
    end)
  end

  @doc "Rate-limit scope for an API path: project ref, org slug, or \"user\"."
  def scope_for(path) do
    case String.split(path, ["/", "?"], trim: true) do
      ["v1", "projects", ref | _rest] when ref != "available-regions" -> ref
      ["v1", "organizations", slug | _rest] -> slug
      _other -> "user"
    end
  end

  @doc "Last-seen rate limit info per scope, from this VM's requests."
  def ratelimits do
    if :ets.whereis(@ratelimit_table) != :undefined do
      :ets.tab2list(@ratelimit_table)
    else
      []
    end
  end

  @doc """
  Scrub the access token (and any Authorization header value) from a term
  that is about to be logged or inspected.
  """
  def redact(term, token \\ nil)

  def redact(term, token) when is_binary(term) do
    term
    |> then(fn s -> if token, do: String.replace(s, token, "sbp_…"), else: s end)
    |> String.replace(~r/Bearer\s+\S+/, "Bearer sbp_…")
    |> String.replace(~r/sbp_[A-Za-z0-9_-]+/, "sbp_…")
    |> String.replace(~r/oauth_refresh_[A-Za-z0-9_-]+/, "oauth_refresh_…")
  end

  def redact(term, token) do
    term
    |> inspect(limit: 50, printable_limit: 4096)
    |> redact(token)
  end
end
