defmodule Scry.Logic.TermTest do
  use ExUnit.Case, async: true

  alias Ichor.Backtrack.Bindings
  alias Scry.Logic.Term

  test "variable?/1 recognizes only {:var, name}" do
    assert Term.variable?({:var, "X"})
    refute Term.variable?("X")
    refute Term.variable?(42)
    refute Term.variable?({:compound, "foo", []})
  end

  test "var_id/1 returns the variable's own name" do
    assert Term.var_id({:var, "X"}) == "X"
  end

  test "compound?/1 is always false -- scry_logic never represents a nested compound term" do
    refute Term.compound?({:var, "X"})
    refute Term.compound?("bob")
    refute Term.compound?({:compound, "foo", ["a"]})
  end

  test "deconstruct/1 is unreachable in practice but raises a clear error if ever called" do
    assert_raise ArgumentError, ~r/should be unreachable/, fn ->
      Term.deconstruct({:var, "X"})
    end
  end

  describe "real unification through Ichor.Backtrack.Bindings" do
    test "a variable unifies with a ground term" do
      assert {:ok, bindings} = Bindings.unify(Term, Bindings.new(), {:var, "X"}, "bob")
      assert Bindings.resolve(Term, bindings, {:var, "X"}) == "bob"
    end

    test "two ground terms unify only when equal" do
      assert {:ok, _} = Bindings.unify(Term, Bindings.new(), "bob", "bob")
      assert :fail = Bindings.unify(Term, Bindings.new(), "bob", "ann")
    end

    test "two distinct variables unify with each other" do
      {:ok, bindings} = Bindings.unify(Term, Bindings.new(), {:var, "X"}, {:var, "Y"})
      {:ok, bindings} = Bindings.unify(Term, bindings, {:var, "Y"}, "bob")
      assert Bindings.resolve(Term, bindings, {:var, "X"}) == "bob"
    end

    test "the same variable name unifies with itself across two occurrences (repeated names unify)" do
      {:ok, bindings} = Bindings.unify(Term, Bindings.new(), {:var, "X"}, 42)
      assert {:ok, ^bindings} = Bindings.unify(Term, bindings, {:var, "X"}, 42)
      assert :fail = Bindings.unify(Term, bindings, {:var, "X"}, 43)
    end
  end
end
