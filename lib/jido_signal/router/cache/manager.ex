defmodule Jido.Signal.Router.Cache.Manager do
  @moduledoc false

  use GenServer

  @name __MODULE__

  @type cache_id :: atom() | {atom(), term()}

  @spec register(cache_id(), pid()) :: :ok
  def register(cache_id, owner_pid)
      when (is_atom(cache_id) or is_tuple(cache_id)) and is_pid(owner_pid) do
    with {:ok, _pid} <- ensure_started() do
      GenServer.call(@name, {:register, cache_id, owner_pid})
    end
  end

  @spec unregister(cache_id()) :: :ok
  def unregister(cache_id) when is_atom(cache_id) or is_tuple(cache_id) do
    case Process.whereis(@name) do
      nil -> :ok
      _pid -> GenServer.call(@name, {:unregister, cache_id})
    end
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{cache_to_ref: %{}, ref_to_cache_ids: %{}}}
  end

  @impl GenServer
  def handle_call({:register, cache_id, owner_pid}, _from, state) do
    state = unregister_cache_id(cache_id, state)
    ref = Process.monitor(owner_pid)
    cache_to_ref = Map.put(state.cache_to_ref, cache_id, ref)

    ref_to_cache_ids =
      Map.update(state.ref_to_cache_ids, ref, MapSet.new([cache_id]), &MapSet.put(&1, cache_id))

    {:reply, :ok, %{state | cache_to_ref: cache_to_ref, ref_to_cache_ids: ref_to_cache_ids}}
  end

  @impl GenServer
  def handle_call({:unregister, cache_id}, _from, state) do
    {:reply, :ok, unregister_cache_id(cache_id, state)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cache_ids = Map.get(state.ref_to_cache_ids, ref, MapSet.new())

    Enum.each(cache_ids, fn cache_id ->
      _ = :persistent_term.erase(cache_key(cache_id))
    end)

    cache_to_ref =
      Enum.reduce(cache_ids, state.cache_to_ref, fn cache_id, acc ->
        Map.delete(acc, cache_id)
      end)

    ref_to_cache_ids = Map.delete(state.ref_to_cache_ids, ref)
    {:noreply, %{state | cache_to_ref: cache_to_ref, ref_to_cache_ids: ref_to_cache_ids}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case GenServer.start_link(__MODULE__, :ok, name: @name) do
          {:ok, pid} ->
            Process.unlink(pid)
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          error ->
            error
        end

      pid ->
        {:ok, pid}
    end
  end

  defp unregister_cache_id(cache_id, state) do
    case Map.pop(state.cache_to_ref, cache_id) do
      {nil, _cache_to_ref} ->
        state

      {ref, cache_to_ref} ->
        remaining =
          state.ref_to_cache_ids
          |> Map.get(ref, MapSet.new())
          |> MapSet.delete(cache_id)

        ref_to_cache_ids =
          if MapSet.size(remaining) == 0 do
            Process.demonitor(ref, [:flush])
            Map.delete(state.ref_to_cache_ids, ref)
          else
            Map.put(state.ref_to_cache_ids, ref, remaining)
          end

        %{state | cache_to_ref: cache_to_ref, ref_to_cache_ids: ref_to_cache_ids}
    end
  end

  defp cache_key(cache_id), do: {:jido_signal_router_cache, cache_id}
end
