defmodule Scry.Logic.Test.FamilyDB do
  @moduledoc """
  Test-support fixture: a small, hand-written family-tree clause
  database, in the `%{{name, arity} => [clause_fun]}` shape `Scry.Logic.
  Executor`'s own `conn` parameter expects. `ancestor_clauses/0` is the
  reference example for that module's own "recursive clauses must defer
  their own self-call" gotcha -- written the correct (lazy-wrapped) way
  on purpose, proven to terminate by every test that exercises it.
  """

  alias Ichor.Backtrack.{Bindings, Tree}
  alias Scry.Logic.Term

  @doc "A goal that unifies `t1` and `t2` -- `Ichor`'s own `Prolog.DB.eq/2` worked example, verbatim."
  def eq(t1, t2) do
    fn bindings ->
      case Bindings.unify(Term, bindings, t1, t2) do
        {:ok, extended} -> Tree.unit().(extended)
        :fail -> Tree.fail().(bindings)
      end
    end
  end

  @doc "Unifies every `{t1, t2}` pair in order, short-circuiting on the first failure."
  def unify_all(pairs) do
    Enum.reduce(pairs, Tree.unit(), fn {t1, t2}, acc -> Tree.conjunction(acc, eq(t1, t2)) end)
  end

  @doc "Tries every clause (in order) against `args`, as a disjunction."
  def solve_any(clauses, args) do
    Enum.reduce(clauses, Tree.fail(), fn clause, acc -> Tree.disjunction(acc, clause.(args)) end)
  end

  @doc "parent(tom, bob). parent(bob, ann). parent(bob, pat)."
  def parent_clauses do
    [
      fn [x, y] -> unify_all([{x, "tom"}, {y, "bob"}]) end,
      fn [x, y] -> unify_all([{x, "bob"}, {y, "ann"}]) end,
      fn [x, y] -> unify_all([{x, "bob"}, {y, "pat"}]) end
    ]
  end

  def parent(args), do: solve_any(parent_clauses(), args)

  @doc "age(tom, 60). age(bob, 35). age(ann, 10). age(pat, 8)."
  def age_clauses do
    [
      fn [x, y] -> unify_all([{x, "tom"}, {y, 60}]) end,
      fn [x, y] -> unify_all([{x, "bob"}, {y, 35}]) end,
      fn [x, y] -> unify_all([{x, "ann"}, {y, 10}]) end,
      fn [x, y] -> unify_all([{x, "pat"}, {y, 8}]) end
    ]
  end

  def age(args), do: solve_any(age_clauses(), args)

  @doc """
  `ancestor(X, Y) :- parent(X, Y).`
  `ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).`

  The recursive second clause wraps its own self-call in
  `fn bindings -> ancestor([z, y]).(bindings) end` -- `Scry.Logic.
  Executor`'s own moduledoc has the full "why this extra layer of
  laziness is required, not stylistic" explanation. Written any other
  way, this clause hangs forever building the goal, never reaching a
  real `parent` fact -- confirmed directly (a real, reproduced hang)
  before landing this shape.
  """
  def ancestor_clauses do
    [
      fn [x, y] -> parent([x, y]) end,
      fn [x, y] ->
        z = {:var, make_ref()}
        Tree.conjunction(parent([x, z]), fn bindings -> ancestor([z, y]).(bindings) end)
      end
    ]
  end

  def ancestor(args), do: solve_any(ancestor_clauses(), args)

  @doc "The full conn map -- parent/2, age/2, ancestor/2."
  def conn do
    %{
      {"parent", 2} => parent_clauses(),
      {"age", 2} => age_clauses(),
      {"ancestor", 2} => ancestor_clauses()
    }
  end
end
