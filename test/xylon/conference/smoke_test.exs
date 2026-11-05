defmodule Xylon.Conference.SmokeTest do
  use ExUnit.Case, async: false

  alias Xylon.Session

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "attach and create conference session" do
    assert Xylon.attached?(:conference)
    assert {:ok, session} = Session.create("t1", "conf-smoke", :conference)
    assert is_pid(Session.forwarder(session))
    assert Session.plan_ref(session) == session
  end

  test "mcu audio with video sfu creates session" do
    assert {:ok, session} =
             Session.create("t1", "conf-mcu", :conference, audio: :mcu, video: :sfu)

    assert is_pid(session)
  end
end
