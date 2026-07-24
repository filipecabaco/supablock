defmodule Supablock.AuthedCase do
  @moduledoc """
  Case template for tests that exercise the resource tree: isolates the XDG
  directories, stores a fake credential, and installs the default API stub as
  the Req plug. `isolate_xdg!/0` also flushes the cache, so a fresh tree is
  guaranteed per test.

  `async: false` because the stub and XDG dirs are installed through
  process-global application/system env.
  """
  use ExUnit.CaseTemplate

  alias Supablock.TestEnv

  setup do
    TestEnv.isolate_xdg!()
    TestEnv.fake_login!()
    TestEnv.stub_api!()
    :ok
  end
end
