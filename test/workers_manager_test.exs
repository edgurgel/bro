defmodule Verk.WorkersManagerTest do
  use ExUnit.Case
  import :meck
  import Verk.WorkersManager
  alias Verk.WorkersManager.State

  defmodule TestHandler do
    use GenEvent

    def init(pid), do: {:ok, pid}
    def handle_event(event, pid) do
      send pid, event
      {:ok, pid}
    end
  end

  setup_all do
    { :ok, pid } = GenEvent.start(name: Verk.EventManager)
    on_exit fn -> GenEvent.stop(pid) end
    :ok
  end

  setup do
    pid = self
    new :poolboy
    on_exit fn ->
      GenEvent.remove_handler(Verk.EventManager, TestHandler, pid)
      unload
    end
    GenEvent.add_mon_handler(Verk.EventManager, TestHandler, pid)
    table = :ets.new(:"queue_name.workers_manager", [:named_table, read_concurrency: true])
    { :ok, monitors: table }
  end

  test "name returns workers manager name" do
    assert name("queue_name") == :"queue_name.workers_manager"
    assert name(:queue_name) == :"queue_name.workers_manager"
  end

  test "list running jobs with jobs to list", %{ monitors: monitors } do
    row = { self, "job_id", "job", make_ref, "start_time" }
    :ets.insert(monitors, row)

    assert running_jobs("queue_name") == [%{ process: self, job: "job", started_at: "start_time" }]
  end

  test "list running jobs with a limit", %{ monitors: monitors } do
    row1 = { self, "job_id", "job", make_ref, "start_time" }
    row2 = { self, "job_id2", "job2", make_ref, "start_time2" }
    :ets.insert(monitors, [row2, row1])

    assert running_jobs("queue_name", 1) == [%{ process: self, job: "job", started_at: "start_time" }]
  end

  test "list running jobs with no jobs" do
    assert running_jobs("queue_name") == []
  end

  test "inspect_worker with no matching job_id" do
    assert inspect_worker("queue_name", "job_id") == { :error, :not_found }
  end

  test "inspect_worker with matching job_id", %{ monitors: monitors } do
    row = { self, "job_id", "job data", make_ref, "start_time" }
    :ets.insert(monitors, row)

    { :ok, result } = inspect_worker("queue_name", "job_id")

    assert result[:job] == "job data"
    assert result[:process] == self
    assert result[:started_at] == "start_time"

    expected = [:current_stacktrace, :initial_call, :reductions, :status]
    assert Enum.all?(expected, &Keyword.has_key?(result[:info], &1))
  end

  test "inspect_worker with matching job_id but process is gone", %{ monitors: monitors } do
    pid = :erlang.list_to_pid('<3.57.1>')
    row = { pid, "job_id", "job data", make_ref, "start_time" }
    :ets.insert(monitors, row)

    assert inspect_worker("queue_name", "job_id") == { :error, :not_found }
  end

  test "init" do
    name = :workers_manager
    queue_name = "queue_name"
    queue_manager_name = "queue_manager_name"
    pool_name = "pool_name"
    pool_size = "size"
    timeout = Application.get_env(:verk, :workers_manager_timeout)
    state = %State{ queue_name: queue_name, queue_manager_name: queue_manager_name,
                    pool_name: pool_name, pool_size: pool_size,
                    monitors: :workers_manager, timeout: timeout }
    expect(Verk.QueueStats, :reset_started, [queue_name], :ok)

    assert init([name, queue_name, queue_manager_name, pool_name, pool_size])
      == { :ok, state }

    assert_received :enqueue_inprogress
    assert validate Verk.QueueStats
  end

  test "handle info enqueue_inprogress" do
    queue_manager_name = "queue_manager_name"
    state = %State{ queue_manager_name: queue_manager_name }

    expect(Verk.QueueManager, :enqueue_inprogress, [queue_manager_name], :ok)

    assert handle_info(:enqueue_inprogress, state) == { :noreply, state, 0 }

    assert validate Verk.QueueManager
  end

  test "handle info timeout with no free workers", %{ monitors: monitors } do
    new Verk.QueueManager
    state = %State{ monitors: monitors, pool_name: "pool_name", pool_size: 1 }

    row = { self, "job_id", "job", make_ref, "start_time" }
    :ets.insert(monitors, row)

    assert handle_info(:timeout, state) == { :noreply, state }

    assert validate Verk.QueueManager
  end

  test "handle info timeout with free workers and no jobs", %{ monitors: monitors } do
    queue_manager_name = :queue_manager_name
    timeout = 1000
    state = %State{ monitors: monitors, pool_name: "pool_name",
                    pool_size: 1, queue_manager_name: queue_manager_name, timeout: timeout }

    expect(Verk.QueueManager, :dequeue, [queue_manager_name, 1], [])

    assert handle_info(:timeout, state) == { :noreply, state, state.timeout }

    assert validate Verk.QueueManager
  end

  test "handle info timeout with free workers and jobs to be done", %{ monitors: monitors } do
    queue_manager_name = :queue_manager_name
    pool_name = :pool_name
    timeout = 1000
    worker = self
    module = :module
    args = [:arg1, :arg2]
    job_id = "job_id"
    state = %State{ monitors: monitors, pool_name: pool_name,
                    pool_size: 1, queue_manager_name: queue_manager_name, timeout: timeout }
    job = %Verk.Job{ class: module, args: args, jid: job_id }

    expect(Verk.QueueManager, :dequeue, [queue_manager_name, 1], [:encoded_job])
    expect(Verk.Job, :decode!, [:encoded_job], job)
    expect(:poolboy, :checkout, [pool_name, false], worker)
    expect(Verk.Worker, :perform_async, [worker, worker, job], :ok)

    assert handle_info(:timeout, state) == { :noreply, state, state.timeout }
    assert match?([{^worker, ^job_id, ^job, _, _}], :ets.lookup(monitors, worker))
    assert_receive %Verk.Events.JobStarted{ job: ^job, started_at: _ }

    assert validate [Verk.QueueManager, :poolboy, Verk.Worker]
  end

  test "cast done having the worker registered", %{ monitors: monitors } do
    queue_manager_name = "queue_manager_name"
    pool_name = "pool_name"
    state = %State{ monitors: monitors, pool_name: pool_name, queue_manager_name: queue_manager_name }
    worker = self
    job = %Verk.Job{}
    job_id = "job_id"

    expect(Verk.QueueManager, :ack, [queue_manager_name, job], :ok)

    :ets.insert(monitors, { worker, job_id, job, make_ref, Timex.DateTime.now })
    assert handle_cast({ :done, worker, job_id }, state) == { :noreply, state, 0 }

    assert :ets.lookup(state.monitors, worker) == []
    assert_receive %Verk.Events.JobFinished{ job: ^job, finished_at: _ }

    assert validate [:poolboy, Verk.QueueManager]
  end

  test "handle info DOWN coming from dead worker with reason and stacktrace", %{ monitors: monitors } do
    ref = make_ref
    worker = self
    pool_name = "pool_name"
    job = "job"
    queue_manager_name = "queue_manager_name"
    reason = :reason
    exception = RuntimeError.exception(inspect(reason))

    :ets.insert(monitors, { worker, "job_id", job, ref, "start_time" })

    state = %State{ monitors: monitors, pool_name: pool_name, queue_manager_name: queue_manager_name }

    expect(Verk.Log, :fail, [job, "start_time", worker], :ok)
    expect(Verk.QueueManager, :retry, [queue_manager_name, job, exception, :stacktrace], :ok)
    expect(Verk.QueueManager, :ack, [queue_manager_name, job], :ok)

    assert handle_info({ :DOWN, ref, :_, worker, { reason, :stacktrace } }, state) == { :noreply, state, 0 }

    assert :ets.lookup(monitors, worker) == []
    assert_receive %Verk.Events.JobFailed{ job: ^job, failed_at: _,
                                           stacktrace: :stacktrace,
                                           exception: ^exception }

    assert validate [:poolboy, Verk.Log, Verk.QueueManager]
  end

  test "handle info DOWN coming from dead worker with reason and no stacktrace", %{ monitors: monitors } do
    ref = make_ref
    worker = self
    pool_name = "pool_name"
    job = "job"
    queue_manager_name = "queue_manager_name"
    reason = :reason
    exception = RuntimeError.exception(inspect(reason))

    :ets.insert(monitors, { worker, "job_id", job, ref, "start_time" })

    state = %State{ monitors: monitors, pool_name: pool_name, queue_manager_name: queue_manager_name }

    expect(Verk.Log, :fail, [job, "start_time", worker], :ok)
    expect(Verk.QueueManager, :retry, [queue_manager_name, job, exception, []], :ok)
    expect(Verk.QueueManager, :ack, [queue_manager_name, job], :ok)

    assert handle_info({ :DOWN, ref, :_, worker, reason }, state) == { :noreply, state, 0 }

    assert :ets.lookup(monitors, worker) == []
    assert_receive %Verk.Events.JobFailed{ job: ^job, failed_at: _,
                                           stacktrace: [],
                                           exception: ^exception }

    assert validate [:poolboy, Verk.Log, Verk.QueueManager]
  end

  test "handle info DOWN coming from dead worker with normal reason", %{ monitors: monitors } do
    queue_manager_name = "queue_manager_name"
    pool_name = "pool_name"
    state = %State{ monitors: monitors, pool_name: pool_name, queue_manager_name: queue_manager_name }
    worker = self
    job = %Verk.Job{}
    job_id = "job_id"
    ref = make_ref

    expect(Verk.QueueManager, :ack, [queue_manager_name, job], :ok)

    :ets.insert(monitors, { worker, job_id, job, ref, Timex.DateTime.now })
    assert handle_info({ :DOWN, ref, :_, worker, :normal }, state) == { :noreply, state, 0 }

    assert :ets.lookup(state.monitors, worker) == []
    assert_receive %Verk.Events.JobFinished{ job: ^job, finished_at: _ }

    assert validate Verk.QueueManager
  end

  test "handle info DOWN coming from dead worker with failed reason", %{ monitors: monitors } do
    ref = make_ref
    worker = self
    pool_name = "pool_name"
    job = "job"
    job_id = "job_id"
    queue_manager_name = "queue_manager_name"
    exception = RuntimeError.exception(":failed")

    :ets.insert(monitors, { worker, job_id, job, ref, "start_time" })

    state = %State{ monitors: monitors, pool_name: pool_name, queue_manager_name: queue_manager_name }

    expect(Verk.Log, :fail, [job, "start_time", worker], :ok)
    expect(Verk.QueueManager, :retry, [queue_manager_name, job, exception, []], :ok)
    expect(Verk.QueueManager, :ack, [queue_manager_name, job], :ok)

    assert handle_info({ :DOWN, ref, :_, worker, :failed }, state) == { :noreply, state, 0 }

    assert :ets.lookup(monitors, worker) == []
    assert_receive %Verk.Events.JobFailed{ job: ^job, failed_at: _,
                                           stacktrace: [],
                                           exception: ^exception }

    assert validate [Verk.Log, Verk.QueueManager]
  end

  test "cast failed coming from worker", %{ monitors: monitors } do
    ref = make_ref
    worker = self
    pool_name = "pool_name"
    job = "job"
    job_id = "job_id"
    queue_manager_name = "queue_manager_name"
    exception = RuntimeError.exception("reasons")

    :ets.insert(monitors, { worker, job_id, job, ref, "start_time" })

    state = %State{ monitors: monitors, pool_name: pool_name, queue_manager_name: queue_manager_name }

    expect(Verk.Log, :fail, [job, "start_time", worker], :ok)
    expect(Verk.QueueManager, :retry, [queue_manager_name, job, exception, :stacktrace], :ok)
    expect(Verk.QueueManager, :ack, [queue_manager_name, job], :ok)

    assert handle_cast({ :failed, worker, job_id, exception, :stacktrace }, state) == { :noreply, state, 0 }

    assert :ets.lookup(monitors, worker) == []
    assert_receive %Verk.Events.JobFailed{ job: ^job, failed_at: _,
                                           stacktrace: :stacktrace,
                                           exception: ^exception }

    assert validate [Verk.Log, Verk.QueueManager]
  end
end
