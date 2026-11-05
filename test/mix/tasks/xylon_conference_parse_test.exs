defmodule Mix.Tasks.Xylon.ConferenceParseTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Xylon.Conference

  test "parse_args defaults audio to sfu" do
    assert {:ok, opts} = Conference.parse_args(["--http-port", "8080"])
    assert opts[:audio] == :sfu
    assert opts[:http_port] == 8080
  end

  test "parse_args accepts --audio mcu" do
    assert {:ok, opts} = Conference.parse_args(["--audio", "mcu"])
    assert opts[:audio] == :mcu
  end

  test "parse_args rejects unknown --audio" do
    assert {:error, {:invalid_audio, "mesh"}} = Conference.parse_args(["--audio", "mesh"])
  end

  test "cluster_lab_config nil without env" do
    clear_cluster_env()
    assert Conference.cluster_lab_config() == nil
  end

  test "cluster_lab_config from XYLON_CLUSTER and region" do
    clear_cluster_env()
    System.put_env("XYLON_CLUSTER", "1")
    System.put_env("XYLON_REGION_ID", "us-west-2")
    System.put_env("XYLON_HUB_PRIORITY", "3")
    System.put_env("XYLON_EDGE_URLS", ~s({"us-west-2":"http://127.0.0.1:8080"}))

    on_exit(&clear_cluster_env/0)

    cfg = Conference.cluster_lab_config()
    assert cfg[:enabled] == true
    assert cfg[:region_id] == "us-west-2"
    assert cfg[:hub_priority] == 3
    assert cfg[:edge_urls]["us-west-2"] == "http://127.0.0.1:8080"
  end

  defp clear_cluster_env do
    Enum.each(
      ~w(XYLON_CLUSTER XYLON_REGION_ID XYLON_HUB_PRIORITY XYLON_EDGE_URLS XYLON_TRUNK_KEY_AB XYLON_TRUNK_SALT_AB XYLON_TRUNK_KEY_BA XYLON_TRUNK_SALT_BA),
      &System.delete_env/1
    )
  end
end
