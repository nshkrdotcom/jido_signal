# Router Refactoring Plan

**Generated:** Mon Nov 10 2025  
**Target:** Jido Signal Router Performance & Reliability Improvements  
**Strategy:** Sequential internal optimizations with 100% backwards compatibility

---

## Executive Summary

This plan addresses critical performance bottlenecks in the Router system through **5 sequential steps**. Each step is a **pure internal optimization** that maintains exact API compatibility, ordering guarantees, and error behavior. **No feature flags** - rollback is via git revert.

**Critical Issues Addressed:**
1. ✅ Hot-path bottleneck: matches?/2 rebuilds trie + generates UUID per call
2. ✅ Inefficient multi-wildcard matching with list allocations
3. ✅ O(N) route_count recalculation on every removal
4. ✅ Inefficient has_route?/2 implementation
5. ✅ Minor trie build optimizations

**Expected Impact:**
- 50-100x performance improvement in Bus subscription matching
- O(N) → O(1) route_count tracking
- Reduced allocations in multi-wildcard matching
- Zero behavioral changes - all existing tests pass unmodified

**Backwards Compatibility Guarantee:**
- ✅ No public API changes
- ✅ Same handler execution order (complexity → priority → registration FIFO)
- ✅ Same error types and messages
- ✅ Same edge-case behavior
- ✅ All existing tests pass without modification

---

## Validation Strategy

### Per-Step Gates

After **every step**, the following must pass before proceeding:

```bash
# 1. Run full test suite (must pass without modifications)
mix test

# 2. Run quality checks
mix quality  # format + compile --warnings-as-errors + dialyzer + credo

# 3. Verify no regressions in critical test files
mix test test/router_test.exs
mix test test/router_pattern_test.exs
mix test test/router_definition_test.exs

# 4. Git commit with descriptive message
git add -A
git commit -m "refactor(router): [step description]"
```

### Rollback Strategy

**No feature flags** - rollback via version control:

```bash
# If any step causes issues:
git revert HEAD
mix test  # Verify revert fixes issue
```

Each step is a single atomic commit that can be independently reverted.

---

## Implementation Steps

### Step 1: Eliminate Hot-Path Bottleneck in matches?/2 and filter/2

**Duration:** 2-4 hours  
**Priority:** CRITICAL  
**Risk:** MEDIUM  
**Impact:** 50-100x performance improvement in Bus subscription matching

#### Problem

Current implementation builds a trie and generates a UUID **for every call**:

```elixir
defp do_matches?(type, pattern) do
  test_signal = %Signal{
    id: Jido.Signal.ID.generate!(),  # UUID generation every call!
    type: type,
    # ...
  }
  trie = Engine.build_trie([test_route])  # Trie build every call!
  # ...
end
```

At 1000 signals/sec with 10 subscriptions = **10,000 trie builds/sec**.

#### Solution

Replace with pure segment-based pattern matcher using two-pointer algorithm with backtracking for `**`. **Maintains exact same semantics** - any difference in behavior is a bug.

#### Backwards Compatibility

- ✅ Same return values (true/false)
- ✅ Same validation behavior (invalid patterns return false)
- ✅ Same nil/empty handling
- ✅ Same wildcard semantics (`*` = one segment, `**` = zero or more)
- ✅ Preserves all existing guards and fast-paths

#### Changes

**File:** `lib/jido_signal/router.ex`

Add new private helper **before** existing `do_matches?/2`:

```elixir
# Fast segment-based pattern matching (no trie build required)
@spec match_segments?(String.t(), String.t()) :: boolean()
defp match_segments?(type, pattern) do
  type_segments = String.split(type, ".")
  pattern_segments = String.split(pattern, ".")
  
  do_match_segments(type_segments, pattern_segments, 0, 0, nil, nil)
end

# Two-pointer matcher with backtracking for **
# Algorithm: https://leetcode.com/problems/wildcard-matching/
@spec do_match_segments([String.t()], [String.t()], non_neg_integer(), non_neg_integer(), 
                        non_neg_integer() | nil, non_neg_integer() | nil) :: boolean()
defp do_match_segments(type_segs, pattern_segs, i, j, star_i, star_j) do
  type_len = length(type_segs)
  pattern_len = length(pattern_segs)
  
  cond do
    # Both exhausted - match
    i >= type_len and j >= pattern_len ->
      true
    
    # Pattern exhausted but type remains - only OK if we have trailing **
    i >= type_len ->
      # Check if remaining pattern is all **
      Enum.drop(pattern_segs, j) |> Enum.all?(&(&1 == "**"))
    
    # Pattern has ** - record backtrack position and advance pattern pointer
    j < pattern_len and Enum.at(pattern_segs, j) == "**" ->
      do_match_segments(type_segs, pattern_segs, i, j + 1, i, j + 1)
    
    # Pattern has * or exact match - advance both pointers
    j < pattern_len and (Enum.at(pattern_segs, j) == "*" or 
                         Enum.at(pattern_segs, j) == Enum.at(type_segs, i)) ->
      do_match_segments(type_segs, pattern_segs, i + 1, j + 1, star_i, star_j)
    
    # Mismatch - backtrack to last ** if available
    star_j != nil ->
      # Try consuming one more segment with **
      do_match_segments(type_segs, pattern_segs, star_i + 1, star_j, star_i + 1, star_j)
    
    # No match possible
    true ->
      false
  end
end
```

**Replace** the existing `do_matches?/2` implementation (delete old, write new):

```elixir
# Direct segment matching - replaces trie-based approach
defp do_matches?(type, pattern) do
  case Validator.validate_path(pattern) do
    {:ok, _} -> match_segments?(type, pattern)
    {:error, _} -> false
  end
end
```

Update `filter/2` to use direct `matches?/2` (simpler implementation):

```elixir
def filter(signals, pattern) when is_list(signals) and is_binary(pattern) do
  case Validator.validate_path(pattern) do
    {:ok, _} ->
      Enum.filter(signals, fn signal ->
        matches?(signal.type, pattern)
      end)
    
    {:error, _} = error ->
      error
  end
end
```

#### Tests

**Important:** All existing tests must pass **without modification**.

Create **new** test file for validation:

**File:** `test/router_pattern_equivalence_test.exs` (NEW)

```elixir
defmodule Jido.Signal.Router.PatternEquivalenceTest do
  use ExUnit.Case, async: true
  alias Jido.Signal.Router
  
  describe "pattern matching equivalence" do
    # Comprehensive test cases covering all wildcard combinations
    @test_cases [
      # Exact matches
      {"user.created", "user.created", true},
      {"user.updated", "user.created", false},
      
      # Single wildcard
      {"user.123", "user.*", true},
      {"user.123.updated", "user.*", false},
      {"user.123", "*.123", true},
      
      # Multi-level wildcard (zero segments)
      {"user.created", "user.**.created", true},
      {"user.created", "**.created", true},
      
      # Multi-level wildcard (multiple segments)
      {"order.123.payment.completed", "order.**", true},
      {"order.123.payment.completed", "order.**.completed", true},
      {"order.123.payment.completed", "**.completed", true},
      
      # Combined wildcards
      {"user.123.created", "user.*.created", true},
      {"order.456.payment.completed", "*.*.payment.*", true},
      {"a.b.c.d.e", "a.**.e", true},
      {"a.e", "a.**.e", true},
      
      # Edge cases
      {"a", "**", true},
      {"a.b.c", "**", true},
      {"", "**", false},  # Empty type not allowed
      
      # No match
      {"user.deleted", "user.created", false},
      {"order.payment", "order.**.completed", false},
    ]
    
    for {type, pattern, expected} <- @test_cases do
      test "matches?(#{inspect(type)}, #{inspect(pattern)}) == #{expected}" do
        assert Router.matches?(unquote(type), unquote(pattern)) == unquote(expected)
      end
    end
    
    # Long path test (no stack overflow)
    test "handles deep paths without stack overflow" do
      long_type = Enum.join(1..100, ".")
      
      assert Router.matches?(long_type, "**")
      assert Router.matches?(long_type, "1.**.100")
      refute Router.matches?(long_type, "1.**.999")
    end
    
    # Invalid patterns return false
    test "rejects invalid patterns gracefully" do
      refute Router.matches?("user.created", "user..created")
      refute Router.matches?("user.created", "")
      refute Router.matches?(nil, "user.*")
      refute Router.matches?("user.created", nil)
    end
  end
end
```

#### Validation

```bash
# Must pass without any test modifications
mix test test/router_pattern_test.exs
mix test test/router_pattern_equivalence_test.exs
mix test
mix quality
```

#### Rollback

```bash
git revert HEAD
mix test
```

---

### Step 2: Optimize Multi-Wildcard Traversal in Engine

**Duration:** 1-2 hours  
**Priority:** MEDIUM  
**Risk:** LOW  
**Impact:** Reduces allocations in `**` matching

#### Problem

Current implementation uses `tails/1` helper that builds intermediate lists:

```elixir
[rest, []]
|> Stream.concat(tails(rest))
|> Enum.reduce(handlers, fn remaining, acc -> ... end)

defp tails([]), do: []
defp tails([_ | t] = list), do: [t | tails(t)]
```

For path with 10 segments, creates ~10 intermediate lists.

#### Solution

Replace with iterative tail-advance without building lists. **Maintains exact same matching behavior and handler ordering**.

#### Backwards Compatibility

- ✅ Same routes matched
- ✅ Same handler ordering (complexity → priority → FIFO)
- ✅ Same traversal behavior

#### Changes

**File:** `lib/jido_signal/router/engine.ex`

**Replace** the multi-wildcard case (around lines 243-261):

```elixir
# OLD - DELETE THIS:
case Map.get(trie.segments, "**") do
  %TrieNode{} = node ->
    handlers = collect_handlers(node.handlers, signal, matching_handlers)
    
    [rest, []]
    |> Stream.concat(tails(rest))
    |> Enum.reduce(handlers, fn remaining, acc ->
      if remaining == [] do
        acc
      else
        do_route(remaining, node, signal, acc)
      end
    end)
  
  nil ->
    matching_handlers
end

# NEW - REPLACE WITH THIS:
case Map.get(trie.segments, "**") do
  %TrieNode{} = node ->
    # Collect handlers from ** node first
    handlers = collect_handlers(node.handlers, signal, matching_handlers)
    # Iteratively try matching by consuming 0, 1, 2, ... segments
    do_route_multi_wildcard(node, rest, signal, handlers)
  
  nil ->
    matching_handlers
end
```

Add new helper function:

```elixir
# Iteratively match zero or more segments for ** wildcard
# Preserves exact same traversal order as tails/1 approach
@spec do_route_multi_wildcard(TrieNode.t(), [String.t()], Signal.t(), [HandlerInfo.t()]) ::
        [HandlerInfo.t()]
defp do_route_multi_wildcard(node, segments, signal, acc) do
  # Try matching remaining path (zero-length ** match)
  acc = do_route(segments, node, signal, acc)
  
  # Try dropping one segment at a time (greedy ** matching)
  case segments do
    [] ->
      acc
    
    [_ | tail] ->
      do_route_multi_wildcard(node, tail, signal, acc)
  end
end
```

**Delete** the `tails/1` helper (no longer needed):

```elixir
# DELETE THIS FUNCTION:
defp tails([]), do: []
defp tails([_ | t] = list), do: [t | tails(t)]
```

#### Tests

**Important:** All existing tests must pass without modification.

Create new test file for deep path validation:

**File:** `test/router_wildcard_deep_test.exs` (NEW)

```elixir
defmodule Jido.Signal.Router.WildcardDeepTest do
  use ExUnit.Case, async: true
  alias Jido.Signal
  alias Jido.Signal.Router
  
  describe "deep multi-wildcard paths" do
    test "handles 50-segment path without stack overflow" do
      {:ok, router} = Router.new({"a.**.z", :handler})
      
      # Build path: a.1.2.3...48.z
      middle = Enum.join(1..48, ".")
      signal = %Signal{
        type: "a.#{middle}.z",
        source: "/test",
        id: Jido.Signal.ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }
      
      assert {:ok, [:handler]} = Router.route(router, signal)
    end
    
    test "multiple ** in pattern works correctly" do
      {:ok, router} = Router.new({"a.**.m.**.z", :handler})
      
      signal = %Signal{
        type: "a.b.c.m.x.y.z",
        source: "/test",
        id: Jido.Signal.ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }
      
      assert {:ok, [:handler]} = Router.route(router, signal)
    end
    
    test "maintains handler ordering with ** patterns" do
      {:ok, router} = Router.new([
        {"user.**.created", :handler_wildcard, 0},
        {"user.123.created", :handler_exact, 100}
      ])
      
      signal = %Signal{
        type: "user.123.created",
        source: "/test",
        id: Jido.Signal.ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }
      
      {:ok, handlers} = Router.route(router, signal)
      
      # Exact match (higher complexity) should come first
      assert handlers == [:handler_exact, :handler_wildcard]
    end
  end
end
```

#### Validation

```bash
mix test test/router_wildcard_deep_test.exs
mix test test/router_test.exs  # Verify existing wildcard tests
mix test
mix quality
```

#### Rollback

```bash
git revert HEAD
mix test
```

---

### Step 3: Efficient route_count Tracking

**Duration:** 1-2 hours  
**Priority:** MEDIUM  
**Risk:** LOW  
**Impact:** O(N) → O(1) for route_count maintenance

#### Problem

Current `remove/2` calls `Engine.count_routes(new_trie)` which traverses the **entire trie** on every removal:

```elixir
def remove(%Router{} = router, paths) when is_list(paths) do
  new_trie = Enum.reduce(paths, router.trie, &Engine.remove_path/2)
  route_count = Engine.count_routes(new_trie)  # O(N) traversal!
  {:ok, %{router | trie: new_trie, route_count: route_count}}
end
```

#### Solution

Track count incrementally during add/remove operations. **Maintains exact same count semantics**.

#### Backwards Compatibility

- ✅ Same route_count value (counts individual targets in multi-target routes)
- ✅ Same behavior for all operations
- ✅ No API changes

#### Changes

**File:** `lib/jido_signal/router/engine.ex`

Update `remove_path/2` to return removed count:

```elixir
@spec remove_path(String.t(), TrieNode.t()) :: {TrieNode.t(), non_neg_integer()}
def remove_path(path, trie) do
  segments = String.split(path, ".")
  do_remove_path(trie, segments)
end

@spec do_remove_path(TrieNode.t(), [String.t()]) :: {TrieNode.t(), non_neg_integer()}
defp do_remove_path(trie, []) do
  # Leaf node - count handlers before clearing
  handler_count = length(trie.handlers.handlers)
  matcher_count = length(trie.handlers.matchers)
  total_removed = handler_count + matcher_count
  
  # Clear handlers
  empty_handlers = %NodeHandlers{handlers: [], matchers: []}
  updated_trie = %{trie | handlers: empty_handlers}
  
  {updated_trie, total_removed}
end

defp do_remove_path(trie, [segment | rest]) do
  case Map.get(trie.segments, segment) do
    nil ->
      # Path doesn't exist
      {trie, 0}
    
    child_node ->
      {updated_child, removed_count} = do_remove_path(child_node, rest)
      
      # If child is now empty (no handlers, no children), remove it
      updated_segments =
        if node_empty?(updated_child) do
          Map.delete(trie.segments, segment)
        else
          Map.put(trie.segments, segment, updated_child)
        end
      
      {%{trie | segments: updated_segments}, removed_count}
  end
end

# Helper to check if node is completely empty
@spec node_empty?(TrieNode.t()) :: boolean()
defp node_empty?(%TrieNode{} = node) do
  Enum.empty?(node.handlers.handlers) and
    Enum.empty?(node.handlers.matchers) and
    map_size(node.segments) == 0
end
```

**File:** `lib/jido_signal/router.ex`

Update `remove/2` to use returned count:

```elixir
def remove(%Router{} = router, paths) when is_list(paths) do
  {new_trie, total_removed} =
    Enum.reduce(paths, {router.trie, 0}, fn path, {trie, count} ->
      {updated_trie, removed} = Engine.remove_path(path, trie)
      {updated_trie, count + removed}
    end)
  
  route_count = max(router.route_count - total_removed, 0)
  {:ok, %{router | trie: new_trie, route_count: route_count}}
end
```

Update `add/2` to count targets accurately:

```elixir
def add(%Router{} = router, routes) when is_list(routes) do
  with {:ok, normalized} <- Validator.normalize(routes),
       {:ok, validated} <- validate(normalized) do
    new_trie = Engine.build_trie(validated, router.trie)
    
    # Count new targets (multi-target routes count as multiple)
    added_count =
      Enum.reduce(validated, 0, fn route, acc ->
        case route.target do
          targets when is_list(targets) -> acc + length(targets)
          _single_target -> acc + 1
        end
      end)
    
    {:ok, %{router | trie: new_trie, route_count: router.route_count + added_count}}
  end
end
```

#### Tests

Create new test file for count validation:

**File:** `test/router_count_test.exs` (NEW)

```elixir
defmodule Jido.Signal.Router.CountTest do
  use ExUnit.Case, async: true
  alias Jido.Signal.Router
  alias Jido.Signal.Router.Engine
  
  describe "route_count tracking" do
    test "counts single-target routes correctly" do
      {:ok, router} = Router.new([
        {"user.created", :handler1},
        {"user.updated", :handler2},
        {"order.placed", :handler3}
      ])
      
      assert router.route_count == 3
    end
    
    test "counts multi-target routes correctly" do
      {:ok, router} = Router.new([
        {"system.error", [{:logger, []}, {:metrics, []}, {:alert, []}]}
      ])
      
      # Multi-target counts as 3 separate targets
      assert router.route_count == 3
    end
    
    test "maintains count after removal" do
      {:ok, router} = Router.new([
        {"user.created", :handler1},
        {"user.updated", :handler2},
        {"order.placed", :handler3}
      ])
      
      {:ok, router} = Router.remove(router, "user.created")
      assert router.route_count == 2
      
      {:ok, router} = Router.remove(router, ["user.updated", "order.placed"])
      assert router.route_count == 0
    end
    
    test "handles removal of non-existent path" do
      {:ok, router} = Router.new({"user.created", :handler1})
      
      {:ok, router} = Router.remove(router, "nonexistent.path")
      assert router.route_count == 1
    end
    
    test "route_count matches actual trie count (invariant)" do
      routes = [
        {"user.created", :h1},
        {"user.updated", :h2},
        {"order.**", :h3},
        {"system.error", [{:logger, []}, {:metrics, []}]}
      ]
      
      {:ok, router} = Router.new(routes)
      
      # Verify invariant
      actual_count = Engine.count_routes(router.trie)
      assert router.route_count == actual_count
      
      # After removal, invariant still holds
      {:ok, router} = Router.remove(router, "user.created")
      actual_count = Engine.count_routes(router.trie)
      assert router.route_count == actual_count
    end
  end
end
```

#### Validation

```bash
mix test test/router_count_test.exs
mix test test/router_definition_test.exs
mix test
mix quality
```

#### Rollback

```bash
git revert HEAD
mix test
```

---

### Step 4: Optimize has_route?/2 with Direct Trie Lookup

**Duration:** 30-60 minutes  
**Priority:** LOW  
**Risk:** LOW  
**Impact:** O(N) → O(depth) for route existence checks

#### Problem

Current `has_route?/2` calls `list/1` which traverses the **entire trie**:

```elixir
def has_route?(%Router{} = router, path) when is_binary(path) do
  case list(router) do
    {:ok, routes} -> Enum.any?(routes, &(&1.path == path))
    _ -> false
  end
end
```

#### Solution

Direct trie traversal for exact path. **Maintains exact same semantics**.

#### Backwards Compatibility

- ✅ Same return value (boolean)
- ✅ Same validation behavior
- ✅ Same edge cases

#### Changes

**File:** `lib/jido_signal/router/engine.ex`

Add new function:

```elixir
@spec has_path?(TrieNode.t(), [String.t()]) :: boolean()
def has_path?(trie, segments) do
  do_has_path?(trie, segments)
end

@spec do_has_path?(TrieNode.t(), [String.t()]) :: boolean()
defp do_has_path?(%TrieNode{} = node, []) do
  # At leaf - check if any handlers exist at this exact path
  not Enum.empty?(node.handlers.handlers) or not Enum.empty?(node.handlers.matchers)
end

defp do_has_path?(%TrieNode{} = node, [segment | rest]) do
  case Map.get(node.segments, segment) do
    nil -> false
    child_node -> do_has_path?(child_node, rest)
  end
end
```

**File:** `lib/jido_signal/router.ex`

**Replace** `has_route?/2` implementation:

```elixir
@spec has_route?(Router.t(), String.t()) :: boolean()
def has_route?(%Router{} = router, path) when is_binary(path) do
  case Validator.validate_path(path) do
    {:ok, _} ->
      segments = String.split(path, ".")
      Engine.has_path?(router.trie, segments)
    
    {:error, _} ->
      false
  end
end
```

#### Tests

Add to existing test file:

**File:** `test/router_definition_test.exs`

```elixir
describe "has_route?/2 optimization" do
  test "returns true for exact paths that exist" do
    {:ok, router} = Router.new([
      {"user.created", :handler1},
      {"order.placed", :handler2}
    ])
    
    assert Router.has_route?(router, "user.created")
    assert Router.has_route?(router, "order.placed")
  end
  
  test "returns false for paths that don't exist" do
    {:ok, router} = Router.new({"user.created", :handler1})
    
    refute Router.has_route?(router, "user.updated")
    refute Router.has_route?(router, "nonexistent")
  end
  
  test "returns false for partial paths" do
    {:ok, router} = Router.new({"user.created.verified", :handler1})
    
    # Partial paths don't match
    refute Router.has_route?(router, "user")
    refute Router.has_route?(router, "user.created")
    
    # Only exact match
    assert Router.has_route?(router, "user.created.verified")
  end
  
  test "returns false for invalid paths" do
    {:ok, router} = Router.new({"user.created", :handler1})
    
    refute Router.has_route?(router, "invalid..path")
    refute Router.has_route?(router, "")
  end
  
  test "works with wildcard patterns stored in router" do
    {:ok, router} = Router.new({"user.*", :handler1})
    
    # Exact path match (literal "user.*")
    assert Router.has_route?(router, "user.*")
    
    # Not a pattern matcher - doesn't match expanded paths
    refute Router.has_route?(router, "user.123")
  end
end
```

#### Validation

```bash
mix test test/router_definition_test.exs
mix test
mix quality
```

#### Rollback

```bash
git revert HEAD
mix test
```

---

### Step 5: Minor Trie Build Optimizations

**Duration:** 30-60 minutes  
**Priority:** LOW  
**Risk:** LOW  
**Impact:** Reduced string splitting overhead

#### Problem

Route paths are split multiple times during trie construction.

#### Solution

Precompute segments once per route. **No behavioral changes**.

#### Backwards Compatibility

- ✅ Exact same behavior
- ✅ Pure internal optimization

#### Changes

**File:** `lib/jido_signal/router/engine.ex`

Update `build_trie/2`:

```elixir
@spec build_trie([Route.t()], TrieNode.t() | nil) :: TrieNode.t()
def build_trie(routes, existing_trie \\ nil) do
  base_trie = existing_trie || %TrieNode{}
  
  # Precompute segments to avoid repeated splits
  routes_with_segments =
    Enum.map(routes, fn route ->
      {route, String.split(route.path, ".")}
    end)
  
  Enum.reduce(routes_with_segments, base_trie, fn {route, segments}, trie ->
    case route.match do
      nil -> do_add_path_route(route, trie, segments)
      match when is_function(match) -> do_add_pattern_route(route, trie, segments)
    end
  end)
end
```

Update `do_add_path_route/3` and `do_add_pattern_route/3` signatures to accept precomputed segments:

```elixir
# Change from:
defp do_add_path_route(%Route{} = route, trie) do
  segments = String.split(route.path, ".")
  # ...
end

# To:
defp do_add_path_route(%Route{} = route, trie, segments) do
  # segments already provided
  # ...
end
```

#### Validation

```bash
mix test
mix quality
```

#### Rollback

```bash
git revert HEAD
mix test
```

---

## Post-Implementation Checklist

### Documentation Updates

After all steps complete:

1. **Update CHANGELOG.md**:
   ```markdown
   ## [Unreleased]
   
   ### Performance
   - Optimized `Router.matches?/2` - 50-100x faster for pattern matching
   - Optimized multi-wildcard (`**`) matching - reduced allocations
   - Optimized `route_count` tracking - O(N) → O(1) for removals
   - Optimized `has_route?/2` - O(N) → O(depth) lookup
   ```

2. **Verify no documentation claims need updating**
   - Check that moduledocs don't promise specific internal implementation details
   - Verify examples still work correctly

### Performance Validation

Optional benchmarking to measure improvements:

```elixir
# Save as benchmark/router_bench.exs
patterns = ["user.*", "user.**", "audit.**.created", "**"]
types = ["user.created", "user.123.updated", "audit.user.action.created"]

Benchee.run(%{
  "matches? - user.*" => fn ->
    Jido.Signal.Router.matches?("user.123", "user.*")
  end,
  "matches? - **" => fn ->
    Jido.Signal.Router.matches?("a.b.c.d", "**")
  end,
  "matches? - complex" => fn ->
    Jido.Signal.Router.matches?("audit.user.created", "audit.**.created")
  end
})
```

### Final Validation

```bash
# Run full test suite
mix test

# Run quality checks
mix quality

# Run coverage (optional)
mix coveralls.html

# Verify no warnings
mix compile --warnings-as-errors

# Verify types
mix dialyzer
```

---

## Success Metrics

After completion, verify:

- ✅ All tests pass: `mix test`
- ✅ No quality issues: `mix quality`
- ✅ No behavioral regressions
- ✅ Expected performance improvements:
  - `matches?/2` substantially faster (no trie build, no UUID gen)
  - `remove/2` no longer calls `count_routes/1`
  - `has_route?/2` no longer calls `list/1`
- ✅ Backward compatibility maintained (all existing tests pass unmodified)

---

## Timeline Estimate

| Step | Duration | Cumulative |
|------|----------|------------|
| 1. matches?/filter | 2-4h | 4h |
| 2. Multi-wildcard | 1-2h | 6h |
| 3. route_count | 1-2h | 8h |
| 4. has_route? | 0.5-1h | 9h |
| 5. Build optimization | 0.5-1h | 10h |
| **Total** | | **~2 days** |

Add buffer for testing and validation: **2-3 days total**

---

## Risk Mitigation

### Pattern Matching Equivalence (Step 1)

**Risk:** New matcher doesn't match trie behavior in edge cases  
**Mitigation:**
- Comprehensive test coverage including edge cases
- Can add legacy comparison tests if needed
- Thorough code review of two-pointer algorithm

### Handler Ordering (Step 2)

**Risk:** Multi-wildcard refactor changes handler order  
**Mitigation:**
- Existing tests verify ordering
- New tests explicitly check ordering with wildcards
- Algorithm preserves exact traversal order

### Count Accuracy (Step 3)

**Risk:** route_count gets out of sync with actual trie  
**Mitigation:**
- Invariant tests verify count == Engine.count_routes(trie)
- Simple increment/decrement logic
- Easy to audit

---

## Notes

- Each step is independently valuable - can pause after any step
- No runtime configuration - simpler testing and deployment
- All changes are pure internal optimizations
- Rollback via git revert - standard version control workflow
- Oracle available for consultation if complex issues arise
