defmodule Xylon.Conference.RecordingViaTrunkTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{FakePeer, Plan}
  alias Xylon.{Forwarder, Participant, Session}
  alias Xylon.Recording.Ctx
  alias XMediaLib.Rtp

  defmodule CaptureViaHandler do
    @behaviour Xylon.Recording.Handler

    @impl true
    def on_start(%Ctx{}, _opts), do: {:ok, %{vias: []}}

    @impl true
    def on_stop(%Ctx{}, state), do: {:ok, %{artifacts: [], counters: %{}, vias: state.vias}}

    @impl true
    def on_publisher_rtp(%Ctx{}, state, meta, _rtp) do
      via = Map.get(meta, :via) || Map.get(meta, "via")
      {:ok, %{state | vias: [via | state.vias]}}
    end

    @impl true
    def on_mix_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok = Xylon.Recording.Registry.ensure_table!()

    Application.put_env(:xylon, :recording, handler: CaptureViaHandler)

    on_exit(fn ->
      Application.delete_env(:xylon, :recording)
    end)

    :ok
  end

  test "trunk-remote publisher meta includes via trunk" do
    sid = "via-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer} = FakePeer.start_link()

    remote = %Participant{
      id: "remote-bob",
      peer_ref: peer,
      role: :publisher,
      meta: %{remote: true}
    }

    assert :ok = Plan.put_participant(plan_ref, remote)
    assert :ok = Forwarder.put_plan(fwd, peer, %{mode: :sfu, participant: remote})

    assert :ok =
             Xylon.Conference.publish(plan_ref, "remote-bob", %{
               mid: "0",
               kind: :audio,
               ssrc: 9001,
               codec: "opus"
             })

    assert {:ok, _} = Session.start_recording(session)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 9001,
      csrcs: [],
      extension: nil,
      payload: <<1, 2, 3>>
    }

    send(fwd, {:xgw, :rtp, peer, rtp, %{}})
    Process.sleep(30)

    {_mod, _ctx, handler_state} = Xylon.Recording.Registry.get(session)
    assert "trunk" in handler_state.vias

    assert {:ok, _} = Session.stop_recording(session)
  end
end
