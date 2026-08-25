defmodule Fountain.Broker.HTTPTest do
  use ExUnit.Case, async: true

  alias Fountain.Broker.HTTP

  describe "parse_request/1" do
    test "a CONNECT head" do
      raw =
        "CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com:443\r\nProxy-Authorization: Basic x\r\n\r\ntail"

      assert {:ok, head, "tail"} = HTTP.parse_request(raw)
      assert head.method == "CONNECT"
      assert head.target == "api.github.com:443"
      assert head.version == {1, 1}
      assert head.headers == [{"Host", "api.github.com:443"}, {"Proxy-Authorization", "Basic x"}]
      assert {:ok, {"api.github.com", 443}, "api.github.com:443"} = HTTP.destination(head)
    end

    test "an absolute-form GET, and its origin-form target" do
      raw =
        "GET http://deb.debian.org/debian/dists/x?y=1 HTTP/1.1\r\nHost: deb.debian.org\r\n\r\n"

      assert {:ok, head, ""} = HTTP.parse_request(raw)
      assert head.method == "GET"
      assert {:ok, {"deb.debian.org", 80}, "/debian/dists/x?y=1"} = HTTP.destination(head)
    end

    test "an origin-form request inside a tunnel" do
      raw = "POST /repos HTTP/1.1\r\nHost: api.github.com\r\nContent-Length: 2\r\n\r\n{}"

      assert {:ok, head, "{}"} = HTTP.parse_request(raw)
      assert head.target == "/repos"
      assert HTTP.body_framing(head) == {:length, 2}
      assert {:error, :bad_target} = HTTP.destination(head)
    end

    test "an incomplete head asks for more, keeping the buffer" do
      assert {:more, _} = HTTP.parse_request("GET /x HTTP/1.1\r\nHost: a")
      assert {:more, _} = HTTP.parse_request("GET /x HT")
    end

    test "garbage is an error" do
      assert {:error, _} = HTTP.parse_request("\x16\x03\x01 not http\r\n\r\n")
    end

    test "a bad CONNECT authority" do
      {:ok, head, _} = HTTP.parse_request("CONNECT nope HTTP/1.1\r\n\r\n")
      assert {:error, :bad_target} = HTTP.destination(head)
    end
  end

  test "encode_request round-trips a head with the target substituted" do
    {:ok, head, _} = HTTP.parse_request("GET http://h/p HTTP/1.1\r\nHost: h\r\nX: y\r\n\r\n")

    assert IO.iodata_to_binary(HTTP.encode_request(head, "/p")) ==
             "GET /p HTTP/1.1\r\nHost: h\r\nX: y\r\n\r\n"
  end

  describe "take_body/2" do
    test "no body" do
      assert {:done, "", "next"} = HTTP.take_body(:none, "next")
    end

    test "content-length, whole and in pieces" do
      assert {:done, "abc", "d"} = HTTP.take_body({:length, 3}, "abcd")
      assert {:partial, "ab", {:length, 1}} = HTTP.take_body({:length, 3}, "ab")
      assert {:done, "c", ""} = HTTP.take_body({:length, 1}, "c")
    end

    test "chunked, forwarded verbatim through to the trailers" do
      body = "3\r\nabc\r\n2;ext=1\r\nde\r\n0\r\n\r\n"
      assert {:done, ^body, "NEXT"} = HTTP.take_body(:chunked, body <> "NEXT")
    end

    test "chunked, split at every awkward point" do
      body = "3\r\nabc\r\n2\r\nde\r\n0\r\nTrailer: t\r\n\r\n"

      for cut <- 1..(byte_size(body) - 1) do
        <<a::binary-size(cut), b::binary>> = body
        assert {:partial, ^a, state} = HTTP.take_body(:chunked, a)
        assert {:done, ^b, "X"} = HTTP.take_body(state, b <> "X")
      end
    end
  end
end
