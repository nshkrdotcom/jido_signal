# Guide: The Router

The Router is Jido.Signal's intelligent routing engine that uses a trie-based data structure to efficiently match signals to handlers. It supports complex path patterns and sophisticated prioritization rules.

## Trie-Based Routing Engine

The router uses a prefix tree (trie) to organize and match signal paths efficiently:

```
user
├── created
├── updated
├── deleted
└── profile
    ├── updated
    └── verified
```

This structure allows for O(k) lookup time where k is the path depth, making routing extremely fast even with thousands of subscriptions.

## Path Patterns

The router supports three types of path matching:

### Exact Matches

```elixir
# Matches only "user.created"
"user.created"
```

### Single-Level Wildcards (`*`)

The `*` wildcard matches exactly one path segment:

```elixir
# Matches: "user.created", "user.updated", "user.deleted"
# Does NOT match: "user.profile.updated"
"user.*"

# Matches: "order.item.added", "order.item.removed"  
# Does NOT match: "order.created" or "order.item.stock.updated"
"order.item.*"
```

### Multi-Level Wildcards (`**`)

The `**` wildcard matches any number of path segments:

```elixir
# Matches: "user.created", "user.profile.updated", "user.settings.privacy.changed"
"user.**"

# Matches anything under the payment namespace
"payment.**"

# Matches all signals
"**"
```

## Pattern Examples

```elixir
alias Jido.Signal.Bus

# Exact subscription
Bus.subscribe(:my_bus, "user.created", dispatch: {:pid, target: self()})

# Single-level wildcard - all direct user events
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self()})

# Multi-level wildcard - all user-related events
Bus.subscribe(:my_bus, "user.**", dispatch: {:pid, target: self()})

# Complex patterns
Bus.subscribe(:my_bus, "payment.transaction.*", dispatch: {:pid, target: self()})
Bus.subscribe(:my_bus, "inventory.**.low", dispatch: {:pid, target: self()})
```

## Execution Order and Priority

When multiple patterns match a signal, the router determines execution order using three criteria:

### 1. Path Specificity (Complexity)

More specific patterns execute first:

```elixir
# For signal "user.profile.updated", execution order is:
# 1. "user.profile.updated"  (exact match - highest specificity)
# 2. "user.profile.*"        (single wildcard)
# 3. "user.*"                (single wildcard, less specific)
# 4. "user.**"               (multi-level wildcard)
# 5. "**"                    (catch-all - lowest specificity)
```

### 2. Explicit Priority

You can override natural ordering with explicit priority:

```elixir
# Higher priority numbers execute first
Bus.subscribe(:my_bus, "user.**", dispatch: {:pid, target: audit_logger}, priority: 1000)
Bus.subscribe(:my_bus, "user.created", dispatch: {:pid, target: welcome_sender}, priority: 500)
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: analytics}, priority: 100)
```

### 3. Registration Order

For handlers with the same specificity and priority, first-registered executes first:

```elixir
# These will execute in registration order
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: handler_a})  # First
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: handler_b})  # Second
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: handler_c})  # Third
```

## Standalone Router Usage

You can use the router directly for advanced scenarios:

### Creating a Router

```elixir
alias Jido.Signal.Router

# Create a new router
{:ok, router} = Router.new()

# Add routes
{:ok, route_id} = Router.add_route(router, "user.*", %{handler: :user_handler})
{:ok, route_id} = Router.add_route(router, "payment.**", %{handler: :payment_handler})
```

### Matching Routes

```elixir
# Find matching routes for a signal path
matches = Router.match(router, "user.created")
# Returns: [%{pattern: "user.*", handler: :user_handler, priority: 0}]

# Get all routes
all_routes = Router.list_routes(router)
```

### Route Management

```elixir
# Remove a route
Router.remove_route(router, route_id)

# Update route priority
Router.update_route(router, route_id, %{priority: 500})

# Clear all routes
Router.clear(router)
```

## Advanced Routing Patterns

### Conditional Routing

Combine path patterns with filters for sophisticated routing:

```elixir
Bus.subscribe(:my_bus, "user.*", [
  dispatch: {:pid, target: premium_handler},
  filter: fn signal ->
    signal.data.subscription_type == "premium"
  end,
  priority: 100
])

Bus.subscribe(:my_bus, "user.*", [
  dispatch: {:pid, target: standard_handler},
  filter: fn signal ->
    signal.data.subscription_type != "premium"
  end,
  priority: 50
])
```

### Hierarchical Processing

Use wildcards to create processing hierarchies:

```elixir
# Catch-all logging (lowest priority)
Bus.subscribe(:my_bus, "**", [
  dispatch: {:logger, level: :debug},
  priority: 1
])

# Domain-specific logging
Bus.subscribe(:my_bus, "user.**", [
  dispatch: {:logger, level: :info, prefix: "USER"},
  priority: 10
])

# Critical event alerting
Bus.subscribe(:my_bus, "user.deleted", [
  dispatch: {:webhook, url: "https://alerts.example.com"},
  priority: 1000
])
```

### Fan-Out Patterns

Route single signals to multiple handlers:

```elixir
# A single signal can trigger multiple handlers
Bus.subscribe(:my_bus, "order.completed", dispatch: {:pid, target: inventory_updater})
Bus.subscribe(:my_bus, "order.completed", dispatch: {:pid, target: email_sender})
Bus.subscribe(:my_bus, "order.completed", dispatch: {:pid, target: analytics_tracker})
Bus.subscribe(:my_bus, "order.completed", dispatch: {:webhook, url: "https://api.crm.com"})
```

## Pattern Matching Behavior

### Edge Cases

```elixir
# Empty segments are significant
"user..created"     # Matches signal with empty segment: ["user", "", "created"]
"user.*."          # Matches: "user.something." (with trailing empty segment)

# Multiple wildcards
"*.user.*"         # Matches: "app.user.created", "service.user.updated"
"**.critical.**"   # Matches any path containing "critical"
```

### Escape Sequences

Special characters in literal paths:

```elixir
# To match literal dots, use escape sequences in custom implementations
# The standard router treats all dots as path separators
```

## Performance Characteristics

### Lookup Performance

- **O(k)** where k is the path depth
- **Memory efficient** with shared prefixes
- **Fast wildcard matching** using trie traversal

### Optimization Tips

```elixir
# More specific patterns first for better cache locality
Bus.subscribe(:my_bus, "user.profile.updated", ...)  # Specific
Bus.subscribe(:my_bus, "user.*", ...)                # General

# Use appropriate wildcard types
"user.*"     # When you only want direct children
"user.**"    # When you want all descendants
```

### Benchmarking

```elixir
# Test routing performance
signal = Jido.Signal.new(%{type: "user.profile.updated", source: "test"})

{time, _result} = :timer.tc(fn ->
  Router.match(router, signal.type)
end)

IO.puts("Routing took #{time} microseconds")
```

## Best Practices

### Pattern Design

1. **Use hierarchical naming**: `domain.entity.action`
2. **Be consistent**: Choose a naming convention and stick to it
3. **Avoid deep nesting**: Keep paths readable and manageable
4. **Use meaningful names**: Make patterns self-documenting

### Performance Optimization

1. **Register specific patterns first** for better cache performance
2. **Use single-level wildcards** when you don't need deep matching
3. **Batch route additions** when possible
4. **Monitor routing performance** in high-throughput scenarios

### Error Handling

```elixir
# Handle routing errors gracefully
case Router.add_route(router, pattern, handler_config) do
  {:ok, route_id} -> 
    # Success
  {:error, :invalid_pattern} -> 
    # Handle invalid pattern
  {:error, reason} -> 
    # Handle other errors
end
```

The Router provides the foundation for building sophisticated, high-performance event routing systems that can scale to handle complex signal distribution patterns.
