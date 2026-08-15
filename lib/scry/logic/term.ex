defmodule Scry.Logic.Term do
  @moduledoc """
  `Scry.Logic.Executor`'s own `Ichor.Backtrack.Term` implementation --
  the term representation `Ichor.Backtrack.Bindings.unify/4` unifies
  against, passed explicitly as `term_module` (that module's own
  moduledoc: "nothing here prescribes what a term actually *is*").

  Deliberately narrower than a general Prolog term representation
  (`Ichor`'s own `test/support/prolog.ex` worked example, `{:compound,
  functor, args}`): `compound?/1` always returns `false` here. A Scry
  goal call (`ancestor(X, "bob")`) is never unified *as a term* against
  a clause head the way a nested Prolog compound argument would be --
  `Scry.Logic.Executor` resolves a goal by looking up a backend `conn`'s
  own clause functions for `{name, arity}` and calling each one
  directly with the (already-resolved) argument list, exactly
  `Ichor`'s own `Prolog.DB.solve_any/2` worked example does. Scry has no
  rule-authoring syntax -- it never needs to
  represent or unify a *nested* compound structure, only ever a flat
  argument list per goal, which is what makes this simplification safe:
  nothing in `scry_logic` ever needs `compound?/1` to be `true`.

  A variable is `{:var, name}`, keyed by the query's own variable name
  (a plain string, e.g. `"X"`) -- not a freshly minted `reference/0` the
  way `Prolog.Terms` uses for a *clause's own internal* variables. This
  is deliberate, not a simplification that loses anything: a Scry
  query's own top-level variables are named, source-text identifiers,
  stable for exactly one execution ("repeated names
  within a query unify"), never re-instantiated mid-query the way a
  recursive clause's own internal variables must be -- freshening a
  *clause's* own internal variables (so two different calls to the same
  recursive clause never accidentally share one) is entirely the
  backend `conn`'s own responsibility, the same `make_ref()`-per-call
  convention `Prolog.DB`'s own `grandparent_clauses/0` already
  demonstrates; `scry_logic` itself never mints one.

  Anything that isn't a `{:var, _}` tuple is atomic, unified with plain
  `==/2` -- an ordinary Elixir value (`"bob"`, `30`, `true`, `nil`),
  exactly what `Scry.Logic.Executor` resolves a ground `expr()` argument
  down to before a goal is ever built.
  """

  @behaviour Ichor.Backtrack.Term

  @impl true
  def variable?({:var, _name}), do: true
  def variable?(_term), do: false

  @impl true
  def var_id({:var, name}), do: name

  @impl true
  def compound?(_term), do: false

  # Never actually called -- `compound?/1` is always `false`, and
  # `Ichor.Backtrack.Bindings.unify/4` only ever calls `deconstruct/1`
  # when both sides report `compound?/1` `true`. Still a required
  # (non-optional) callback of `Ichor.Backtrack.Term`, so a real, if
  # unreachable, implementation is needed to satisfy the behaviour.
  @impl true
  def deconstruct(term) do
    raise ArgumentError,
          "Scry.Logic.Term.deconstruct/1 should be unreachable (compound?/1 is always false): " <>
            inspect(term)
  end
end
