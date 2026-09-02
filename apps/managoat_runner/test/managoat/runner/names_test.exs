defmodule Managoat.Runner.NamesTest do
  use ExUnit.Case, async: true

  alias Managoat.Runner.Names

  test "a name round-trips the runner id" do
    id = "0f0e0d0c-0b0a-4908-8706-050403020100"
    name = Names.for_runner(id)
    assert name =~ ~r/\Arunner-[0-9a-f]{32}-[0-9a-f]{8}\z/
    assert {:ok, ^id} = Names.parse(name)
  end

  test "two names on one runner differ" do
    id = "0f0e0d0c-0b0a-4908-8706-050403020100"
    assert Names.for_runner(id) != Names.for_runner(id)
  end

  test "an uppercase hex id parses to the lowercase dashed form" do
    assert {:ok, "0f0e0d0c-0b0a-4908-8706-050403020100"} =
             Names.parse("runner-0F0E0D0C0B0A49088706050403020100-abcd1234")
  end

  test "other providers' names and malformed runner names are rejected" do
    assert :error = Names.parse("fountain-abcd1234-deadbeef")
    assert :error = Names.parse("runner-short-x")
    assert :error = Names.parse("runner-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-abcd1234")
    assert :error = Names.parse("runner-0f0e0d0c0b0a49088706050403020100")
    assert :error = Names.parse("")
  end
end
