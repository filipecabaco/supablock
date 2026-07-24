defmodule Supablock.DashboardStub do
  @moduledoc """
  Plays the Supabase dashboard side of the browser-login handshake: given the
  CLI session's P-256 public key, derives the shared ECDH secret and returns an
  AES-256-GCM sealed token payload, exactly as the real exchange endpoint does.
  """

  @doc """
  Seal `plaintext` for `public_key` (a raw 65-byte P-256 point). Returns the
  `access_token`/`public_key`/`nonce` hex fields the CLI expects to decrypt.
  """
  def encrypt(public_key, plaintext) when is_binary(public_key) do
    {server_pub, server_priv} = :crypto.generate_key(:ecdh, :prime256v1)
    secret = :crypto.compute_key(:ecdh, public_key, server_priv, :prime256v1)
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, secret, nonce, plaintext, <<>>, 16, true)

    %{
      "access_token" => Base.encode16(ciphertext <> tag, case: :lower),
      "public_key" => Base.encode16(server_pub, case: :lower),
      "nonce" => Base.encode16(nonce, case: :lower)
    }
  end

  @doc "Like `encrypt/2` but takes a hex-encoded key and adds the poll-response envelope fields."
  def encrypt_hex(public_key_hex, plaintext) do
    {:ok, public_key} = Base.decode16(public_key_hex, case: :mixed)

    Map.merge(encrypt(public_key, plaintext), %{
      "id" => "00000000-0000-4000-8000-000000000000",
      "created_at" => "2026-01-01T00:00:00Z"
    })
  end
end
