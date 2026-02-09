defmodule JidoTest.Signal.Bus.LifecycleStabilityTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.Partition
  alias Jido.Signal.Bus.PartitionSupervisor
  alias Jido.Signal.Bus.Snapshot
  alias Jido.Signal.Router
  alias Jido.Signal.Router.Cache

  @moduletag :capture_log

  defp wait_until(fun, attempts \\ 80)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp drain_signal_messages do
    receive do
      {:signal, _signal} -> drain_signal_messages()
    after
      0 -> :ok
    end
  end

  test "GenServer.stop/1 tears down internal supervisors and partition workers" do
    bus_name = :"test_bus_stop_#{System.unique_integer([:positive, :monotonic])}"
    {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2)

    state = :sys.get_state(bus_pid)
    child_supervisor_pid = state.child_supervisor
    partition_supervisor_pid = GenServer.whereis(PartitionSupervisor.via_tuple(bus_name))

    partition_pids =
      0..1
      |> Enum.map(fn partition_id ->
        GenServer.whereis(Partition.via_tuple(bus_name, partition_id))
      end)
      |> Enum.reject(&is_nil/1)

    :ok = GenServer.stop(bus_pid)

    assert wait_until(fn -> not Process.alive?(child_supervisor_pid) end)

    assert wait_until(fn ->
             is_nil(partition_supervisor_pid) or not Process.alive?(partition_supervisor_pid)
           end)

    Enum.each(partition_pids, fn partition_pid ->
      assert wait_until(fn -> not Process.alive?(partition_pid) end)
    end)
  end

  test "bus stop cleans snapshot and router cache entries" do
    bus_name = :"test_bus_snapshot_cleanup_#{System.unique_integer([:positive, :monotonic])}"
    cache_id = {:bus_router_cache, bus_name}

    router = Router.new!([{"test.lifecycle.snapshot", :handler}], cache_id: cache_id)
    assert Cache.cached?(cache_id)

    {:ok, bus_pid} = Bus.start_link(name: bus_name, router: router)

    {:ok, signal} =
      Signal.new(%{
        type: "test.lifecycle.snapshot",
        source: "/test",
        data: %{value: 1}
      })

    {:ok, _recorded} = Bus.publish(bus_name, [signal])
    {:ok, snapshot_ref} = Bus.snapshot_create(bus_name, "**")

    snapshot_key = {Snapshot, snapshot_ref.id}
    refute :persistent_term.get(snapshot_key, :not_found) == :not_found

    :ok = Bus.stop(bus_pid)

    assert :persistent_term.get(snapshot_key, :not_found) == :not_found
    refute Cache.cached?(cache_id)
  end

  test "bus restarts under supervision and remains responsive after crash" do
    bus_name = :"test_bus_restart_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Bus, name: bus_name, partition_count: 2})

    {:ok, _sub_regular} =
      Bus.subscribe(bus_name, "test.restart", dispatch: {:pid, target: self()})

    {:ok, _sub_persistent} =
      Bus.subscribe(bus_name, "test.restart", persistent?: true, dispatch: {:pid, target: self()})

    {:ok, pre_restart_signal} =
      Signal.new(%{
        type: "test.restart",
        source: "/test",
        data: %{phase: :before_restart}
      })

    {:ok, _} = Bus.publish(bus_name, [pre_restart_signal])
    assert_receive {:signal, %Signal{type: "test.restart"}}, 1_000
    drain_signal_messages()

    {:ok, old_bus_pid} = Bus.whereis(bus_name)
    old_state = :sys.get_state(old_bus_pid)
    old_child_supervisor_pid = old_state.child_supervisor

    Process.exit(old_bus_pid, :kill)

    assert wait_until(fn ->
             case Bus.whereis(bus_name) do
               {:ok, new_pid} -> new_pid != old_bus_pid and Process.alive?(new_pid)
               {:error, _reason} -> false
             end
           end)

    assert wait_until(fn -> not Process.alive?(old_child_supervisor_pid) end)

    {:ok, post_restart_signal} =
      Signal.new(%{
        type: "test.restart",
        source: "/test",
        data: %{phase: :after_restart}
      })

    {:ok, _} = Bus.publish(bus_name, [post_restart_signal])
    refute_receive {:signal, %Signal{type: "test.restart", data: %{phase: :after_restart}}}, 250

    {:ok, _sub_after_restart} =
      Bus.subscribe(bus_name, "test.restart", dispatch: {:pid, target: self()})

    {:ok, final_signal} =
      Signal.new(%{
        type: "test.restart",
        source: "/test",
        data: %{phase: :recovered}
      })

    {:ok, _} = Bus.publish(bus_name, [final_signal])
    assert_receive {:signal, %Signal{type: "test.restart", data: %{phase: :recovered}}}, 1_000
  end

  test "concurrent publish order matches serialized dispatch order" do
    bus_name = :"test_bus_ordering_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Bus, name: bus_name})

    {:ok, _subscription} =
      Bus.subscribe(bus_name, "test.concurrent.order", dispatch: {:pid, target: self()})

    handler_id = "bus-ordering-#{System.unique_integer([:positive, :monotonic])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:jido, :signal, :bus, :after_dispatch],
      fn _event, _measurements, metadata, _config ->
        if metadata.bus_name == bus_name and metadata.signal.type == "test.concurrent.order" do
          send(test_pid, {:serialized_seq, metadata.signal.data.seq})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    tasks =
      Enum.map(1..8, fn seq ->
        Task.async(fn ->
          {:ok, signal} =
            Signal.new(%{
              type: "test.concurrent.order",
              source: "/test",
              data: %{seq: seq}
            })

          Bus.publish(bus_name, [signal])
        end)
      end)

    Enum.each(tasks, fn task ->
      assert {:ok, [_recorded_signal]} = Task.await(task, 5_000)
    end)

    delivered_order =
      Enum.map(1..8, fn _ ->
        receive do
          {:signal, %Signal{type: "test.concurrent.order", data: %{seq: seq}}} -> seq
        after
          2_000 -> flunk("did not receive all concurrently published signals")
        end
      end)

    serialized_order =
      Enum.map(1..8, fn _ ->
        receive do
          {:serialized_seq, seq} -> seq
        after
          2_000 -> flunk("did not receive all serialization telemetry events")
        end
      end)

    assert delivered_order == serialized_order
  end
end
