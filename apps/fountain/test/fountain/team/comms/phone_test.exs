defmodule Fountain.Team.Comms.PhoneTest do
  use ExUnit.Case, async: true

  alias Fountain.Team.Comms.Phone

  test "normalizes what people type to E.164" do
    for {input, expected} <- [
          {"+15551234567", "+15551234567"},
          {"5551234567", "+15551234567"},
          {"15551234567", "+15551234567"},
          {"(555) 123-4567", "+15551234567"},
          {"+1 555 123 4567", "+15551234567"},
          {"+44 20 7946 0958", "+442079460958"},
          {"0044 20 7946 0958", "+442079460958"}
        ] do
      assert Phone.normalize(input) == {:ok, expected}, input
    end
  end

  test "rejects what is not a phone number" do
    for input <- [
          "",
          "call me",
          "123",
          "+0123456789",
          "555-1234",
          nil,
          42,
          "+1 555 123 4567 ext 9"
        ] do
      assert Phone.normalize(input) == :error, inspect(input)
    end
  end

  test "same? compares normalized forms" do
    assert Phone.same?("(555) 000-1111", "+15550001111")
    refute Phone.same?("+15550001111", "+15550001112")
    refute Phone.same?("junk", "+15550001111")
  end
end
