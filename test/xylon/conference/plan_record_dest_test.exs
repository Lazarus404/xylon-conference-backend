defmodule Xylon.Conference.PlanRecordDestTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Plan, SessionHooks}
  alias Xylon.{Participant, Session}

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "attach_layout creates :record routes for published tracks" do
    sid = "rec-dest-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer} = Xylon.Conference.FakePeer.start_link()
    pub = %Participant{id: "alice", peer_ref: peer, role: :publisher}
    assert :ok = Plan.put_participant(plan_ref, pub)

    assert :ok =
             SessionHooks.publish(plan_ref, "alice", %{
               mid: "0",
               kind: :audio,
               ssrc: 1001,
               codec: "opus"
             })

    assert :ok = SessionHooks.attach_layout(plan_ref)

    routes = Plan.routes_for_inbound(plan_ref, "alice", 1001)
    assert Enum.any?(routes, fn r -> r.destination.type == :record end)
    assert Enum.any?(routes, fn r -> r.subscriber_id == SessionHooks.layout_subscriber_id() end)
  end
end
