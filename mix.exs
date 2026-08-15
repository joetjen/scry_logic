defmodule Scry.Logic.MixProject do
  use Mix.Project

  @version "0.1.0"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :scry_logic,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Scry.Logic",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix, :ichor_runtime]]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # `test/support/family_db.ex` -- a shared clause-database fixture
  # (Scry.Logic.Test.FamilyDB) several test files reuse, the standard
  # Phoenix-style `elixirc_paths` convention (not an established
  # pattern elsewhere in this ecosystem's own kind packages, none of
  # which have needed a shared test fixture module of their own yet).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # === SCRY CORE ===
      # A local path dependency, not a Hex version constraint, since
      # scry_core isn't published to Hex yet. Real, unscoped -- Scry.
      # Logic.parse/1 calls Scry.Core.parse/1 at runtime, and Scry.
      # Logic.Executor implements Scry.Core.EngineBehaviour directly.
      # No grammar fragment of its own to compose -- the
      # `SELECT <name>(<args>) { ... }` call-shaped source
      # (`goal_args`) is a plain scry_core grammar addition now, not an
      # EP1/EP2 extension point this package fills (Scry.Core.Query's
      # own moduledoc has the full reasoning), so scry_logic is a
      # degenerate kind the same way scry_relational/scry_olap are,
      # despite having a real executor unlike either of them.
      {:scry_core, path: "../scry_core"},

      # === ICHOR RUNTIME ===
      # Real, unscoped (not only: [:dev, :test]) -- Scry.Logic.Executor
      # calls Ichor.Backtrack.Tree/Bindings/Term at *runtime* to run
      # SLD-resolution, unlike every other kind package's own only-for
      # -grammar-generation use of ichor_runtime. No grammar to compose
      # or compile ahead of time here at all, so plain `ichor` (the
      # grammar *compiler*) isn't a dependency in any form -- only the
      # runtime unification/backtracking substrate is.
      {:ichor_runtime, "~> 0.2"},

      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `MIX_ENV=test mix credo`
      # Dialyzer is invoked via `MIX_ENV=test mix dialyzer`
      # Sobelow is invoked via `MIX_ENV=test mix sobelow`
      # Coveralls is invoked via `MIX_ENV=test mix coveralls

      # === TESTING ===
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
      # ExDoc is invoked via `MIX_ENV=dev mix docs`
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "The logic kind for Scry -- Prolog/Datalog-shaped querying, a " <>
      "call-shaped source resolved via real SLD-resolution/unification (Ichor.Backtrack) " <>
      "against clauses a backend conn supplies; Scry has no rule-authoring syntax of its own."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/scry_logic"},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/scry_logic",
      source_ref: "v#{@version}",
      extras: extras()
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ]
  end
end
