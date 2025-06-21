# Getting Started: Your First Signal Bus

This guide will get you up and running with Jido.Signal in minutes. We'll create a simple pub/sub system to demonstrate the core concepts.

## Installation

Add `jido_signal` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_signal, "~> 1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Starting a Bus

Add a named bus to your application's supervision tree. In your `application.ex`:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Other supervisors...
      {Jido.Signal.Bus, name: :my_bus}
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Creating a Subscriber

Build a simple `GenServer` that can receive signals:

```elixir
defmodule MyApp.UserHandler do
  use GenServer
  alias Jido.Signal.Bus

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Subscribe to all user-related signals
    Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self()})
    {:ok, %{}}
  end

  # Handle incoming signals
  def handle_info({:signal, signal}, state) do
    IO.puts("Received signal: #{signal.type}")
    IO.inspect(signal.data)
    {:noreply, state}
  end
end
```

## Subscribing to Signals

The `Bus.subscribe/3` function allows you to listen for signals matching a path pattern:

```elixir
# Subscribe to specific signal types
Bus.subscribe(:my_bus, "user.created", dispatch: {:pid, target: self()})

# Use wildcards to match multiple types
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self()})

# Match all signals under a path
Bus.subscribe(:my_bus, "user.**", dispatch: {:pid, target: self()})
```

## Publishing a Signal

Create and publish signals to the bus:

```elixir
# Create a basic signal
signal = Jido.Signal.new(%{
  type: "user.created",
  source: "user_service",
  data: %{
    user_id: 123,
    email: "user@example.com",
    name: "John Doe"
  }
})

# Publish to the bus
Bus.publish(:my_bus, signal)
```

## Putting It All Together

Here's a complete example that demonstrates the entire flow:

```elixir
defmodule MyApp.Example do
  use GenServer
  alias Jido.Signal.Bus

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Subscribe to user signals
    Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self()})
    
    # Publish a test signal after a short delay
    Process.send_after(self(), :publish_test, 1000)
    
    {:ok, %{}}
  end

  def handle_info(:publish_test, state) do
    signal = Jido.Signal.new(%{
      type: "user.created",
      source: "example",
      data: %{user_id: 123, name: "Test User"}
    })
    
    Bus.publish(:my_bus, signal)
    {:noreply, state}
  end

  def handle_info({:signal, signal}, state) do
    IO.puts("✓ Received signal: #{signal.type}")
    IO.puts("  Data: #{inspect(signal.data)}")
    {:noreply, state}
  end
end
```

Start this in your IEx session to see it work:

```elixir
# Start the example GenServer
{:ok, _pid} = MyApp.Example.start_link()

# You should see output like:
# ✓ Received signal: user.created
#   Data: %{user_id: 123, name: "Test User"}
```

## Next Steps

Now that you have a basic signal bus running, explore these topics:

- [Signal Structure](core-concepts/signal-structure.md) - Learn about signal anatomy
- [Signal Bus](core-concepts/signal-bus.md) - Dive deeper into bus features
- [Router](core-concepts/router.md) - Understand routing patterns
- [Dispatch System](core-concepts/dispatch-system.md) - Send signals to external destinations
