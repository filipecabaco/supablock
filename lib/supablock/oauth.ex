defmodule Supablock.OAuth do
  @moduledoc """
  OAuth2 against the documented Management API endpoints, following the
  "Build a Supabase Integration" guide:

    * `GET /v1/oauth/authorize` — authorization-code flow with **PKCE S256**
      and a `state` parameter, redirecting to a loopback callback
      (`http://localhost:53682/callback`, served by `Supablock.AuthCallback`);
    * `POST /v1/oauth/token` — code exchange and refresh, client id + secret
      as basic auth, form-urlencoded (per the guide);
    * `POST /v1/oauth/revoke` — used by `supablock logout` to kill the
      authorization server-side.

  These token-endpoint POSTs are the only non-GET requests supablock ever
  makes, and they touch the OAuth session itself — never account resources.
  With the OAuth app registered read-only, the read-only guarantee is
  enforced server-side, not just promised client-side.

  The client id/secret identify the app, not the user; in a distributed CLI
  they are not confidential (standard public-client reality — PKCE and the
  loopback-only redirect are what protect the flow). Resolution order:
  `supablock config set oauth.client_id/…client_secret` → the
  `SUPABLOCK_OAUTH_CLIENT_ID`/`_SECRET` environment variables → the app
  identity **baked in at build time** (CI injects the released supablock
  OAuth app's credentials, so `supablock login` needs zero configuration —
  the same way gh/gcloud ship theirs).
  """

  alias Supablock.{Client, Config}

  @callback_port 53682
  @redirect_path "/callback"
  @timeout_ms 8_000

  @baked_client_id System.get_env("SUPABLOCK_OAUTH_CLIENT_ID")
  @baked_client_secret System.get_env("SUPABLOCK_OAUTH_CLIENT_SECRET")

  defstruct [:state, :verifier, :url, :redirect_uri]

  @type t :: %__MODULE__{}
  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: non_neg_integer
        }

  @spec configured?() :: boolean
  def configured?, do: present?(client_id()) and present?(client_secret())

  @spec callback_port() :: pos_integer
  def callback_port, do: @callback_port

  @doc "Build a login request: PKCE pair, state, and the authorize URL."
  @spec new_request() :: t
  def new_request do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    redirect_uri = "http://localhost:#{@callback_port}#{@redirect_path}"

    query =
      URI.encode_query(%{
        "client_id" => client_id(),
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    %__MODULE__{
      state: state,
      verifier: verifier,
      redirect_uri: redirect_uri,
      url: Client.base_url() <> "/v1/oauth/authorize?" <> query
    }
  end

  @doc "Exchange the authorization code (with the PKCE verifier) for tokens."
  @spec exchange_code(t, String.t()) :: {:ok, tokens} | {:error, term}
  def exchange_code(%__MODULE__{} = request, code) when is_binary(code) do
    post_token(%{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => request.redirect_uri,
      "code_verifier" => request.verifier
    })
  end

  @doc """
  Refresh the token pair. Supabase refresh tokens are **single-use**: the
  response carries a new refresh token and the old one is dead — callers
  (`Supablock.TokenStore`) must persist the new pair before doing anything
  else.
  """
  @spec refresh(String.t()) :: {:ok, tokens} | {:error, term}
  def refresh(refresh_token) when is_binary(refresh_token) do
    case post_token(%{"grant_type" => "refresh_token", "refresh_token" => refresh_token}) do
      {:ok, tokens} ->
        {:ok, tokens}

      {:error, status} when status in [:unauthorized, {:http, 400}, {:http, 403}] ->
        {:error, :reauth_required}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Revoke the whole authorization server-side (used by logout). Best effort."
  @spec revoke(String.t()) :: :ok | {:error, term}
  def revoke(refresh_token) when is_binary(refresh_token) do
    request =
      base_req()
      |> Req.merge(
        url: "/v1/oauth/revoke",
        method: :post,
        json: %{
          "client_id" => client_id(),
          "client_secret" => client_secret(),
          "refresh_token" => refresh_token
        }
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 204}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, _exception} -> {:error, :transport}
    end
  end

  defp post_token(form) do
    request =
      base_req()
      |> Req.merge(
        url: "/v1/oauth/token",
        method: :post,
        form: form,
        auth: {:basic, "#{client_id()}:#{client_secret()}"}
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..201 ->
        parse_tokens(body)

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, %{__exception__: true} = error} ->
        {:error, {:transport, transport_reason(error)}}
    end
  end

  defp base_req do
    Req.new(
      base_url: Client.base_url(),
      receive_timeout: @timeout_ms,
      connect_options: Client.connect_options(@timeout_ms),
      retry: false
    )
    |> Client.apply_test_plug()
  end

  defp parse_tokens(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_tokens(decoded)
      {:error, _reason} -> {:error, :unexpected_response}
    end
  end

  defp parse_tokens(%{"access_token" => access, "refresh_token" => refresh} = body)
       when is_binary(access) and is_binary(refresh) do
    expires_in =
      case body["expires_in"] do
        seconds when is_integer(seconds) and seconds > 0 -> seconds
        _missing -> 3_600
      end

    {:ok,
     %{
       access_token: access,
       refresh_token: refresh,
       expires_at: System.os_time(:second) + expires_in
     }}
  end

  defp parse_tokens(_other), do: {:error, :unexpected_response}

  defp transport_reason(%{reason: reason}), do: reason
  defp transport_reason(error), do: error.__struct__

  @doc false
  def client_id do
    presence(Config.get("oauth.client_id")) ||
      presence(System.get_env("SUPABLOCK_OAUTH_CLIENT_ID")) ||
      presence(@baked_client_id)
  end

  @doc false
  def client_secret do
    presence(Config.get("oauth.client_secret")) ||
      presence(System.get_env("SUPABLOCK_OAUTH_CLIENT_SECRET")) ||
      presence(@baked_client_secret)
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_other), do: nil

  defp present?(value), do: presence(value) != nil
end
