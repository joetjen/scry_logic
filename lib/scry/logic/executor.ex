defmodule Scry.Logic.Executor do
  @moduledoc """
  `Scry.Core.EngineBehaviour` for lang_spec.md §8.4's `logic` variant --
  real SLD-resolution/unification (`Ichor.Backtrack`), not a row-fetch
  translated some other way. `SELECT ancestor(X, "bob") WHERE age(X) >
  30 { X }` becomes: build a goal from the call-shaped source
  (`%Scry.Core.Query{}.goal_args`), find and conjoin any further goal
  calls hiding inside `WHERE` (`age(X)`, arity-plus-one'd into a fresh
  output variable when it's being compared rather than used bare --
  this module's own `extract_where_goals/2`), run the combined goal
  against `conn`'s own clauses, and turn each solution's variable
  bindings into an ordinary row -- then hand the rest (any remaining
  plain `WHERE`, `GROUP BY`, `ORDER BY`, `LIMIT`, projection) to
  `Scry.Core.QueryOps.run_flat/3`, unchanged, the same "build special
  source rows, delegate everything else" shape `scry_search`/
  `scry_document`/`scry_graph` already established.

  **Facts and rules live entirely in `conn`** (lang_spec.md §8.4 -- Scry
  has no rule-authoring syntax): `conn` is a plain map, `%{{name,
  arity} => [clause_fun]}`, one entry per relation `conn` knows how to
  answer -- each `clause_fun` is `[term()] -> Ichor.Backtrack.goal()`,
  called once per *use*, not once per definition (so it can mint its
  own fresh internal variables per call, the same convention `Ichor`'s
  own `test/support/prolog.ex` worked example -- `Prolog.DB`'s
  `grandparent_clauses/0` -- already demonstrates). A relation this
  module can't find any clauses for simply has zero solutions (fails
  silently), a deliberate simplification against strict ISO Prolog's
  own "unknown procedure" error -- reasonable for a reference/test
  engine, worth reconsidering for a real backend adapter later.

  This is a **reference/in-memory implementation**, exactly the same
  posture `scry_search`'s own toy relevance scorer already has (that
  module's own moduledoc: "explicitly documented as a reference
  implementation, not real search") -- a real backend (an actual
  Prolog/Datalog server) is under no obligation to route through this
  module or its `conn` shape at all; it can implement `Scry.Core.
  EngineBehaviour` directly, however its own wire protocol actually
  works. `scry_test_logic` is what exercises this one end to end.

  ## A genuinely load-bearing gotcha for any `conn` author: recursive clauses must defer their own self-call

  Found the hard way (a real, reproducible infinite hang, not a
  hypothetical): `Ichor.Backtrack.Tree`'s own `disjunction/2`/
  `conjunction/2` are lazy about *searching* a goal that already exists
  as a value, but `solve_any/2` (`Ichor`'s own `Prolog.DB` worked
  example, and this module's own identical helper) calls each
  `clause_fun.(args)` *eagerly* while building the disjunction -- so a
  clause whose own body directly calls another goal-building function
  (`ancestor([z, y])`, say) runs that call immediately, as an ordinary
  strict Elixir function call, before any bindings exist. For a
  *non*-self-referential predicate (`grandparent` calling `parent`,
  `Prolog.DB`'s own worked example) this is harmless. For a genuinely
  recursive one (`ancestor(X, Y) :- parent(X, Y). ancestor(X, Y) :-
  parent(X, Z), ancestor(Z, Y).`) it is **not**: building `ancestor`'s
  own second clause immediately tries to build `ancestor`'s own second
  clause again, forever, before ever reaching a real `parent` fact that
  would bound it -- the recursion is unbounded at *goal-construction*
  time even though the underlying data (and the actual search) is
  perfectly finite. `member_clauses/1` in `Ichor`'s own worked example
  avoids this by recursing on an already-concrete, shrinking Elixir
  list (terminating structurally at `[]`), not by relying on the search
  itself to bound anything -- it never actually exercises this case.

  The fix, confirmed to terminate correctly: wrap the recursive
  self-call in one more layer of laziness, deferring it until the
  combinator that consumes it actually supplies real bindings:

  ```elixir
  def ancestor_clauses do
    [
      fn [x, y] -> parent([x, y]) end,
      fn [x, y] ->
        z = {:var, make_ref()}
        Tree.conjunction(parent([x, z]), fn bindings -> ancestor([z, y]).(bindings) end)
      end
    ]
  end
  ```

  `fn bindings -> ancestor([z, y]).(bindings) end` *is* itself a valid
  `Ichor.Backtrack.goal()` (`bindings -> solutions()`) -- the extra
  closure is what stops `ancestor([z, y])` from being called until
  `Tree.conjunction/2`'s own `flat_map` actually has a concrete
  `bindings` value to hand it, at which point the recursion depth is
  naturally bounded by however many real solutions the search finds.
  Any `conn` supplying a recursive relation needs this same shape;
  `scry_test_logic`'s own ancestor fixture is the reference example.

  ## Stated scope limits, not silently mishandled

  - **`WHERE`-embedded goal calls are only recognized as one side of a
    `{:cmp, ...}` comparison** (`age(X) > 30`), walking an ordinary
    `AND`/`OR`/`NOT` predicate tree to find them -- not a scope choice
    this module made, but a fact about the grammar itself:
    `priv/grammar.aether`'s own `comparison` production has no
    alternative that accepts a bare call with no operator at all
    (`comp_op`/`KW_IN` are both required), so a "bare goal call as a
    whole predicate" (`WHERE age(X)`, no comparison) is a parse error
    before this module ever sees the query, not something it would need
    to decline itself.
  - **`%Scry.Core.CombinedQuery{}` (`UNION`/`INTERSECT`/`EXCEPT`) is
    declined outright** (`{:unsupported, {:construct, :combined_query}}`)
    -- combining two solution streams this way is a real, separate
    design question (does unification survive across the combinator?),
    not resolved this round.
  - **A goal argument must resolve to a plain ground value, an external
    `$param`, or a bare field reference (a variable)** -- an arithmetic
    expression, a nested call, or any other `expr()` shape as a goal
    argument is declined with a clear error rather than silently
    truncated or misinterpreted.
  - **`query.with_bindings`/a correlated nested `SELECT` as a `logic`
    query's own source is not handled** -- `goal_args`'s own presence
    always means "resolve this as a goal against `conn`", never "this
    name might instead be a `WITH` binding."
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Ichor.Backtrack.{Bindings, Tree}
  alias Scry.Core.{Cursor, CombinedQuery, Query, QueryOps}
  alias Scry.Logic.Term

  # Deliberately duplicated from `Scry.Core.QueryOps`'s own private
  # `@aggregate_names ++ @cast_names` (not exposed publicly by that
  # module) -- a `{:call, name, args}` found inside a `logic` query's
  # own `WHERE` is a wildcard relation call *unless* `name` is one of
  # these, matching lang_spec.md §2's own auto-import ordering ("core's
  # own built-ins always win first -- a variant can never shadow a core
  # name").
  @known_call_names ~w(
    sum avg count min max stddev_samp stddev_pop var_samp var_pop percentile rate
    string int exact inexact json
  )

  @doc """
  Runs `query_or_combined` against `conn`, wrapping the result in a
  `Scry.Core.Cursor.t()` -- the same `execute/3`-then-`Cursor.new/1`
  shape `Scry.Core.Executor.run/3,4` and `Scry.Search.Executor.run/3`
  already use.
  """
  @spec run(Query.t() | CombinedQuery.t(), term(), map()) ::
          {:ok, Cursor.t()} | {:error, term()}
  def run(query_or_combined, conn, params \\ %{}) do
    with {:ok, rows} <- execute(conn, query_or_combined, params) do
      {:ok, Cursor.new(rows)}
    end
  end

  @impl true
  def execute(_conn, %CombinedQuery{}, _params) do
    {:error, {:unsupported, {:construct, :combined_query}}}
  end

  @impl true
  def execute(_conn, %Query{goal_args: nil}, _params) do
    {:error, {:unsupported, {:construct, :non_goal_source}}}
  end

  def execute(conn, %Query{} = query, params) do
    with {:ok, source_args, source_vars} <- resolve_args(query.goal_args, params),
         {:ok, source_goal} <- goal_for(query.source, source_args, conn),
         {:ok, rewritten_wheres, extra_goals, extra_vars} <-
           extract_where_goals(query.wheres, conn, params) do
      combined_goal = Enum.reduce(extra_goals, source_goal, &Tree.conjunction(&2, &1))
      var_names = Enum.uniq(source_vars ++ extra_vars)

      rows =
        combined_goal
        |> apply_goal(Bindings.new())
        |> Tree.to_list()
        |> Enum.map(&bindings_to_row(&1, var_names))

      QueryOps.run_flat(rows, %{query | wheres: rewritten_wheres}, params)
    end
  end

  defp apply_goal(goal, bindings), do: goal.(bindings)

  defp bindings_to_row(bindings, var_names) do
    Map.new(var_names, fn name -> {name, Bindings.resolve(Term, bindings, {:var, name})} end)
  end

  # ---- goal construction ---------------------------------------------------

  defp goal_for(source, args, conn) do
    functor = List.last(source)
    clauses = Map.get(conn, {functor, length(args)}, [])
    {:ok, solve_any(clauses, args)}
  end

  # Tries every clause (in declared order) against `args`, as a
  # disjunction -- `Ichor`'s own `Prolog.DB.solve_any/2` worked example,
  # verbatim.
  defp solve_any(clauses, args) do
    Enum.reduce(clauses, Tree.fail(), fn clause, acc -> Tree.disjunction(acc, clause.(args)) end)
  end

  # ---- goal argument resolution ---------------------------------------------

  # Resolves a list of `expr()` goal arguments (source `goal_args`, or a
  # `WHERE`-embedded call's own args) into `{terms, variable_names}` --
  # a bare `{:field, [name]}` becomes `{:var, name}` (a logic variable);
  # `{:param, name}` resolves against `params`; anything else that's
  # already a plain literal (string/number/boolean/nil/`%Rational{}`)
  # passes through unchanged. Any other `expr()` shape (arithmetic, a
  # nested call, `{:dot, ...}`, ...) is declined -- this module's own
  # moduledoc states that scope limit.
  defp resolve_args(args, params) do
    Enum.reduce_while(args, {:ok, [], []}, fn arg, {:ok, terms, vars} ->
      case resolve_arg(arg, params) do
        {:ok, {:var, name} = term} -> {:cont, {:ok, terms ++ [term], vars ++ [name]}}
        {:ok, term} -> {:cont, {:ok, terms ++ [term], vars}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, terms, vars} -> {:ok, terms, vars}
      {:error, _} = err -> err
    end
  end

  defp resolve_arg({:field, [name]}, _params), do: {:ok, {:var, name}}

  defp resolve_arg({:param, name}, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:query_error, {:missing_param, name}}}
    end
  end

  defp resolve_arg(literal, _params)
       when is_binary(literal) or is_number(literal) or is_boolean(literal) or is_nil(literal) or
              is_struct(literal, Scry.Core.Rational) do
    {:ok, literal}
  end

  defp resolve_arg(other, _params), do: {:error, {:unsupported, {:goal_argument, other}}}

  # ---- WHERE-embedded goal extraction ---------------------------------------

  # Walks `wheres` (an AND-ed list of predicates, each possibly nested
  # `{:and, ...}`/`{:or, ...}`/`{:not, ...}`), finding every `{:cmp, op,
  # lhs, rhs}` where one side is a wildcard call (`name` not in
  # `@known_call_names`). Each one becomes a *conjoined goal*, args
  # arity-plus-one'd with a fresh output variable (`"$goal_out_N"`) when
  # the call is being compared (a value position) rather than a bare
  # goal on its own; the comparison itself is rewritten in place to
  # reference that fresh variable as an ordinary field, so the leftover
  # `wheres` `Scry.Core.QueryOps.run_flat/3` sees afterward is entirely
  # ordinary -- no bespoke post-filtering logic needed here at all.
  defp extract_where_goals(wheres, conn, params) do
    wheres
    |> Enum.reduce_while({:ok, [], [], [], 0}, fn predicate, {:ok, preds, goals, vars, counter} ->
      case rewrite_predicate(predicate, conn, params, counter) do
        {:ok, new_pred, new_goals, new_vars, new_counter} ->
          {:cont, {:ok, preds ++ [new_pred], goals ++ new_goals, vars ++ new_vars, new_counter}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, preds, goals, vars, _counter} -> {:ok, preds, goals, vars}
      {:error, _} = err -> err
    end
  end

  defp rewrite_predicate({:and, left, right}, conn, params, counter) do
    rewrite_combinator(:and, left, right, conn, params, counter)
  end

  defp rewrite_predicate({:or, left, right}, conn, params, counter) do
    rewrite_combinator(:or, left, right, conn, params, counter)
  end

  defp rewrite_predicate({:not, inner}, conn, params, counter) do
    with {:ok, new_inner, goals, vars, new_counter} <-
           rewrite_predicate(inner, conn, params, counter) do
      {:ok, {:not, new_inner}, goals, vars, new_counter}
    end
  end

  defp rewrite_predicate({:cmp, op, {:call, name, args}, rhs}, conn, params, counter)
       when name not in @known_call_names do
    rewrite_call_comparison(op, name, args, rhs, conn, params, counter)
  end

  defp rewrite_predicate(predicate, _conn, _params, counter),
    do: {:ok, predicate, [], [], counter}

  defp rewrite_combinator(tag, left, right, conn, params, counter) do
    with {:ok, new_left, left_goals, left_vars, counter2} <-
           rewrite_predicate(left, conn, params, counter),
         {:ok, new_right, right_goals, right_vars, counter3} <-
           rewrite_predicate(right, conn, params, counter2) do
      {:ok, {tag, new_left, new_right}, left_goals ++ right_goals, left_vars ++ right_vars,
       counter3}
    end
  end

  # `rhs` (the non-call half of the comparison, e.g. the `30` in
  # `age(X) > 30`) is left exactly as-is, an ordinary `expr()` -- it's
  # not a goal argument at all, just whatever `Scry.Core.QueryOps`
  # already knows how to resolve a comparison's own `right:literal`
  # against a row, so it goes back into the rewritten predicate
  # completely unchanged. The call only ever appears on the *left* --
  # `priv/grammar.aether`'s own `comparison := left:predicate_lhs
  # op:comp_op right:literal` requires `right` to be a bare literal
  # token, never a call, so `10 < age(Y)` (call on the right) is a
  # parse error before this module ever runs, not a second shape this
  # function needs to handle -- confirmed empirically (a real parse
  # failure) before simplifying this from a two-sided rewrite down to
  # the one real shape.
  defp rewrite_call_comparison(op, name, args, rhs, conn, params, counter) do
    with {:ok, call_terms, call_vars} <- resolve_args(args, params) do
      fresh_name = "$goal_out_#{counter + 1}"
      full_terms = call_terms ++ [{:var, fresh_name}]
      goal = solve_any(Map.get(conn, {name, length(full_terms)}, []), full_terms)

      # A predicate's own `lhs`/`rhs` uses a *bare* `[String.t()]` path
      # for a field reference (`Scry.Core.QueryOps.resolve_predicate_lhs/4`'s
      # own `is_list(path)` clause) -- unlike `{:field, path}`, the tag
      # `select`/`order_by`/`goal_args` positions need. Confirmed the
      # hard way (a `FunctionClauseError` against the real thing) before
      # fixing this to match.
      new_cmp = {:cmp, op, [fresh_name], rhs}

      {:ok, new_cmp, [goal], call_vars ++ [fresh_name], counter + 1}
    end
  end
end
