defmodule Scry.LogicTest do
  use ExUnit.Case, async: true

  alias Scry.Core.Query

  test "parse/1 delegates directly to Scry.Core.parse/1" do
    assert {:ok, %Query{} = q} = Scry.Logic.parse("SELECT ancestor(X, \"bob\") { X }")
    assert q.source == ["ancestor"]
    assert q.goal_args == [{:field, ["X"]}, "bob"]
  end

  test "an ordinary query with no goal_args still parses" do
    assert {:ok, %Query{} = q} = Scry.Logic.parse("SELECT users { name }")
    assert q.goal_args == nil
  end

  test "a genuine parse error still surfaces as an error" do
    assert {:error, _} = Scry.Logic.parse("NOT A REAL QUERY")
  end
end
