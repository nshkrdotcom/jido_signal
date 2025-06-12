Of course. Based on the provided codebase, here are several detailed architectural diagrams rendered using Mermaid's text-based format. These diagrams illustrate the key components, their interactions, and the primary data flows within the `jido_signal` library.

### 1. High-Level Component Architecture

This diagram provides a C4-style component view of the Jido Signal system. It shows the main logical blocks, their responsibilities, and how they interact. It's a high-level overview of the entire library.

**Key Observations from the Code:**

*   **`Jido.Signal.Bus`** is the central `GenServer` that orchestrates most operations.
*   The `Bus` uses **`Jido.Signal.Router`** for matching signals to subscribers and **`Jido.Signal.Dispatch`** to send them.
*   The `Bus` manages its `BusState`, which contains the signal log and subscription data.
*   A `MiddlewarePipeline` intercepts signals at various stages (`before_publish`, `before_dispatch`, etc.).
*   For durable subscriptions, the `Bus` spawns and manages **`PersistentSubscription`** `GenServer`s.
*   The **`Dispatch`** module uses a pluggable adapter system to deliver signals to various targets like PIDs, HTTP endpoints, and PubSub systems.
*   **`Bus.Snapshot`** and **`Jido.Signal.Journal`** provide state and causality persistence.

```mermaid
graph TD
    subgraph "Client Application"
        Client(Client Code)
    end

    subgraph "Jido Signal Bus Core"
        Bus[Jido.Signal.Bus<br/><i>GenServer</i>]
        Router[Jido.Signal.Router<br/><i>Trie Engine</i>]
        Middleware[Middleware Pipeline]
        Dispatch[Jido.Signal.Dispatch]
        State[BusState<br/><i>Signal Log & Subscriptions</i>]
    end

    subgraph "Pluggable Dispatch Adapters"
        PidAdapter[PidAdapter]
        HttpAdapter[HttpAdapter]
        WebhookAdapter[WebhookAdapter]
        PubSubAdapter[PubSubAdapter]
        LoggerAdapter[LoggerAdapter]
        Adapters[...]
    end

    subgraph "Persistence & State Management"
        PersistentSub[PersistentSubscription<br/><i>GenServer</i>]
        Journal[Jido.Signal.Journal<br/><i>Causality Tracking</i>]
        Snapshot[Bus.Snapshot<br/><i>:persistent_term</i>]
    end

    Client -- "1. publish(signal)" --> Bus
    Client -- "2. subscribe(path, opts)" --> Bus

    Bus -- "Uses for state" --> State
    Bus -- "3. Finds subscribers via" --> Router
    Bus -- "4. Intercepts via" --> Middleware
    Bus -- "5. Delivers via" --> Dispatch
    Bus -- "Spawns for durability" --> PersistentSub
    Bus -- "Creates for point-in-time views" --> Snapshot

    Dispatch -- "Delegates to" --> PidAdapter
    Dispatch -- "Delegates to" --> HttpAdapter
    Dispatch -- "Delegates to" --> WebhookAdapter
    Dispatch -- "Delegates to" --> PubSubAdapter
    Dispatch -- "Delegates to" --> LoggerAdapter
    Dispatch -- "Delegates to" --> Adapters

    PersistentSub -- "Sends signals to" --> Client
    Client -- "acks()" --> Bus
    Bus -- "Forwards acks to" --> PersistentSub

    WebhookAdapter -- "Extends" --> HttpAdapter

    %% Elixir-inspired styling
    classDef userLayer fill:#4e2a8e,stroke:#24292e,stroke-width:2px,color:#fff
    classDef coreAbstraction fill:#7c4dbd,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef keyModule fill:#9b72d0,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef clientLayer fill:#b89ce0,stroke:#4e2a8e,stroke-width:2px,color:#24292e
    classDef serviceLayer fill:#d4c5ec,stroke:#4e2a8e,stroke-width:1px,color:#24292e
    classDef externalSystem fill:#f5f5f5,stroke:#666,stroke-width:1px,color:#24292e
    classDef adapter fill:#fdfbf7,stroke:#4e2a8e,stroke-width:2px,color:#24292e

    class Client clientLayer
    class Bus keyModule
    class Router keyModule
    class Middleware keyModule
    class Dispatch keyModule
    class State keyModule
    class PidAdapter adapter
    class HttpAdapter adapter
    class WebhookAdapter adapter
    class PubSubAdapter adapter
    class LoggerAdapter adapter
    class Adapters adapter
    class PersistentSub serviceLayer
    class Journal serviceLayer
    class Snapshot serviceLayer

    %% Darker arrow styling for better visibility
    linkStyle default stroke:#24292e,stroke-width:2px
```

---

### 2. Signal Publishing Flow

This sequence diagram details the journey of a signal from the moment it's published to the bus until it's dispatched to a subscriber. It highlights the role of middleware in the processing pipeline.

**Key Observations from the Code:**

*   The `Bus.publish/2` function is a `GenServer.call`.
*   The `MiddlewarePipeline.before_publish` hook runs first, allowing signal modification or halting the publish action.
*   Signals are recorded in the `BusState`'s log.
*   The bus iterates through subscriptions, using `Router.matches?` to find relevant subscribers.
*   For each match, `MiddlewarePipeline.before_dispatch` runs, followed by `Dispatch.dispatch`.
*   Finally, the `after_dispatch` and `after_publish` hooks run for side-effects like logging.

```mermaid
sequenceDiagram
    participant Client
    participant Bus as Jido.Signal.Bus (GenServer)
    participant Middleware as MiddlewarePipeline
    participant State as BusState
    participant Dispatch
    participant Subscriber

    Client->>+Bus: publish(signals)
    Bus->>Middleware: before_publish(signals)
    Middleware-->>Bus: {:ok, processed_signals}

    Bus->>State: append_signals(processed_signals)
    State-->>Bus: {:ok, new_state}
    Note right of Bus: Signals are now in the log.

    loop For each signal in processed_signals
        loop For each subscription
            Bus->>Bus: Check if signal.type matches subscription.path
            opt Match found
                Bus->>Middleware: before_dispatch(signal, subscription)
                Middleware-->>Bus: {:ok, processed_signal}
                Bus->>Dispatch: dispatch(processed_signal, subscription.dispatch)
                Dispatch->>Subscriber: Delivers signal via adapter
                Bus->>Middleware: after_dispatch(signal, subscription, result)
            end
        end
    end

    Bus->>Middleware: after_publish(processed_signals)

    Bus-->>-Client: {:ok, recorded_signals}
```

---

### 3. Persistent Subscription Flow

This diagram illustrates the process of creating and using a persistent subscription. It shows how the `Bus` coordinates with a `DynamicSupervisor` to spawn a dedicated `PersistentSubscription` process to manage state for a durable client.

**Key Observations from the Code:**

*   `Bus.subscribe` delegates to the `Jido.Signal.Bus.Subscriber` module.
*   If `persistent?` is true, a child process is started under the `Bus`'s `DynamicSupervisor`.
*   The child process is a `Jido.Signal.Bus.PersistentSubscription` GenServer, which manages its own state (checkpoint, in-flight signals).
*   When signals are published, the `Bus` dispatches them to the `PersistentSubscription` process, not directly to the client.
*   The `PersistentSubscription` process then forwards the signal to the client PID and waits for an `ack`.
*   `ack`s update the subscription's checkpoint, allowing it to resume from the correct position after a disconnect.

```mermaid
sequenceDiagram
    participant Client
    participant Bus as Jido.Signal.Bus (GenServer)
    participant SubscriberMod as Bus.Subscriber (Module)
    participant DynSupervisor as DynamicSupervisor
    participant PersistentSub as PersistentSubscription (GenServer)

    Client->>+Bus: subscribe(path, persistent?: true)
    Bus->>SubscriberMod: subscribe(state, path, opts)
    Note over SubscriberMod: persistent? is true
    SubscriberMod->>DynSupervisor: start_child(PersistentSubscription, opts)
    DynSupervisor->>+PersistentSub: start_link(opts)
    PersistentSub->>PersistentSub: init() - monitors Client
    PersistentSub-->>-DynSupervisor: {:ok, pid}
    DynSupervisor-->>SubscriberMod: {:ok, pid}
    SubscriberMod-->>Bus: {:ok, new_state_with_sub}
    Bus-->>-Client: {:ok, subscription_id}

    Note over Client, PersistentSub: Subscription is now active.

    participant AnotherClient
    AnotherClient->>+Bus: publish(signal)
    Note over Bus: Signal matches persistent subscription path
    Bus->>PersistentSub: cast {:signal, signal}
    PersistentSub->>PersistentSub: Add to in_flight_signals
    PersistentSub->>Client: Delivers signal via dispatch config
    Bus-->>-AnotherClient: {:ok, ...}

    Note over Client, PersistentSub: Client processes signal...

    Client->>+Bus: ack(subscription_id, signal.id)
    Bus->>PersistentSub: cast {:ack, signal.id}
    PersistentSub->>PersistentSub: Removes from in_flight_signals<br/>Updates checkpoint
    Bus-->>-Client: :ok
```

---

### 4. Dispatch Subsystem Architecture

This class diagram illustrates the design of the `Dispatch` module, which follows the **Strategy Pattern**. It defines a common `Adapter` behaviour (interface) and provides multiple concrete implementations (strategies) for different delivery mechanisms.

**Key Observations from the Code:**

*   `Jido.Signal.Dispatch.Adapter` defines the behaviour with `validate_opts/1` and `deliver/2` callbacks.
*   Modules like `PidAdapter`, `HttpAdapter`, and `PubSubAdapter` are concrete implementations of this behaviour.
*   `WebhookAdapter` is a specialized version of `HttpAdapter`, reusing its core logic and adding signature generation.
*   The `Jido.Signal.Dispatch` module acts as the "Context" in the pattern. It receives a configuration (e.g., `{:http, [...]}`), resolves the correct adapter module, and delegates the delivery task to it.

```mermaid
classDiagram
    direction LR

    class Dispatch {
        <<Context>>
        +dispatch(signal, config)
        +dispatch_async(signal, config)
        +dispatch_batch(signal, configs)
        -resolve_adapter(adapter_name) module
        -dispatch_single(signal, config)
    }

    class Adapter {
        <<Interface>>
        +validate_opts(opts)
        +deliver(signal, opts)
    }

    class PidAdapter {
        +validate_opts(opts)
        +deliver(signal, opts)
    }
    class HttpAdapter {
        +validate_opts(opts)
        +deliver(signal, opts)
    }
    class WebhookAdapter {
        +validate_opts(opts)
        +deliver(signal, opts)
    }
    class PubSubAdapter {
        +validate_opts(opts)
        +deliver(signal, opts)
    }
    class NoopAdapter {
        +validate_opts(opts)
        +deliver(signal, opts)
    }
    class LoggerAdapter {
        +validate_opts(opts)
        +deliver(signal, opts)
    }
    class OtherAdapters {
        ...
    }


    Dispatch --> Adapter : uses
    Adapter <|-- PidAdapter
    Adapter <|-- HttpAdapter
    Adapter <|-- WebhookAdapter
    Adapter <|-- PubSubAdapter
    Adapter <|-- NoopAdapter
    Adapter <|-- LoggerAdapter
    Adapter <|-- OtherAdapters

    WebhookAdapter --|> HttpAdapter : extends

    %% Elixir-inspired styling
    classDef userLayer fill:#4e2a8e,stroke:#24292e,stroke-width:2px,color:#fff
    classDef coreAbstraction fill:#7c4dbd,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef keyModule fill:#9b72d0,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef clientLayer fill:#b89ce0,stroke:#4e2a8e,stroke-width:2px,color:#24292e
    classDef serviceLayer fill:#d4c5ec,stroke:#4e2a8e,stroke-width:1px,color:#24292e
    classDef externalSystem fill:#f5f5f5,stroke:#666,stroke-width:1px,color:#24292e
    classDef adapter fill:#fdfbf7,stroke:#4e2a8e,stroke-width:2px,color:#24292e

    class Dispatch keyModule
    class Adapter coreAbstraction
    class PidAdapter adapter
    class HttpAdapter adapter
    class WebhookAdapter adapter
    class PubSubAdapter adapter
    class NoopAdapter adapter
    class LoggerAdapter adapter
    class OtherAdapters adapter
```

---

### 5. Router Engine Trie Structure

This diagram provides a conceptual view of the internal trie (prefix tree) data structure used by the `Router` to efficiently match signal types to handlers. It illustrates how different path patterns, including wildcards, are represented as nodes in the tree.

**Key Observations from the Code:**

*   `Jido.Signal.Router.Engine` builds and traverses this structure.
*   Each segment of a path (e.g., "user", "created") becomes a node in the trie.
*   Wildcards (`*` and `**`) are treated as special segment nodes.
*   `HandlerInfo` and `PatternMatch` structs are attached to nodes, representing the final target(s) for a matched path.
*   Routing involves traversing the trie segment by segment. When a wildcard node is encountered, the engine explores multiple matching paths. This structure allows for very fast lookups, as the time complexity is proportional to the length of the signal type's path, not the total number of routes.

```mermaid
graph TD
    Root["(root)"]

    subgraph "Example Routes"
        direction LR
        R1["<b>user.created</b> → H1"]
        R2["<b>user.*.notified</b> → H2"]
        R3["<b>payment.**</b> → H3"]
    end

    Root --> User(user)
    Root --> Payment(payment)

    User --> Created(created)
    User --> WildcardSingle("*")

    Created -- "Path Ends" --> Handler1[HandlerInfo: H1]

    WildcardSingle --> Notified(notified)
    Notified -- "Path Ends" --> Handler2[HandlerInfo: H2]

    Payment --> WildcardMulti("**")
    WildcardMulti -- "Matches Rest of Path" --> Handler3[HandlerInfo: H3]

    %% Elixir-inspired styling
    classDef userLayer fill:#4e2a8e,stroke:#24292e,stroke-width:2px,color:#fff
    classDef coreAbstraction fill:#7c4dbd,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef keyModule fill:#9b72d0,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef clientLayer fill:#b89ce0,stroke:#4e2a8e,stroke-width:2px,color:#24292e
    classDef serviceLayer fill:#d4c5ec,stroke:#4e2a8e,stroke-width:1px,color:#24292e
    classDef externalSystem fill:#f5f5f5,stroke:#666,stroke-width:1px,color:#24292e
    classDef adapter fill:#fdfbf7,stroke:#4e2a8e,stroke-width:2px,color:#24292e

    class Root serviceLayer
    class User serviceLayer
    class Payment serviceLayer
    class Created serviceLayer
    class WildcardSingle serviceLayer
    class Notified serviceLayer
    class WildcardMulti serviceLayer
    class Handler1 keyModule
    class Handler2 keyModule
    class Handler3 keyModule

    %% Darker arrow styling for better visibility
    linkStyle default stroke:#24292e,stroke-width:2px
```

---

### 6. Serialization Subsystem Architecture

This class diagram shows the architecture of the serialization system. It follows the **Strategy Pattern**, where a common `Serializer` behaviour defines the interface, and concrete modules (`JsonSerializer`, `ErlangTermSerializer`, etc.) provide specific implementations. This allows the system to be flexible and support multiple data formats.

**Key Observations from the Code:**

*   `Jido.Signal.Serialization.Serializer` defines the `serialize/2` and `deserialize/2` callbacks.
*   The `Jido.Signal.serialize/2` and `deserialize/2` functions act as the "Context", selecting the appropriate serializer at runtime based on configuration or options.
*   Helper protocols like `TypeProvider` (for mapping structs to string types) and `JsonDecoder` (for custom post-deserialization logic) are used by the serializers to handle Elixir-specific data structures correctly.

```mermaid
classDiagram
    direction TB

    class Signal {
        <<Client>>
        +serialize(signal, opts)
        +deserialize(binary, opts)
    }

    class Serializer {
        <<Interface>>
        +serialize(term, opts)
        +deserialize(binary, opts)
    }

    class JsonSerializer {
        +serialize(term, opts)
        +deserialize(binary, opts)
    }
    class ErlangTermSerializer {
        +serialize(term, opts)
        +deserialize(binary, opts)
    }
    class MsgpackSerializer {
        +serialize(term, opts)
        +deserialize(binary, opts)
    }

    class TypeProvider {
        <<Helper Protocol>>
        +to_string(struct)
        +to_struct(string)
    }

    class JsonDecoder {
        <<Helper Protocol>>
        +decode(data)
    }

    Signal --> Serializer : "delegates to"
    Serializer <|-- JsonSerializer
    Serializer <|-- ErlangTermSerializer
    Serializer <|-- MsgpackSerializer

    JsonSerializer ..> TypeProvider : "uses for struct mapping"
    JsonSerializer ..> JsonDecoder : "uses for post-processing"
    ErlangTermSerializer ..> TypeProvider : "uses for struct mapping"
    MsgpackSerializer ..> TypeProvider : "uses for struct mapping"

    %% Elixir-inspired styling
    classDef userLayer fill:#4e2a8e,stroke:#24292e,stroke-width:2px,color:#fff
    classDef coreAbstraction fill:#7c4dbd,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef keyModule fill:#9b72d0,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef clientLayer fill:#b89ce0,stroke:#4e2a8e,stroke-width:2px,color:#24292e
    classDef serviceLayer fill:#d4c5ec,stroke:#4e2a8e,stroke-width:1px,color:#24292e
    classDef externalSystem fill:#f5f5f5,stroke:#666,stroke-width:1px,color:#24292e
    classDef adapter fill:#fdfbf7,stroke:#4e2a8e,stroke-width:2px,color:#24292e

    class Signal clientLayer
    class Serializer coreAbstraction
    class JsonSerializer adapter
    class ErlangTermSerializer adapter
    class MsgpackSerializer adapter
    class TypeProvider serviceLayer
    class JsonDecoder serviceLayer
```

---

### 7. Journal Causality Data Model

This Entity-Relationship Diagram (ERD) illustrates the data model managed by the `Jido.Signal.Journal`. The journal's primary purpose is to track the causal relationships between signals, forming a directed acyclic graph of events.

**Key Observations from the Code:**

*   The core entity is the **Signal**.
*   The relationship `causes/is caused by` is a **recursive one-to-many relationship** on the Signal entity. A single signal (`cause`) can trigger multiple subsequent signals (`effects`). Each `effect` has at most one direct `cause`. This is implemented in the code via `put_cause`, `get_effects`, and `get_cause`.
*   A **Conversation** groups related signals. A signal's `subject` attribute conceptually links it to a conversation. The `put_conversation` and `get_conversation` functions manage this grouping.
*   The persistence adapters (`ETS`, `InMemory`) implement storage for this model.

```mermaid
erDiagram
    SIGNAL {
        string id PK
        string type
        string source
        string subject "FK to CONVERSATION (conceptual)"
        string cause_id "FK to SIGNAL (optional)"
        json data
    }

    CONVERSATION {
        string id PK "Derived from signal.subject"
    }

    SIGNAL ||--o{ SIGNAL : "causes"
    note on SIGNAL "A 'cause' can have many 'effects'."

    CONVERSATION ||--|{ SIGNAL : "groups"
    note on CONVERSATION "A conversation contains many signals."

```

---

### 8. Custom Signal Definition via Metaprogramming

This diagram explains the metaprogramming pattern used to define custom signal types. The `use Jido.Signal` macro acts as a code generator, injecting factory functions and configuration into a custom module, which then produces standardized `Jido.Signal` structs.

**Key Observations from the Code:**

*   The `Jido.Signal` module contains a `__using__` macro.
*   When a developer writes `use Jido.Signal, ...` in their own module (e.g., `MySignal`), this macro is invoked at compile time.
*   The macro defines functions like `new/2`, `new!/2`, `type/0`, and `schema/0` directly inside the `MySignal` module.
*   The options passed to `use` (like `:type` and `:schema`) are used to configure the generated functions.
*   The generated `new/2` function in `MySignal` validates its input against the provided schema and then calls `Jido.Signal.from_map` to create a standard `%Jido.Signal{}` struct, pre-filled with the configured defaults.

```mermaid
classDiagram
    direction TB

    class JidoSignal {
        <<Module with Macro>>
        # __using__(opts) : macro
        + from_map(map) : SignalStruct
    }

    class MySignal {
        <<Custom Signal Module>>
        + new(data, opts) : SignalStruct
        + new!(data, opts) : SignalStruct
        + type() : string
        + schema() : keyword
    }

    class SignalStruct {
        <<Data Struct>>
        + specversion: string
        + id: string
        + source: string
        + type: string
        + data: term
    }

    JidoSignal --o MySignal : "generates code via `use` macro"
    note for MySignal "Code inside this module is generated at compile-time."

    MySignal ..> SignalStruct : "creates instances of"

    %% Elixir-inspired styling
    classDef userLayer fill:#4e2a8e,stroke:#24292e,stroke-width:2px,color:#fff
    classDef coreAbstraction fill:#7c4dbd,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef keyModule fill:#9b72d0,stroke:#4e2a8e,stroke-width:2px,color:#fff
    classDef clientLayer fill:#b89ce0,stroke:#4e2a8e,stroke-width:2px,color:#24292e
    classDef serviceLayer fill:#d4c5ec,stroke:#4e2a8e,stroke-width:1px,color:#24292e
    classDef externalSystem fill:#f5f5f5,stroke:#666,stroke-width:1px,color:#24292e
    classDef adapter fill:#fdfbf7,stroke:#4e2a8e,stroke-width:2px,color:#24292e

    class JidoSignal coreAbstraction
    class MySignal clientLayer
    class SignalStruct keyModule
```
