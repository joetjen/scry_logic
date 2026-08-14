defmodule Scry.Logic.ExecutorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ichor.Backtrack.{Bindings, Tree}
  alias Scry.Core.CombinedQuery
  alias Scry.Logic.{Executor, Term}
  alias Scry.Logic.Test.FamilyDB

  defp run!(query_text, params \\ %{}) do
    {:ok, query} = Scry.Logic.parse(query_text)
    {:ok, rows} = Executor.execute(FamilyDB.conn(), query, params)
    Enum.to_list(rows)
  end

  describe "a call-shaped source, resolved against real SLD-resolution" do
    test "an unbound goal returns every fact, in clause order" do
      assert run!("SELECT parent(X, Y) { X, Y }") == [
               %{"X" => "tom", "Y" => "bob"},
               %{"X" => "bob", "Y" => "ann"},
               %{"X" => "bob", "Y" => "pat"}
             ]
    end

    test "a ground first argument narrows the search" do
      assert run!("SELECT parent(\"bob\", Y) { Y }") == [%{"Y" => "ann"}, %{"Y" => "pat"}]
    end

    test "a fully ground goal succeeds with an empty (still one-row) binding" do
      assert run!("SELECT parent(\"tom\", \"bob\") { ok: \"matched\" }") == [
               %{"ok" => "matched"}
             ]
    end

    test "a fully ground goal that doesn't hold produces zero rows" do
      assert run!("SELECT parent(\"ann\", \"bob\") { ok: \"matched\" }") == []
    end

    test "a zero-arity/unknown relation has zero solutions, not an error" do
      assert run!("SELECT nope(X) { X }") == []
    end
  end

  describe "the lang_spec.md §8.4 worked example -- a WHERE-embedded goal call" do
    test "age(X) > 30 conjoins a second goal and filters by its own resolved value" do
      assert run!("SELECT parent(X, Y) WHERE age(Y) > 10 { X, Y }") == [
               %{"X" => "tom", "Y" => "bob"}
             ]
    end

    test "combined with an ordinary AND against a ground value", %{} do
      assert run!("SELECT parent(X, Y) WHERE age(Y) > 10 AND Y = \"bob\" { X, Y }") == [
               %{"X" => "tom", "Y" => "bob"}
             ]
    end

    test "no facts satisfy the embedded goal's own comparison" do
      assert run!("SELECT parent(X, Y) WHERE age(Y) > 1000 { X, Y }") == []
    end
  end

  describe "wildcard-fallback ordering -- a core builtin's own name never becomes a phantom goal" do
    test "string(Y) = ... is an ordinary cast comparison, not a wildcard relation call" do
      # A wrongly-wildcarded `string(...)` would look up a phantom
      # `{"string", 2}` relation `conn` has no clauses for -- this
      # module's own documented "unknown relation simply fails
      # silently" posture -- silently returning zero rows regardless of
      # what `Y` actually is. The correct behavior delegates the whole
      # comparison unchanged to `Scry.Core.QueryOps.run_flat/3`, which
      # resolves `string(Y)` as the real (identity, for an
      # already-string `Y`) cast it is.
      assert run!(~s|SELECT parent(X, Y) WHERE string(Y) = "bob" { X, Y }|) == [
               %{"X" => "tom", "Y" => "bob"}
             ]
    end

    test "dxn($p)/dxnb($p) (added to core's own cast names after this module's own list was first hand-duplicated) are correctly recognized as core builtins too" do
      # A malformed-DXN external param, not a bound goal variable --
      # every fixed string `FamilyDB`'s own facts ever bind Y to
      # ("bob", "tom", ...) turns out to be *valid* DXN (a bare
      # identifier decodes as a `%Dextrin.Symbol{}`), so it can't tell
      # the two cases apart on its own. The correct behavior genuinely
      # attempts the DXN decode and raises on this malformed input; a
      # wrongly-wildcarded `dxn(...)` would instead silently return
      # `[]` (a phantom relation `conn` has no clauses for, this
      # module's own documented "unknown relation simply fails
      # silently" posture), never reaching `Scry.Core.QueryOps.
      # cast_to_dxn/1` at all. This is exactly the real, confirmed bug
      # found and fixed here: `dxn`/`dxnb` used to be missing from this
      # module's own hand-duplicated `@known_call_names`.
      assert_raise ArgumentError, ~r/dxn\(\.\.\.\) could not decode/, fn ->
        run!(~s|SELECT parent(X, Y) WHERE dxn($p) = "z" { X, Y }|, %{"p" => "not dxn at all }{"})
      end

      assert_raise ArgumentError, ~r/dxnb\(\.\.\.\) could not decode/, fn ->
        run!(~s|SELECT parent(X, Y) WHERE dxnb($p) = "z" { X, Y }|, %{"p" => "not dxnb at all"})
      end
    end

    test "config :scry_logic, :extra_known_call_names excludes a further, non-core name from the wildcard fallback" do
      # `age/2` is a *real* relation in `FamilyDB`'s own `conn`,
      # normally resolved as a goal (the worked-example describe block
      # above proves this). Registering it as an "extra known name"
      # (standing in for another loaded kind's own EP2 auto-imported
      # name, lang_spec.md §2's own resolution ordering) makes the
      # wildcard-fallback machinery treat `age(Y)` as an ordinary,
      # unregistered cast call instead -- `apply_cast/2` has no "age"
      # cast, so this raises a clear, different error rather than
      # silently resolving it as a goal, proving the config value
      # genuinely reaches `wildcard_call?/1`.
      Application.put_env(:scry_logic, :extra_known_call_names, ["age"])

      on_exit(fn -> Application.delete_env(:scry_logic, :extra_known_call_names) end)

      assert_raise ArgumentError, ~r/unknown or unsupported function: "age"/, fn ->
        run!(~s|SELECT parent(X, Y) WHERE age(Y) > 10 { X, Y }|)
      end
    end
  end

  describe "recursion -- a real transitive-closure predicate" do
    test "ancestor/2, defined recursively in the conn, terminates and returns every solution" do
      assert run!("SELECT ancestor(\"tom\", Y) { Y }") == [
               %{"Y" => "bob"},
               %{"Y" => "ann"},
               %{"Y" => "pat"}
             ]
    end

    test "a leaf with no descendants has zero ancestor solutions" do
      assert run!("SELECT ancestor(\"pat\", Y) { Y }") == []
    end
  end

  describe "delegation to Scry.Core.QueryOps.run_flat/3 for everything else" do
    test "ORDER BY and LIMIT apply to the resolved rows" do
      assert run!("SELECT parent(X, Y) ORDER BY Y DESC LIMIT 1 { Y }") == [%{"Y" => "pat"}]
    end

    test "projection only returns the requested fields" do
      assert run!("SELECT parent(X, Y) { X }") == [
               %{"X" => "tom"},
               %{"X" => "bob"},
               %{"X" => "bob"}
             ]
    end

    test "a synthesized fresh-variable field never leaks into the projected row" do
      [row | _] = run!("SELECT parent(X, Y) WHERE age(Y) > 10 { X, Y }")
      refute Map.has_key?(row, "$goal_out_1")
    end
  end

  describe "external $params" do
    test "a $param goal argument resolves against the params map" do
      assert run!("SELECT parent(\"bob\", $child) { ok: \"matched\" }", %{"child" => "ann"}) ==
               [%{"ok" => "matched"}]
    end

    test "a missing $param is a clear query error, not a crash" do
      {:ok, query} = Scry.Logic.parse("SELECT parent(\"bob\", $child) { ok: \"matched\" }")

      assert {:error, {:query_error, {:missing_param, "child"}}} =
               Executor.execute(FamilyDB.conn(), query, %{})
    end
  end

  describe "stated scope limits" do
    test "goal_args: nil (an ordinary, non-goal query) is declined" do
      {:ok, query} = Scry.Logic.parse("SELECT users { name }")

      assert {:error, {:unsupported, {:construct, :non_goal_source}}} =
               Executor.execute(FamilyDB.conn(), query, %{})
    end

    test "a CombinedQuery (UNION/INTERSECT/EXCEPT) is declined" do
      {:ok, %CombinedQuery{} = combined} =
        Scry.Logic.parse("SELECT parent(X, Y) { Y } UNION SELECT parent(X, Y) { Y }")

      assert {:error, {:unsupported, {:construct, :combined_query}}} =
               Executor.execute(FamilyDB.conn(), combined, %{})
    end

    test "an unsupported goal-argument shape (an arithmetic expression) is declined clearly" do
      {:ok, query} = Scry.Logic.parse("SELECT parent(1 + 1, Y) { Y }")

      assert {:error, {:unsupported, {:goal_argument, _}}} =
               Executor.execute(FamilyDB.conn(), query, %{})
    end

    test "a goal call on the right side of a comparison is a parse error, not an executor concern" do
      assert {:error, _} = Scry.Logic.parse("SELECT parent(X, Y) WHERE 10 < age(Y) { X, Y }")
    end
  end

  describe "property: an arbitrary ground-fact relation" do
    property "SELECT rel(X, Y) { X, Y } always returns exactly the declared facts, in order" do
      check all(
              facts <-
                list_of(
                  {string(:alphanumeric, min_length: 1, max_length: 6),
                   string(:alphanumeric, min_length: 1, max_length: 6)},
                  max_length: 12
                )
            ) do
        clauses =
          Enum.map(facts, fn {x, y} ->
            fn [a, b] ->
              fn bindings ->
                with {:ok, b1} <- Bindings.unify(Term, bindings, a, x),
                     {:ok, b2} <- Bindings.unify(Term, b1, b, y) do
                  Tree.unit().(b2)
                else
                  :fail -> Tree.fail().(bindings)
                end
              end
            end
          end)

        conn = %{{"rel", 2} => clauses}
        {:ok, query} = Scry.Logic.parse("SELECT rel(X, Y) { X, Y }")
        {:ok, rows} = Executor.execute(conn, query, %{})

        expected = Enum.map(facts, fn {x, y} -> %{"X" => x, "Y" => y} end)
        assert Enum.to_list(rows) == expected
      end
    end

    property "a ground first argument only ever returns facts whose own first element matches" do
      check all(
              facts <-
                list_of(
                  {member_of(~w(a b c)), string(:alphanumeric, min_length: 1, max_length: 6)},
                  max_length: 12
                ),
              target <- member_of(~w(a b c))
            ) do
        clauses =
          Enum.map(facts, fn {x, y} ->
            fn [a, b] ->
              fn bindings ->
                with {:ok, b1} <- Bindings.unify(Term, bindings, a, x),
                     {:ok, b2} <- Bindings.unify(Term, b1, b, y) do
                  Tree.unit().(b2)
                else
                  :fail -> Tree.fail().(bindings)
                end
              end
            end
          end)

        conn = %{{"rel", 2} => clauses}
        {:ok, query} = Scry.Logic.parse("SELECT rel(\"#{target}\", Y) { Y }")
        {:ok, rows} = Executor.execute(conn, query, %{})

        expected = for {x, y} <- facts, x == target, do: %{"Y" => y}
        assert Enum.to_list(rows) == expected
      end
    end
  end

  describe "run/3 wraps the result in a Scry.Core.Cursor" do
    test "run/3 returns a real, iterable cursor" do
      {:ok, query} = Scry.Logic.parse("SELECT parent(X, Y) { X, Y }")
      assert {:ok, cursor} = Executor.run(query, FamilyDB.conn())
      assert Scry.Core.Cursor.to_list(cursor) == run!("SELECT parent(X, Y) { X, Y }")
    end
  end
end
