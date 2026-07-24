defmodule Supablock.Router do
  @moduledoc """
  Maps filesystem paths to Management API resources. Pure logic plus cache
  calls — no FUSE types leak in here.

  Tree:

      /
        organizations/
          <org-slug>/
            info.json
            members.json
            regions.json
            projects/
              <project-ref>/
                info.json
                health
                advisors/security.json         # advisor lints (RLS off, slow queries, …)
                advisors/performance.json
                config/auth.json
                config/database.json
                config/disk.json
                config/pgbouncer.json
                config/pooler.json
                config/postgrest.json
                config/realtime.json
                config/storage.json
                config/auth/sso/<provider-id>/info.json
                config/auth/third-party/<integration-id>/info.json
                api-keys/publishable
                api-keys/secret
                secrets.json                   # edge-function secret names (values REDACTED)
                network/restrictions.json
                network/ssl-enforcement.json
                network/custom-hostname.json   # `{}` when never configured
                network/vanity-subdomain.json
                functions/<fn-slug>/info.json
                functions/<fn-slug>/body       # raw eszip bundle
                storage/buckets/<bucket>/info.json
                branches/<branch>/info.json
                database/                    # every project; rows served via its Data API
                  backups.json               # Management API: backup schedule + restore points
                  migrations.json            # applied migrations (version + name)
                  readonly.json              # read-only mode status
                  <schema>/
                    <table>/
                      schema.json            # columns, types, primary key
                      rows-000000.csv        # rows 0..page_size-1
                      rows-000500.csv        # ...
                types.ts                     # generated TypeScript types
                upgrade-eligibility.json     # `{}` when unavailable
                how-to-change.md             # write path per resource (supablock stays read-only)

  Dynamic segments are validated against the cached parent listing, so a
  bogus name is a cheap `:enoent` (plus negative caching) rather than an API
  call. Sizes come from rendering, which is deterministic, so `stat` is
  stable.
  """

  alias Supablock.{Cache, Client, Config, Database, Endpoints, Logs, Metrics, Render, WriteDocs}

  @type node_kind :: :dir | {:file, non_neg_integer}
  @type error :: :enoent | :eio | :eagain | :eacces

  @project_children ~w(info.json health advisors config api-keys secrets.json functions storage branches database network logs metrics types.ts upgrade-eligibility.json how-to-change.md)
  @config_children ~w(auth.json database.json disk.json pgbouncer.json pooler.json postgrest.json realtime.json storage.json auth)
  @auth_config_children ~w(sso third-party)
  @api_key_children ~w(publishable secret)
  @advisor_children ~w(performance.json security.json)
  @network_children ~w(custom-hostname.json restrictions.json ssl-enforcement.json vanity-subdomain.json)
  @database_files ~w(backups.json migrations.json readonly.json)

  @project_json_leaves %{
    ["config", "auth.json"] => :auth_config,
    ["config", "database.json"] => :db_config,
    ["config", "disk.json"] => :disk_config,
    ["config", "pgbouncer.json"] => :pgbouncer_config,
    ["config", "pooler.json"] => :pooler_config,
    ["config", "postgrest.json"] => :postgrest_config,
    ["config", "realtime.json"] => :realtime_config,
    ["config", "storage.json"] => :storage_config,
    ["advisors", "security.json"] => :advisors_security,
    ["advisors", "performance.json"] => :advisors_performance,
    ["network", "restrictions.json"] => :network_restrictions,
    ["network", "ssl-enforcement.json"] => :ssl_enforcement
  }
  @project_json_paths Map.keys(@project_json_leaves)

  @project_optional_leaves %{
    ["network", "custom-hostname.json"] => :custom_hostname,
    ["network", "vanity-subdomain.json"] => :vanity_subdomain,
    ["upgrade-eligibility.json"] => :upgrade_eligibility
  }
  @project_optional_paths Map.keys(@project_optional_leaves)

  @database_json_leaves %{
    ["backups.json"] => :backups,
    ["migrations.json"] => :migrations,
    ["readonly.json"] => :readonly
  }
  @database_json_paths Map.keys(@database_json_leaves)

  @redacted_body "REDACTED — run: supablock config set expose_secrets true\n"

  @spec describe(String.t()) :: {:ok, node_kind} | {:error, error}
  def describe(path) do
    case resolve(segments(path)) do
      {:dir, _lister} -> {:ok, :dir}
      {:file, render} -> with {:ok, body} <- run_render(render), do: {:ok, {:file, byte_size(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `describe/1` but never renders a file body — classification costs
  only the (cached) parent listings. This is what the no-mount walkers
  (`find`, `grep`) use, so a walk stays as cheap as `ls -R`.
  """
  @spec kind(String.t()) :: {:ok, :dir | :file} | {:error, error}
  def kind(path) do
    case resolve(segments(path)) do
      {:dir, _lister} -> {:ok, :dir}
      {:file, _render} -> {:ok, :file}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, error}
  def list(path) do
    case resolve(segments(path)) do
      {:dir, lister} -> lister.()
      {:file, _render} -> {:error, :eio}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read(String.t()) :: {:ok, binary} | {:error, error}
  def read(path) do
    case resolve(segments(path)) do
      {:file, render} -> run_render(render)
      {:dir, _lister} -> {:error, :eio}
      {:error, reason} -> {:error, reason}
    end
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp resolve([]) do
    {:dir, fn -> {:ok, ["organizations"]} end}
  end

  defp resolve(["organizations"]) do
    {:dir, fn -> with {:ok, entries} <- org_entries(), do: {:ok, names(entries)} end}
  end

  defp resolve(["organizations", org_name | rest]) do
    with_entry(org_entries(), org_name, fn org -> resolve_org(org, rest) end)
  end

  defp resolve(_unknown), do: {:error, :enoent}

  defp resolve_org(_org, []) do
    {:dir, fn -> {:ok, ["info.json", "members.json", "projects", "regions.json"]} end}
  end

  defp resolve_org(org, ["info.json"]), do: file(:org, %{slug: org_slug(org)}, &Render.json/1)

  defp resolve_org(org, ["regions.json"]),
    do: file(:regions, %{slug: org_slug(org)}, &Render.json/1)

  defp resolve_org(org, ["members.json"]),
    do: file(:org_members, %{slug: org_slug(org)}, &Render.json/1)

  defp resolve_org(org, ["projects"]) do
    {:dir, fn -> with {:ok, entries} <- project_entries(org), do: {:ok, names(entries)} end}
  end

  defp resolve_org(org, ["projects", ref_name | rest]) do
    with_entry(project_entries(org), ref_name, fn project ->
      resolve_project(project, rest)
    end)
  end

  defp resolve_org(_org, _rest), do: {:error, :enoent}

  defp resolve_project(_project, []) do
    {:dir, fn -> {:ok, @project_children} end}
  end

  defp resolve_project(project, ["info.json"]),
    do: file(:project, %{ref: project_ref(project)}, &Render.json/1)

  defp resolve_project(project, ["health"]),
    do: file(:health, %{ref: project_ref(project)}, &Render.health/1)

  defp resolve_project(_project, ["config"]) do
    {:dir, fn -> {:ok, @config_children} end}
  end

  defp resolve_project(_project, ["config", "auth"]) do
    {:dir, fn -> {:ok, @auth_config_children} end}
  end

  defp resolve_project(project, ["config", "auth", "sso"]) do
    {:dir, fn -> with {:ok, entries} <- sso_entries(project), do: {:ok, names(entries)} end}
  end

  defp resolve_project(project, ["config", "auth", "sso", provider_id | rest]) do
    with_entry(sso_entries(project), provider_id, fn provider ->
      resolve_listed(provider, rest)
    end)
  end

  defp resolve_project(project, ["config", "auth", "third-party"]) do
    {:dir, fn -> with {:ok, entries} <- tpa_entries(project), do: {:ok, names(entries)} end}
  end

  defp resolve_project(project, ["config", "auth", "third-party", integration_id | rest]) do
    with_entry(tpa_entries(project), integration_id, fn integration ->
      resolve_listed(integration, rest)
    end)
  end

  defp resolve_project(_project, ["api-keys"]) do
    {:dir, fn -> {:ok, @api_key_children} end}
  end

  defp resolve_project(project, ["api-keys", "publishable"]) do
    file(:api_keys, %{ref: project_ref(project)}, &render_api_keys(&1, :publishable))
  end

  defp resolve_project(project, ["api-keys", "secret"]) do
    if Config.get("expose_secrets") do
      file(:api_keys, %{ref: project_ref(project), reveal: true}, &render_api_keys(&1, :secret))
    else
      {:file, fn -> {:ok, @redacted_body} end}
    end
  end

  defp resolve_project(_project, ["advisors"]) do
    {:dir, fn -> {:ok, @advisor_children} end}
  end

  defp resolve_project(_project, ["network"]) do
    {:dir, fn -> {:ok, @network_children} end}
  end

  defp resolve_project(project, ["types.ts"]),
    do:
      file(:typescript_types, %{ref: project_ref(project)}, &Render.typescript/1,
        timeout_ms: 30_000
      )

  defp resolve_project(project, ["how-to-change.md"]),
    do: {:file, fn -> {:ok, WriteDocs.project_doc(project_ref(project))} end}

  defp resolve_project(project, ["secrets.json"]),
    do: file(:secrets, %{ref: project_ref(project)}, &render_secrets/1)

  defp resolve_project(project, ["functions"]) do
    {:dir, fn -> with {:ok, entries} <- function_entries(project), do: {:ok, names(entries)} end}
  end

  defp resolve_project(project, ["functions", fn_name | rest]) do
    with_entry(function_entries(project), fn_name, fn function ->
      resolve_function(project, function, rest)
    end)
  end

  defp resolve_project(_project, ["storage"]) do
    {:dir, fn -> {:ok, ["buckets"]} end}
  end

  defp resolve_project(project, ["storage", "buckets"]) do
    {:dir, fn -> with {:ok, entries} <- bucket_entries(project), do: {:ok, names(entries)} end}
  end

  defp resolve_project(project, ["storage", "buckets", bucket_name | rest]) do
    with_entry(bucket_entries(project), bucket_name, fn bucket ->
      resolve_listed(bucket, rest)
    end)
  end

  defp resolve_project(_project, ["storage" | _rest]), do: {:error, :enoent}

  defp resolve_project(project, ["branches"]) do
    {:dir, fn -> with {:ok, entries} <- branch_entries(project), do: {:ok, names(entries)} end}
  end

  defp resolve_project(project, ["branches", branch_name | rest]) do
    with_entry(branch_entries(project), branch_name, fn branch ->
      resolve_listed(branch, rest)
    end)
  end

  defp resolve_project(project, ["database" | rest]) do
    resolve_database(project_ref(project), rest)
  end

  defp resolve_project(_project, ["logs"]) do
    {:dir, fn -> {:ok, Logs.sources()} end}
  end

  defp resolve_project(project, ["logs", source]) do
    if Logs.valid_source?(source) do
      ref = project_ref(project)

      {:file,
       fn ->
         case Logs.fetch(ref, source) do
           {:ok, data} -> {:ok, Render.logs(data)}
           {:error, reason} -> {:error, map_error(reason)}
         end
       end}
    else
      {:error, :enoent}
    end
  end

  defp resolve_project(_project, ["logs" | _rest]), do: {:error, :enoent}

  defp resolve_project(project, ["metrics"]) do
    ref = project_ref(project)

    {:file,
     fn ->
       case Metrics.fetch(ref) do
         {:ok, body} -> {:ok, body}
         {:error, reason} -> {:error, map_error(reason)}
       end
     end}
  end

  defp resolve_project(project, segs) when segs in @project_json_paths,
    do: file(Map.fetch!(@project_json_leaves, segs), %{ref: project_ref(project)}, &Render.json/1)

  defp resolve_project(project, segs) when segs in @project_optional_paths,
    do: optional_file(Map.fetch!(@project_optional_leaves, segs), %{ref: project_ref(project)})

  defp resolve_project(_project, _rest), do: {:error, :enoent}

  defp resolve_database(ref, []) do
    {:dir,
     fn ->
       case Database.schemas(ref) do
         {:ok, schemas} ->
           {:ok, @database_files ++ string_names(schemas)}

         {:error, _reason} ->
           {:ok, @database_files}
       end
     end}
  end

  defp resolve_database(ref, segs) when segs in @database_json_paths,
    do: file(Map.fetch!(@database_json_leaves, segs), %{ref: ref}, &Render.json/1)

  defp resolve_database(ref, [schema_seg | rest]) do
    with {:ok, schemas} <- Database.schemas(ref),
         {:ok, schema} <- pick(schemas, schema_seg) do
      resolve_schema(ref, schema, rest)
    end
  end

  defp resolve_schema(ref, schema, []) do
    {:dir,
     fn -> with {:ok, tables} <- Database.tables(ref, schema), do: {:ok, string_names(tables)} end}
  end

  defp resolve_schema(ref, schema, [table_seg | rest]) do
    with {:ok, tables} <- Database.tables(ref, schema),
         {:ok, table} <- pick(tables, table_seg) do
      resolve_table(ref, schema, table, rest)
    end
  end

  defp resolve_table(ref, schema, table, []) do
    {:dir,
     fn ->
       with {:ok, count} <- Database.row_count(ref, schema, table) do
         {:ok, ["schema.json" | page_filenames(count)]}
       end
     end}
  end

  defp resolve_table(ref, schema, table, ["schema.json"]) do
    {:file, fn -> Database.table_schema(ref, schema, table) end}
  end

  defp resolve_table(ref, schema, table, [file]) do
    with {:ok, format, offset} <- parse_page_file(file),
         {:ok, count} <- Database.row_count(ref, schema, table),
         true <- valid_offset?(offset, count) do
      {:file, fn -> Database.render_page(ref, schema, table, offset, format) end}
    else
      {:error, reason} when reason in [:eio, :eagain, :eacces, :enoent] -> {:error, reason}
      _other -> {:error, :enoent}
    end
  end

  defp resolve_table(_ref, _schema, _table, _rest), do: {:error, :enoent}

  defp string_entries(names), do: entries(names, & &1)
  defp string_names(names), do: names(string_entries(names))

  defp pick(names, seg) do
    case List.keyfind(string_entries(names), seg, 0) do
      {^seg, name} -> {:ok, name}
      nil -> {:error, :enoent}
    end
  end

  defp page_filenames(count) do
    size = Database.page_size()
    pages = div(count + size - 1, size)
    max_offset = if pages <= 1, do: 0, else: (pages - 1) * size
    width = max(6, String.length(Integer.to_string(max_offset)))
    ext = to_string(Database.format())

    for page <- 0..(pages - 1)//1 do
      offset = page * size
      "rows-" <> String.pad_leading(Integer.to_string(offset), width, "0") <> "." <> ext
    end
  end

  defp parse_page_file(file) do
    case Regex.run(~r/^rows-(\d+)\.(csv|json)$/, file) do
      [_all, digits, "csv"] -> {:ok, :csv, String.to_integer(digits)}
      [_all, digits, "json"] -> {:ok, :json, String.to_integer(digits)}
      _no_match -> {:error, :enoent}
    end
  end

  defp valid_offset?(offset, count) do
    size = Database.page_size()
    rem(offset, size) == 0 and offset >= 0 and offset < count
  end

  defp resolve_function(_project, _function, []) do
    {:dir, fn -> {:ok, ["body", "info.json"]} end}
  end

  defp resolve_function(project, function, ["info.json"]) do
    file(:function, function_args(project, function), &Render.json/1)
  end

  defp resolve_function(project, function, ["body"]) do
    file(:function_body, function_args(project, function), &raw_body/1)
  end

  defp resolve_function(_project, _function, _rest), do: {:error, :enoent}

  defp function_args(project, function) do
    %{ref: project_ref(project), fn_slug: to_string(function["slug"] || function["id"])}
  end

  defp raw_body(body) when is_binary(body), do: body
  defp raw_body(body), do: Render.json(body)

  defp resolve_listed(_item, []) do
    {:dir, fn -> {:ok, ["info.json"]} end}
  end

  defp resolve_listed(item, ["info.json"]) do
    {:file, fn -> {:ok, Render.json(item)} end}
  end

  defp resolve_listed(_item, _rest), do: {:error, :enoent}

  defp file(endpoint, args, render_fun, opts \\ []) do
    {:file,
     fn ->
       with {:ok, value} <- fetch(endpoint, args, opts) do
         {:ok, WriteDocs.maybe_prepend(endpoint, args, render_fun.(value))}
       end
     end}
  end

  defp optional_file(endpoint, args) do
    {:file,
     fn ->
       case fetch(endpoint, args) do
         {:ok, value} ->
           {:ok, WriteDocs.maybe_prepend(endpoint, args, Render.json(value))}

         {:error, reason} when reason in [:enoent, :eacces] ->
           {:ok, WriteDocs.maybe_prepend(endpoint, args, "{}\n")}

         {:error, reason} ->
           {:error, reason}
       end
     end}
  end

  defp run_render(render) when is_function(render, 0), do: render.()

  defp render_api_keys(keys, kind) when is_list(keys) do
    entries =
      keys
      |> Enum.filter(fn key -> Database.classify_key(key) == kind end)
      |> Enum.map(fn key ->
        {to_string(key["name"] || key["id"]), to_string(key["api_key"] || "")}
      end)

    case entries do
      [] -> "\n"
      [{_name, value}] -> value <> "\n"
      many -> Enum.map_join(many, fn {name, value} -> "#{name}: #{value}\n" end)
    end
  end

  defp render_api_keys(other, _kind), do: Render.json(other)

  defp render_secrets(secrets) when is_list(secrets) do
    if Config.get("expose_secrets") do
      Render.json(secrets)
    else
      secrets
      |> Enum.map(fn
        %{} = secret -> Map.replace(secret, "value", "REDACTED")
        other -> other
      end)
      |> Render.json()
    end
  end

  defp render_secrets(other), do: Render.json(other)

  defp org_entries do
    with {:ok, orgs} <- fetch(:orgs, %{}) do
      {:ok, entries(orgs, &org_slug/1)}
    end
  end

  defp project_entries(org) do
    with {:ok, projects} <- fetch(:projects, %{}) do
      ids = [to_string(org["id"] || ""), to_string(org["slug"] || "")]

      projects
      |> Enum.filter(fn project ->
        link = to_string(project["organization_id"] || project["organization_slug"] || "")
        link != "" and link in ids
      end)
      |> entries(&project_ref/1)
      |> then(&{:ok, &1})
    end
  end

  defp function_entries(project) do
    with {:ok, functions} <- fetch(:functions, %{ref: project_ref(project)}) do
      {:ok, entries(functions, fn f -> to_string(f["slug"] || f["id"]) end)}
    end
  end

  defp branch_entries(project) do
    with {:ok, branches} <- fetch(:branches, %{ref: project_ref(project)}) do
      {:ok, entries(branches, fn b -> to_string(b["name"] || b["id"]) end)}
    end
  end

  defp bucket_entries(project) do
    with {:ok, buckets} <- fetch(:buckets, %{ref: project_ref(project)}) do
      {:ok, entries(to_list(buckets), fn b -> to_string(b["name"] || b["id"]) end)}
    end
  end

  defp sso_entries(project) do
    case fetch(:sso_providers, %{ref: project_ref(project)}) do
      {:ok, providers} -> {:ok, entries(to_list(providers), &to_string(&1["id"]))}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tpa_entries(project) do
    with {:ok, integrations} <- fetch(:third_party_auth, %{ref: project_ref(project)}) do
      {:ok, entries(to_list(integrations), &to_string(&1["id"]))}
    end
  end

  defp to_list(list) when is_list(list), do: list
  defp to_list(%{"items" => list}) when is_list(list), do: list
  defp to_list(_other), do: []

  defp org_slug(org), do: to_string(org["slug"] || org["id"])
  defp project_ref(project), do: to_string(project["id"] || project["ref"])

  defp entries(items, name_fun) when is_list(items) do
    items
    |> Enum.map(fn item -> {sanitize(name_fun.(item)), item} end)
    |> uniquify()
  end

  defp entries(_other, _name_fun), do: []

  defp names(entries), do: Enum.map(entries, fn {name, _item} -> name end)

  defp with_entry(entries_result, name, fun) do
    with {:ok, entries} <- entries_result do
      case List.keyfind(entries, name, 0) do
        {^name, item} -> fun.(item)
        nil -> {:error, :enoent}
      end
    end
  end

  @doc false
  def sanitize(name) do
    name
    |> to_string()
    |> String.replace("/", "_")
    |> String.replace(<<0>>, "_")
    |> case do
      "" -> "_"
      "." -> "_"
      ".." -> "__"
      other -> other
    end
  end

  @doc false
  def uniquify(pairs) do
    {out, _seen} =
      Enum.reduce(pairs, {[], %{}}, fn {name, item}, {acc, seen} ->
        count = Map.get(seen, name, 0)
        display = if count == 0, do: name, else: "#{name}~#{count + 1}"
        {[{display, item} | acc], Map.put(seen, name, count + 1)}
      end)

    Enum.reverse(out)
  end

  defp fetch(endpoint, args, opts \\ []) do
    url = Endpoints.path(endpoint, args)
    ttl_ms = Config.ttl_ms(Endpoints.ttl_class(endpoint))

    case Cache.fetch(url, ttl_ms, fn -> Client.get(url, opts) end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  defp map_error(reason) when reason in [:not_found, :unavailable], do: :enoent
  defp map_error(reason) when reason in [:unauthorized, :forbidden], do: :eacces
  defp map_error(:rate_limited), do: :eagain
  defp map_error(_other), do: :eio
end
