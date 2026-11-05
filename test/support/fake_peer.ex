defmodule Xylon.Conference.FakePeer do
  @moduledoc false
  use GenServer

  def start_link, do: GenServer.start_link(__MODULE__, [])

  def drain(pid), do: GenServer.call(pid, :drain)

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_call({:send_rtp, ssrc, packet}, _from, state) do
    {:reply, :ok, [{:send_rtp, ssrc, packet} | state]}
  end

  def handle_call({:send_rtcp, packet}, _from, state) do
    {:reply, :ok, [{:send_rtcp, packet} | state]}
  end

  def handle_call(:drain, _from, state) do
    {:reply, Enum.reverse(state), []}
  end

  def handle_call(:close, _from, state) do
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast({:send_rtp, ssrc, packet}, state) do
    {:noreply, [{:send_rtp, ssrc, packet} | state]}
  end
end
