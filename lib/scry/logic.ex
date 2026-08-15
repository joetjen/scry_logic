defmodule Scry.Logic do
  @moduledoc """
  The `logic` kind for Scry -- Prolog/Datalog-shaped querying: `SELECT
  ancestor(X, "bob") WHERE age(X) > 30 { X }`. Facts and rules live
  entirely in a backend `conn`; Scry itself has no rule-authoring
  syntax and never parses or reasons about a rule body.

  **Degenerate at the grammar level, real at the execution level** --
  unlike `scry_relational`/`scry_olap` (`Scry.Core.TypeCheck`'s own
  `@degenerate_kinds`), `logic` has genuinely new *execution* semantics
  (`Scry.Logic.Executor`, real SLD-resolution via `Ichor.Backtrack`),
  but *no* EP1/EP2 grammar vocabulary of its own to compose in.
  `SELECT <name>(<args>) { ... }` (a call-shaped source) is a plain
  `scry_core` grammar addition (`%Scry.Core.Query{}.goal_args`, see
  that struct's own moduledoc) -- deliberately not gated to `logic` at
  the grammar level, since grammar composition only ever answers
  whether a construct *exists*, not whether it's *legal* against a
  given source; `Scry.Core.TypeCheck`'s category check is what enforces that a non-nil
  `goal_args` only appears against a `TYPE`-declared `"logic"` kind.

  This means `parse/1` below is a direct, permanent delegation to
  `Scry.Core.parse/1` -- there is no `Scry.Logic.Grammar`/`.Actions`
  module, and no `priv/gen/generate_compiled_grammar.exs` generator,
  the same reason `scry_relational` has none. `Scry.Logic.Executor` is
  the real content of this package.
  """

  alias Scry.Core.{CombinedQuery, Query}

  @doc """
  Parses `source` (Scry query text) into a `%Scry.Core.Query{}` (or a
  `%Scry.Core.CombinedQuery{}`, per `Scry.Core.parse/1`'s own combinator
  handling) -- a direct delegation, not a temporary shim: `logic` has
  no grammar fragment of its own to compose in.
  """
  @spec parse(String.t()) :: {:ok, Query.t() | CombinedQuery.t()} | {:error, term()}
  def parse(source) when is_binary(source) do
    Scry.Core.parse(source)
  end
end
