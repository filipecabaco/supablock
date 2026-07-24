defmodule Supablock.WriteDocs do
  @moduledoc """
  Renders the *write path* for a resource as static documentation, so an
  agent that has just read a file off the (read-only) tree knows how to
  change it instead of guessing the Management API shape.

  Two surfaces, one source of truth (`Supablock.Endpoints.mutation/1`):

    * `project_doc/1` — a `how-to-change.md` shown in every project
      directory. This is the default surface: a sibling Markdown file keeps
      the real `*.json` bodies byte-identical and `jq`-clean.

    * `maybe_prepend/3` — when the `inline_docs` config key is on, a `//`
      comment header prepended to a mutable resource's JSON body (JSONC).
      Off by default, because comments break strict JSON parsers (`jq`,
      `Jason.decode`); opt in when your agent parses with comment support.

  supablock issues none of these requests. Every command here is text the
  agent runs itself, with its own credentials, outside supablock. No secret
  or live value is ever interpolated — command bodies carry placeholders.
  """

  alias Supablock.{Config, Endpoints}

  @api_base "https://api.supabase.com"
  @reference "https://supabase.com/docs/reference/api/introduction"

  @catalogue [
    {"info.json", :project},
    {"config/auth.json", :auth_config},
    {"config/database.json", :db_config},
    {"config/disk.json", :disk_config},
    {"config/pooler.json", :pooler_config},
    {"config/postgrest.json", :postgrest_config},
    {"config/realtime.json", :realtime_config},
    {"config/storage.json", :storage_config},
    {"config/auth/sso/<provider-id>/", :sso_providers},
    {"config/auth/third-party/<integration-id>/", :third_party_auth},
    {"secrets.json", :secrets},
    {"api-keys/", :api_keys},
    {"functions/<slug>/", :function},
    {"storage/buckets/<bucket>/", :buckets},
    {"branches/<branch>/", :branches},
    {"database/backups.json", :backups},
    {"database/migrations.json", :migrations},
    {"database/readonly.json", :readonly},
    {"network/restrictions.json", :network_restrictions},
    {"network/ssl-enforcement.json", :ssl_enforcement},
    {"network/custom-hostname.json", :custom_hostname},
    {"network/vanity-subdomain.json", :vanity_subdomain},
    {"upgrade-eligibility.json", :upgrade_eligibility}
  ]

  @doc """
  Prepend the inline JSONC write-header to `body` when `inline_docs` is on
  and `endpoint` names a mutable resource; otherwise return `body` verbatim.
  Called on the render path, so with the flag off it is a no-op and output
  is unchanged pure JSON.
  """
  @spec maybe_prepend(atom, map, binary) :: binary
  def maybe_prepend(endpoint, args, body) do
    with true <- Config.get("inline_docs") == true,
         %{} = mutation <- Endpoints.mutation(endpoint),
         true <- json_body?(body) do
      comment_block(mutation, args) <> body
    else
      _no -> body
    end
  end

  defp json_body?(body), do: match?("{" <> _rest, body) or match?("[" <> _rest, body)

  @doc """
  The `how-to-change.md` body for a project: one section per mutable
  resource type, with `{ref}` filled in and per-item ids left as `<slug>`
  placeholders. Pure static text — no API request is made to build it.
  """
  @spec project_doc(String.t()) :: binary
  def project_doc(ref) do
    sections =
      @catalogue
      |> Enum.flat_map(fn {label, key} ->
        case Endpoints.mutation(key) do
          nil -> []
          mutation -> [doc_section(label, mutation, %{ref: ref})]
        end
      end)

    """
    # How to change this project

    supablock is **read-only** — it never writes to Supabase. This file lists,
    for each resource under this project, the request you can run yourself
    (with your own access token) to change it. Read the current state from the
    neighbouring files; apply changes with the commands below.

    `$SUPABASE_ACCESS_TOKEN` is your Management API token. A section whose
    URL targets the project itself (`*.supabase.co`) is not a Management API
    surface and authenticates with the project key its note names instead.
    Endpoint paths and verbs are checked against the Management API OpenAPI
    spec; confirm request bodies against the reference:
    #{@reference}

    #{Enum.join(sections, "\n")}\
    """
  end

  defp comment_block(mutation, args) do
    ([
       "supablock is read-only and will not make this change. To update this",
       "resource, run the request below yourself:",
       "",
       "  #{mutation.method} #{fill(mutation.path, args)}",
       ""
     ] ++
       Enum.map(curl(mutation, args), &("  " <> &1)) ++
       cli_lines(mutation, args) ++
       note_lines(mutation, args) ++
       ["", "Verify the request body against the Management API reference:", "  #{@reference}"])
    |> Enum.map_join("\n", fn
      "" -> "//"
      line -> "// " <> line
    end)
    |> Kernel.<>("\n\n")
  end

  defp doc_section(label, mutation, args) do
    (["## `#{label}`", "", "```bash"] ++
       curl(mutation, args) ++
       ["```"] ++
       cli_block(mutation, args) ++
       note_block(mutation, args))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp curl(mutation, args) do
    filled = fill(mutation.path, args)
    url = if String.starts_with?(filled, "https://"), do: filled, else: @api_base <> filled
    auth = mutation.auth || "$SUPABASE_ACCESS_TOKEN"

    parts =
      ["\"#{url}\"", "-H \"Authorization: Bearer #{auth}\""] ++
        if(mutation.auth, do: ["-H \"apikey: #{auth}\""], else: []) ++
        if mutation.body do
          ["-H \"Content-Type: application/json\"", "-d '{ ...only the fields you change... }'"]
        else
          []
        end

    {leading, [last]} = Enum.split(parts, -1)
    ["curl -X #{mutation.method} \\"] ++ Enum.map(leading, &("  " <> &1 <> " \\")) ++ ["  " <> last]
  end

  defp cli_lines(%{cli: nil}, _args), do: []
  defp cli_lines(%{cli: cli}, args), do: ["", "CLI: " <> fill(cli, args)]

  defp cli_block(%{cli: nil}, _args), do: []
  defp cli_block(%{cli: cli}, args), do: ["", "CLI: `#{fill(cli, args)}`"]

  defp note_lines(%{note: nil}, _args), do: []
  defp note_lines(%{note: note}, args), do: ["", fill(note, args)]

  defp note_block(%{note: nil}, _args), do: []
  defp note_block(%{note: note}, args), do: ["", "> #{fill(note, args)}"]

  defp fill(template, args) do
    template
    |> String.replace("{ref}", to_string(args[:ref] || "<ref>"))
    |> String.replace("{slug}", to_string(args[:fn_slug] || args[:slug] || "<slug>"))
  end
end
