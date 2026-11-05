defmodule Xylon.Conference.DynacastTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Dynacast, Plan, Runtime, SessionHooks}
  alias Xylon.{Participant, Session}

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "aggregate max SIM substream; all inactive with no subscribers" do
    plan_ref = Plan.new(make_ref())
    Runtime.ensure_table!()

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0, rid: "q"},
                 %{ssrc: 200, substream: 1, rid: "h"},
                 %{ssrc: 300, substream: 2, rid: "f"}
               ]
             })

    assert {:ok, layers} = Dynacast.aggregate(plan_ref, "a", "1")

    assert layers == [
             %{"rid" => "q", "active" => false},
             %{"rid" => "h", "active" => false},
             %{"rid" => "f", "active" => false}
           ]
  end

  test "aggregate activates layers at or below max subscribed substream" do
    plan_ref = Plan.new(make_ref())
    Runtime.ensure_table!()
    a = %Participant{id: "a"}
    b = %Participant{id: "b"}
    c = %Participant{id: "c"}
    Enum.each([a, b, c], &Plan.put_participant(plan_ref, &1))

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0, rid: "q"},
                 %{ssrc: 200, substream: 1, rid: "h"},
                 %{ssrc: 300, substream: 2, rid: "f"}
               ]
             })

    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1", substream: 0)
    assert :ok = Plan.subscribe(plan_ref, "c", "a", "1", substream: 1)

    assert {:ok, layers} = Dynacast.aggregate(plan_ref, "a", "1")

    assert layers == [
             %{"rid" => "q", "active" => true},
             %{"rid" => "h", "active" => true},
             %{"rid" => "f", "active" => false}
           ]
  end

  test "aggregate skips one-SSRC SVC tracks" do
    plan_ref = Plan.new(make_ref())

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 77,
               codec: "VP9"
             })

    assert :skip = Dynacast.aggregate(plan_ref, "a", "1")
  end

  test "flush pushes publish_layers to publisher signaling_pid" do
    assert {:ok, session} =
             Session.create("t1", "dynacast-push", :conference,
               dynacast: true,
               subscribe_mode: :manual
             )

    plan_ref = Session.plan_ref(session)
    assert Runtime.dynacast?(plan_ref)

    assert {:ok, peer_a} = Xylon.Conference.FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a, meta: %{signaling_pid: self()}}
    b = %Participant{id: "b"}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0, rid: "q"},
                 %{ssrc: 200, substream: 1, rid: "h"},
                 %{ssrc: 300, substream: 2, rid: "f"}
               ]
             })

    assert :ok = SessionHooks.subscribe(plan_ref, "b", "a", "1", rid: "q")
    assert :ok = Dynacast.flush(plan_ref, "a", "1")

    assert_receive {:xylon_control_publish_layers,
                    %{
                      mid: "1",
                      layers: [
                        %{"rid" => "q", "active" => true},
                        %{"rid" => "h", "active" => false},
                        %{"rid" => "f", "active" => false}
                      ]
                    }},
                   200
  end

  test "WS handler encodes publish_layers frame" do
    state = %{}

    assert {:push, {:text, json}, ^state} =
             Xylon.Signaling.WSHandler.handle_info(
               {:xylon_control_publish_layers,
                %{
                  mid: "1",
                  layers: [%{"rid" => "q", "active" => true}]
                }},
               state
             )

    assert Jason.decode!(json) == %{
             "type" => "publish_layers",
             "mid" => "1",
             "layers" => [%{"rid" => "q", "active" => true}]
           }
  end
end
