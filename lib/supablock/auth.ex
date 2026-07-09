defmodule Supablock.Auth do
  @moduledoc """
  Token validation against the Management API (one `GET /v1/organizations`).
  """

  alias Supablock.{Client, Endpoints}

  @doc """
  Validate `token` (or the stored credential when nil). Returns
  `{:ok, org_count}`, or the client error.
  """
  @spec validate(String.t() | nil) :: {:ok, non_neg_integer} | {:error, Client.reason()}
  def validate(token \\ nil) do
    opts = if token, do: [token: token], else: []

    case Client.get(Endpoints.path(:orgs), opts) do
      {:ok, orgs} when is_list(orgs) -> {:ok, length(orgs)}
      {:ok, _other} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end
end
