# Drag-n-Stamp Agent Context

This file provides context for AI agents working on the Drag-n-Stamp codebase.

## Commands

- **Setup:** `mix setup` (install dependencies, create and migrate database)
- **Run server:** `mix phx.server`
- **Build assets:** `mix assets.build`
- **Run all tests:** `mix test`
- **Run a single test file:** `mix test test/path/to/file_test.exs`
- **Run a single test:** `mix test test/path/to/file_test.exs:line_number`
- **Format code:** `mix format`

## Code Style

- **Formatting:** Adhere to the rules in `.formatter.exs`. Use `mix format` to automatically format code.
- **Imports:** Follow existing conventions. Keep imports clean and organized at the top of the file.
- **Naming:** Use `snake_case` for variables and function names. Use `CamelCase` for module names. This is standard Elixir convention.
- **Error Handling:** Use `with` statements for complex logic paths and pattern match on return values (e.g., `{:ok, result}` and `{:error, reason}`).
- **Types:** Add `@spec` typespecs for public functions to improve code clarity and maintainability.
- **Testing:** Tests are written with `ExUnit` and use `DragNStampWeb.ConnCase` for controller tests. Assertions should be explicit and clear.
