defmodule Xylon.Conference.PlanTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.Plan
  alias Xylon.Participant

  setup do
    plan_ref = Plan.new(make_ref())
    on_exit(fn -> Plan.delete(plan_ref) end)
    %{plan_ref: plan_ref}
  end

  test "publish and subscribe builds peer routes", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 111})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")

    routes = Plan.routes_for_inbound(plan_ref, "a", 111)
    assert length(routes) == 1
    [route] = routes
    assert route.subscriber_id == "b"
    assert route.mid == "0"
    assert route.kind == :audio
    assert route.destination.type == :peer
    assert route.rewrite.out_ssrc != 111
  end

  test "trunk destinations are returned for forward", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    t = %Participant{id: "trunk1", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, t)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 222})
    assert :ok = Plan.subscribe(plan_ref, "trunk1", "a", "1", dest_type: :trunk)

    [route] = Plan.routes_for_inbound(plan_ref, "a", 222)
    assert route.subscriber_id == "trunk1"
    assert route.destination.type == :trunk
    assert route.rewrite.out_ssrc != 222
  end

  test "unsubscribe clears routes", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 333})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")
    assert :ok = Plan.unsubscribe(plan_ref, "b", "a", "0")
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 333)
  end

  test "publishers lists ids with published streams", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 1})
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 2})
    assert :ok = Plan.put_track(plan_ref, "b", %{mid: "0", kind: :audio, ssrc: 3})

    pubs = Plan.publishers(plan_ref) |> Enum.sort_by(& &1.id)

    assert pubs == [
             %{
               id: "a",
               streams: [
                 %{mid: "0", kind: :audio},
                 %{mid: "1", kind: :video}
               ]
             },
             %{id: "b", streams: [%{mid: "0", kind: :audio}]}
           ]
  end

  test "pause skips routes; resume restores same rewrite", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 444})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")

    [route] = Plan.routes_for_inbound(plan_ref, "a", 444)
    out = route.rewrite.out_ssrc
    rewrite = %{route.rewrite | last_in_seq: 10, last_out_seq: 10}
    assert :ok = Plan.put_rewrite(plan_ref, route.rewrite_key, rewrite)

    assert :ok = Plan.pause(plan_ref, "b", "a", "0")
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 444)

    assert :ok = Plan.resume(plan_ref, "b", "a", "0")
    [again] = Plan.routes_for_inbound(plan_ref, "a", 444)
    assert again.rewrite.out_ssrc == out
    assert again.rewrite.last_in_seq == 10
    assert again.rewrite.last_out_seq == 10
  end

  test "unsubscribe clears send flag with rewrite", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 555})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")
    assert :ok = Plan.pause(plan_ref, "b", "a", "0")
    assert :ok = Plan.unsubscribe(plan_ref, "b", "a", "0")
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 555)
  end

  test "switch rebinds to new publisher with fresh rewrite", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    c = %Participant{id: "c", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    Enum.each([a, b, c], &Plan.put_participant(plan_ref, &1))
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 10, codec: "opus"})
    assert :ok = Plan.put_track(plan_ref, "c", %{mid: "0", kind: :audio, ssrc: 20, codec: "opus"})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")

    [old] = Plan.routes_for_inbound(plan_ref, "a", 10)
    old_out = old.rewrite.out_ssrc

    assert :ok = Plan.switch(plan_ref, "b", "a", "c", "0")
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 10)
    [neu] = Plan.routes_for_inbound(plan_ref, "c", 20)
    assert neu.rewrite.out_ssrc != old_out
    assert {:ok, "c"} = Plan.subscribed_publisher(plan_ref, "b", "0")
  end

  test "switch rejects codec mismatch", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    c = %Participant{id: "c", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    Enum.each([a, b, c], &Plan.put_participant(plan_ref, &1))
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 1, codec: "VP8"})
    assert :ok = Plan.put_track(plan_ref, "c", %{mid: "1", kind: :video, ssrc: 2, codec: "H264"})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")
    assert {:error, :codec_mismatch} = Plan.switch(plan_ref, "b", "a", "c", "1")
  end

  test "set_send_for_publisher pauses all subscribers", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    c = %Participant{id: "c", peer_ref: self()}
    Enum.each([a, b, c], &Plan.put_participant(plan_ref, &1))
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 9})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")
    assert :ok = Plan.subscribe(plan_ref, "c", "a", "0")
    assert :ok = Plan.set_send_for_publisher(plan_ref, "a", ["0"], false)
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 9)
    assert :ok = Plan.set_send_for_publisher(plan_ref, "a", ["0"], true)
    assert length(Plan.routes_for_inbound(plan_ref, "a", 9)) == 2
  end

  test "delete_track removes publisher routes but keeps participant and other mids", %{
    plan_ref: plan_ref
  } do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 11})
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 22})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 22)

    assert :ok = Plan.delete_track(plan_ref, "a", "1")
    assert is_nil(Plan.get_track(plan_ref, "a", "1"))
    assert %{ssrc: 11} = Plan.get_track(plan_ref, "a", "0")
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 22)
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 11)
    assert %Participant{id: "a"} = Plan.get_participant(plan_ref, "a")

    # Idempotent
    assert :ok = Plan.delete_track(plan_ref, "a", "1")
  end

  test "subscribe substream selects layer ssrc", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1}
               ]
             })

    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1", substream: 1)
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 100)
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 200)

    assert :ok = Plan.set_substream(plan_ref, "b", "a", "1", substream: 0)
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 100)
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 200)
  end

  test "subscribe by rid selects matching layer", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               layers: [
                 %{ssrc: 100, substream: 0, rid: "q"},
                 %{ssrc: 200, substream: 1, rid: "h"}
               ]
             })

    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1", rid: "h")
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 200)
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 100)
  end

  test "re-subscribe with new substream keeps out_ssrc; resets rewrite counters", %{
    plan_ref: plan_ref
  } do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1}
               ]
             })

    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1", substream: 0)
    [%{rewrite: %{out_ssrc: out0}}] = Plan.routes_for_inbound(plan_ref, "a", 100)

    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1", substream: 0)
    [%{rewrite: %{out_ssrc: ^out0}}] = Plan.routes_for_inbound(plan_ref, "a", 100)

    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1", substream: 1)
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 100)
    [%{rewrite: %{out_ssrc: out1, last_in_seq: nil, last_out_seq: nil}}] =
      Plan.routes_for_inbound(plan_ref, "a", 200)

    assert out1 == out0
  end

  test "find_track_by_kind returns first matching track", %{plan_ref: plan_ref} do
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 1})
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 2})
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "2", kind: :video, ssrc: 3})

    assert %{mid: "0", kind: :audio} = Plan.find_track_by_kind(plan_ref, "a", :audio)
    assert %{mid: "1", kind: :video} = Plan.find_track_by_kind(plan_ref, "a", :video)
    assert is_nil(Plan.find_track_by_kind(plan_ref, "z", :audio))
  end

  test "bind_track_ssrc updates unbound track and subscriber layer", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 0})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 0)
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 4242)

    assert :ok = Plan.bind_track_ssrc(plan_ref, "a", "1", 4242)
    assert %{ssrc: 4242} = Plan.get_track(plan_ref, "a", "1")
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 4242)
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 0)
  end

  test "learn_layer_ssrc binds RID layers; set_substream rid before learn is no_layer", %{
    plan_ref: plan_ref
  } do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 0,
               layers: [
                 %{ssrc: 0, substream: 0, rid: "q"},
                 %{ssrc: 0, substream: 1, rid: "h"}
               ]
             })

    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")
    assert {:error, :no_layer} = Plan.set_substream(plan_ref, "b", "a", "1", rid: "h")

    assert :ok = Plan.learn_layer_ssrc(plan_ref, "a", "1", "q", 100)
    assert %{ssrc: 100, layers: layers} = Plan.get_track(plan_ref, "a", "1")
    assert Enum.find(layers, &(&1.rid == "q")).ssrc == 100
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 100)

    assert {:error, :no_layer} = Plan.set_substream(plan_ref, "b", "a", "1", rid: "h")
    assert :ok = Plan.learn_layer_ssrc(plan_ref, "a", "1", "h", 200)
    assert :ok = Plan.set_substream(plan_ref, "b", "a", "1", rid: "h")
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 100)
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 200)

    assert {:ok, "a", "1"} = Plan.publisher_for_in_ssrc(plan_ref, 200)
  end

  test "routes_for_inbound cache survives across lookups and refreshes rewrite", %{
    plan_ref: plan_ref
  } do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 777})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")

    [r1] = Plan.routes_for_inbound(plan_ref, "a", 777)
    [r2] = Plan.routes_for_inbound(plan_ref, "a", 777)
    assert r1.subscriber_id == r2.subscriber_id
    assert r1.rewrite.out_ssrc == r2.rewrite.out_ssrc

    updated = %{r1.rewrite | last_in_seq: 42, last_out_seq: 42}
    assert :ok = Plan.put_rewrite(plan_ref, r1.rewrite_key, updated)
    [r3] = Plan.routes_for_inbound(plan_ref, "a", 777)
    assert r3.rewrite.last_in_seq == 42
  end

  test "routes_for_inbound cache invalidates on unsubscribe", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 778})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 778)
    assert :ok = Plan.unsubscribe(plan_ref, "b", "a", "0")
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 778)
  end

  test "routes_for_inbound cache invalidates on pause", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 779})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 779)
    assert :ok = Plan.pause(plan_ref, "b", "a", "0")
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 779)
  end

  test "routes_for_inbound cache invalidates on set_send false", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 782})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 782)
    assert :ok = Plan.set_send(plan_ref, "b", "a", "0", false)
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 782)
    assert :ok = Plan.set_send(plan_ref, "b", "a", "0", true)
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 782)
  end

  test "put_rewrites updates multiple rewrite keys", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    c = %Participant{id: "c", peer_ref: self()}
    Enum.each([a, b, c], &Plan.put_participant(plan_ref, &1))
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 780})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")
    assert :ok = Plan.subscribe(plan_ref, "c", "a", "0")

    routes = Plan.routes_for_inbound(plan_ref, "a", 780)
    assert length(routes) == 2

    pairs =
      Enum.map(routes, fn r ->
        {r.rewrite_key, %{r.rewrite | last_in_seq: 99, last_out_seq: 99}}
      end)

    assert :ok = Plan.put_rewrites(plan_ref, pairs)

    Enum.each(Plan.routes_for_inbound(plan_ref, "a", 780), fn r ->
      assert r.rewrite.last_in_seq == 99
      assert r.rewrite.last_out_seq == 99
    end)
  end

  test "put_participant with new peer_ref invalidates subscriber dest cache", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: self()}
    b1 = %Participant{id: "b", peer_ref: self()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b1)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 781})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "0")

    [r1] = Plan.routes_for_inbound(plan_ref, "a", 781)
    assert r1.destination.participant.peer_ref == self()

    new_peer = spawn(fn -> :timer.sleep(:infinity) end)
    on_exit(fn -> Process.exit(new_peer, :kill) end)

    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "b", peer_ref: new_peer})
    [r2] = Plan.routes_for_inbound(plan_ref, "a", 781)
    assert r2.destination.participant.peer_ref == new_peer
  end
end
