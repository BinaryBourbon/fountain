defmodule Managoat.Sandbox.E2B.EnvdTest do
  use ExUnit.Case, async: true

  alias Managoat.Sandbox.E2B.Envd

  describe "Connect envelope codec" do
    test "round-trips a message frame" do
      frame = Envd.encode_frame(%{"hello" => "world"})
      assert {[{:message, %{"hello" => "world"}}], <<>>} = Envd.decode_frames(frame)
    end

    test "decodes multiple frames and keeps an incomplete tail" do
      a = Envd.encode_frame(%{"n" => 1})
      b = Envd.encode_frame(%{"n" => 2})
      <<partial::binary-size(3), _::binary>> = Envd.encode_frame(%{"n" => 3})

      assert {[{:message, %{"n" => 1}}, {:message, %{"n" => 2}}], ^partial} =
               Envd.decode_frames(a <> b <> partial)
    end

    test "flag 2 is the end-of-stream frame" do
      json = Jason.encode!(%{"error" => %{"message" => "boom"}})
      frame = <<2, byte_size(json)::32-big, json::binary>>

      assert {[{:end_stream, %{"error" => %{"message" => "boom"}}}], <<>>} =
               Envd.decode_frames(frame)
    end

    test "an empty or sub-header buffer decodes to nothing" do
      assert {[], <<>>} = Envd.decode_frames(<<>>)
      assert {[], <<0, 0>>} = Envd.decode_frames(<<0, 0>>)
    end
  end

  describe "start_request/4" do
    test "builds the tagged process config with envs and cwd" do
      request =
        Envd.start_request("fountain-1", "bash", ["-lc", "true"],
          env: [{"A", "1"}],
          dir: "/home/sprite"
        )

      assert %{
               tag: "fountain-1",
               process: %{
                 cmd: "bash",
                 args: ["-lc", "true"],
                 envs: %{"A" => "1"},
                 cwd: "/home/sprite"
               }
             } = request
    end

    test "omits cwd when absent" do
      request = Envd.start_request("t", "true", [], [])
      refute Map.has_key?(request.process, :cwd)
    end
  end

  describe "host/1" do
    test "derives the envd host from the control-plane domain" do
      # Default base URL api.e2b.app -> 49983-{id}.e2b.app.
      assert Envd.host("sbx123") == "https://49983-sbx123.e2b.app"
    end
  end
end
