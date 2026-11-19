defmodule Supablock.AuthCallbackTest do
  use ExUnit.Case, async: false

  alias Supablock.AuthCallback

  @state "st4te-for-this-login"

  defp start! do
    {:ok, listener} = AuthCallback.start_listener(self(), @state)
    on_exit(fn -> AuthCallback.stop_listener(listener) end)
    listener
  end

  defp callback(params, host \\ "127.0.0.1") do
    Req.get!("http://#{host}:53682/callback", params: params, retry: false)
  end

  test "delivers callback params to the waiter and tells the browser to close" do
    start!()

    response = callback(code: "abc123", state: @state)

    assert response.status == 200
    assert response.body =~ "close this tab"

    assert_receive {:oauth_callback, %{"code" => "abc123", "state" => @state}}, 2_000
  end

  test "a callback with another state is refused and never reaches the login" do
    start!()

    # What any web page can make the browser load to try to abort a login.
    for params <- [
          [error: "access_denied", error_description: "gotcha"],
          [error: "access_denied", state: "not-this-one"],
          [code: "stolen", state: "forged-state"],
          [code: "stolen", state: String.slice(@state, 0..-2//1)]
        ] do
      response = callback(params)
      assert response.status == 400
      assert response.body =~ "does not belong"
    end

    refute_receive {:oauth_callback, _params}, 200
  end

  test "a list-valued state (state[]=…) is refused without crashing the listener" do
    start!()

    response = Req.get!("http://127.0.0.1:53682/callback?code=x&state[]=#{@state}", retry: false)
    assert response.status == 400
    refute_receive {:oauth_callback, _params}, 200

    assert callback(code: "ok", state: @state).status == 200
    assert_receive {:oauth_callback, %{"code" => "ok"}}, 2_000
  end

  test "a provider error with this login's state is passed on, with a not-authorized page" do
    start!()

    response = callback(error: "access_denied", state: @state)
    assert response.status == 200
    assert response.body =~ "was not authorized"
    refute response.body =~ "is connected"

    assert_receive {:oauth_callback, %{"error" => "access_denied"}}, 2_000
  end

  test "IPv6 loopback is served too when the host has it (localhost may resolve to ::1)" do
    start!()

    case :gen_tcp.connect({0, 0, 0, 0, 0, 0, 0, 1}, 53682, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        assert callback([code: "v6", state: @state], "[::1]").status == 200
        assert_receive {:oauth_callback, %{"code" => "v6"}}, 2_000

      {:error, _no_ipv6} ->
        :ok
    end
  end

  test "state_matches?/2 only accepts the exact string" do
    assert AuthCallback.state_matches?("abc", "abc")
    refute AuthCallback.state_matches?("abd", "abc")
    refute AuthCallback.state_matches?("ab", "abc")
    refute AuthCallback.state_matches?(["abc"], "abc")
    refute AuthCallback.state_matches?(%{"a" => "abc"}, "abc")
    refute AuthCallback.state_matches?(nil, "abc")
  end

  test "the port can be rebound after stop_listener" do
    {:ok, first} = AuthCallback.start_listener(self(), @state)
    :ok = AuthCallback.stop_listener(first)

    {:ok, second} = AuthCallback.start_listener(self(), @state)
    :ok = AuthCallback.stop_listener(second)
  end

  test "a taken port is reported as :port_in_use" do
    start!()
    assert {:error, :port_in_use} = AuthCallback.start_listener(self(), @state)
  end
end
