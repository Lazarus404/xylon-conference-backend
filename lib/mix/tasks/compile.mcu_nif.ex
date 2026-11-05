defmodule Mix.Tasks.Compile.McuNif do
  @moduledoc false
  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    project = File.cwd!()
    makefile = Path.join(project, "Makefile")
    src = Path.join(project, "c_src/mcu_mix_nif.c")
    so = Path.join(project, "priv/mcu_mix_nif.so")

    # Mix may hardlink project priv/ into _build priv/ (same inode). Never
    # File.cp between those paths -- that truncates the shared file to 0 bytes.
    if File.exists?(so) and match?(%{size: 0}, File.stat!(so)) do
      _ = File.rm(so)
    end

    if File.exists?(makefile) and File.exists?(src) do
      case System.cmd("make", [], cd: project, stderr_to_stdout: true) do
        {out, 0} ->
          if String.trim(out) != "", do: IO.write(out)
          {:ok, []}

        {out, status} ->
          IO.write(out)

          Mix.shell().error(
            "mcu_mix_nif make failed (#{status}); Elixir mix path remains available"
          )

          {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  @impl true
  def clean do
    project = File.cwd!()

    if File.exists?(Path.join(project, "Makefile")) do
      _ = System.cmd("make", ["clean"], cd: project, stderr_to_stdout: true)
    end

    :ok
  end
end
