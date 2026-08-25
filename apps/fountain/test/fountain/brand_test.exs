defmodule Fountain.BrandTest do
  use ExUnit.Case, async: false

  alias Fountain.Brand

  setup do
    previous = Application.get_env(:fountain, :product_name)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :product_name, previous),
        else: Application.delete_env(:fountain, :product_name)
    end)

    :ok
  end

  test "unset or blank falls back to the engine, which is never hosted" do
    Application.delete_env(:fountain, :product_name)
    assert Brand.name() == "Fountain"
    refute Brand.hosted?()

    Application.put_env(:fountain, :product_name, "   ")
    assert Brand.name() == "Fountain"
    refute Brand.hosted?()
  end

  test "a brand is trimmed, used, and marks the deployment hosted" do
    Application.put_env(:fountain, :product_name, " Managoat ")
    assert Brand.name() == "Managoat"
    assert Brand.engine() == "Fountain"
    assert Brand.hosted?()
  end
end
