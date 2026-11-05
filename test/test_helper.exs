# Best-effort: build dirty-CPU mix NIF when a C toolchain is present.
_ =
  System.cmd("make", [],
    cd: Path.expand("..", __DIR__),
    stderr_to_stdout: true
  )

ExUnit.start(exclude: [:dual_node, :cluster])

Application.put_env(:xylon, :ice, advertised_ip: {127, 0, 0, 1})
