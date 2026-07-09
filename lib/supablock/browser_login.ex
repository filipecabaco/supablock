defmodule Supablock.BrowserLogin do
  @moduledoc """
  Browser-based login replicating the official supabase CLI's flow
  (`internal/login/login.go`):

    1. generate an ephemeral ECDH P-256 keypair and a session id;
    2. send the user to `supabase.com/dashboard/cli/login` with the session
       id, a token name, and our public key;
    3. the logged-in dashboard mints a personal access token, encrypts it
       with AES-256-GCM under the ECDH shared secret, and shows the user a
       short verification code;
    4. the user types the code here; we fetch the encrypted token from
       `/platform/cli/login/{session_id}` and decrypt it locally.

  The token never crosses the network in the clear, no localhost server is
  needed, and the flow works over SSH (open the printed URL anywhere).

  Note: `/platform/*` is the same pre-`/v1` API surface the official CLI
  uses — not a documented third-party contract. If it changes upstream,
  `login --token` keeps working.
  """

  alias Supablock.Client

  @curve :prime256v1
  @dashboard_url "https://supabase.com/dashboard"

  defstruct [:session_id, :token_name, :public_key, :private_key, :url]

  @type t :: %__MODULE__{}

  @doc "Create a login session: keys, session id, and the URL to open."
  @spec new_session() :: t
  def new_session do
    {public_key, private_key} = :crypto.generate_key(:ecdh, @curve)
    session_id = uuid4()
    token_name = token_name()

    query =
      URI.encode_query(%{
        "session_id" => session_id,
        "token_name" => token_name,
        "public_key" => Base.encode16(public_key, case: :lower)
      })

    %__MODULE__{
      session_id: session_id,
      token_name: token_name,
      public_key: public_key,
      private_key: private_key,
      url: dashboard_url() <> "/cli/login?" <> query
    }
  end

  @doc """
  Exchange the verification code shown in the browser for the access token:
  fetch the encrypted payload for this session and decrypt it.
  """
  @spec fetch_token(t, String.t()) :: {:ok, String.t()} | {:error, term}
  def fetch_token(%__MODULE__{} = session, device_code) do
    path =
      "/platform/cli/login/#{session.session_id}?device_code=#{URI.encode_www_form(device_code)}"

    case Client.get(path, unauthenticated: true) do
      {:ok, %{"access_token" => token_hex, "public_key" => pub_hex, "nonce" => nonce_hex}} ->
        decrypt(token_hex, pub_hex, nonce_hex, session.private_key)

      {:ok, _unexpected} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Decrypt the dashboard's payload: AES-256-GCM (Go appends the 16-byte tag
  to the ciphertext) keyed by the ECDH shared secret.
  """
  @spec decrypt(String.t(), String.t(), String.t(), binary) ::
          {:ok, String.t()} | {:error, :decrypt_failed}
  def decrypt(token_hex, server_public_key_hex, nonce_hex, private_key) do
    with {:ok, ct_and_tag} <- Base.decode16(token_hex, case: :mixed),
         {:ok, server_public_key} <- Base.decode16(server_public_key_hex, case: :mixed),
         {:ok, nonce} <- Base.decode16(nonce_hex, case: :mixed),
         true <- byte_size(ct_and_tag) > 16 do
      secret = :crypto.compute_key(:ecdh, server_public_key, private_key, @curve)
      ct_len = byte_size(ct_and_tag) - 16
      <<ciphertext::binary-size(ct_len), tag::binary-16>> = ct_and_tag

      case :crypto.crypto_one_time_aead(:aes_256_gcm, secret, nonce, ciphertext, <<>>, tag, false) do
        :error -> {:error, :decrypt_failed}
        token when is_binary(token) -> {:ok, token}
      end
    else
      _invalid -> {:error, :decrypt_failed}
    end
  rescue
    # :crypto raises on malformed points/keys
    _any -> {:error, :decrypt_failed}
  end

  @doc "Open `url` in the default browser; failures are fine (URL is printed)."
  @spec open_browser(String.t()) :: :ok
  def open_browser(url) do
    opener =
      case :os.type() do
        {:unix, :darwin} -> "open"
        _other -> "xdg-open"
      end

    case System.find_executable(opener) do
      nil ->
        :ok

      path ->
        spawn(fn -> System.cmd(path, [url], stderr_to_stdout: true) end)
        :ok
    end
  end

  # Mirrors the official CLI: cli_<user>@<host>_<unix_ts>.
  defp token_name do
    user = System.get_env("USER") || System.get_env("LOGNAME") || "user"

    host =
      case :inet.gethostname() do
        {:ok, hostname} -> to_string(hostname)
        _error -> "host"
      end

    "supablock_#{user}@#{host}_#{System.os_time(:second)}"
  end

  defp dashboard_url do
    System.get_env("SUPABLOCK_DASHBOARD_URL") || @dashboard_url
  end

  defp uuid4 do
    import Bitwise

    <<a::binary-4, b::binary-2, c::16, d::16, e::binary-6>> = :crypto.strong_rand_bytes(16)
    c = band(c, 0x0FFF) |> bor(0x4000)
    d = band(d, 0x3FFF) |> bor(0x8000)

    [a, b, <<c::16>>, <<d::16>>, e]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end
