# Scry.Logic

The `logic` kind for [Scry](https://github.com/joetjen/scry) (lang_spec.md §8.4) --
Prolog/Datalog-shaped querying:

```
SELECT ancestor(X, "bob") WHERE age(X) > 30 { X }
```

Facts and rules live entirely in a backend `conn`; Scry has no rule-authoring
syntax of its own and never parses or reasons about a rule body. `Scry.Logic.Executor`
resolves a goal-shaped query via real SLD-resolution/unification
([`Ichor.Backtrack`](https://hexdocs.pm/ichor_runtime)), against a `conn` shaped
`%{{name, arity} => [clause_fun]}` -- see that module's own moduledoc for the full
architecture, including a genuinely load-bearing gotcha for anyone writing a
recursive relation.

Degenerate at the grammar level (no EP1/EP2 vocabulary of its own -- a call-shaped
source is a plain `scry_core` grammar addition), real at the execution level, unlike
`scry_relational`/`scry_olap`.

See `CHANGELOG.md` for what's landed. `scry_test_logic` exercises this package end to
end against a real fixture family-tree database.
