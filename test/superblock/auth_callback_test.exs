defmodule Superblock.AuthCallbackTest do
  use ExUnit.Case, async: false

  alias Superblock.AuthCallback

  test "delivers callback params to the waiter and tells the browser to close" do
    {:ok, listener} = AuthCallback.start_listener(self())

    on_exit(fn -> AuthCallback.stop_listener(listener) end)

    response =
      Req.get!("http://127.0.0.1:53682/callback",
        params: [code: "abc123", state: "st4te"],
        retry: false
      )

    assert response.status == 200
    assert response.body =~ "close this tab"

    assert_receive {:oauth_callback, %{"code" => "abc123", "state" => "st4te"}}, 2_000
  end

  test "the port can be rebound after stop_listener" do
    {:ok, first} = AuthCallback.start_listener(self())
    :ok = AuthCallback.stop_listener(first)

    {:ok, second} = AuthCallback.start_listener(self())
    :ok = AuthCallback.stop_listener(second)
  end

  test "a taken port is reported as :port_in_use" do
    {:ok, listener} = AuthCallback.start_listener(self())
    on_exit(fn -> AuthCallback.stop_listener(listener) end)

    assert {:error, :port_in_use} = AuthCallback.start_listener(self())
  end
end
