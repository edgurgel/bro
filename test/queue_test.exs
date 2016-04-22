defmodule Verk.QueueTest do
  use ExUnit.Case
  import Verk.Queue

  @queue     "default"
  @queue_key "queue:default"

  setup do
    { :ok, pid } = Application.fetch_env(:verk, :redis_url)
                    |> elem(1)
                    |> Redix.start_link([name: Verk.Redis])
    Redix.command!(pid, ~w(DEL #{@queue_key}))
    on_exit fn ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, _, _, _}
    end
    :ok
  end

  test "count empty queue" do
    assert count(@queue) == {:ok, 0}
  end

  test "count" do
    Redix.command!(Verk.Redis, ~w(LPUSH #{@queue_key} 1 2 3))

    assert count(@queue) == {:ok, 3}
  end

  test "count!" do
    Redix.command!(Verk.Redis, ~w(LPUSH #{@queue_key} 1 2 3))

    assert count!(@queue) == 3
  end

  test "clear" do
    assert clear(@queue) == {:error, %RuntimeError{message: ~s(Queue "#{@queue}" not found.)}}

    Redix.command!(Verk.Redis, ~w(LPUSH #{@queue_key} 1 2 3))
    assert clear(@queue) == :ok

    assert Redix.command!(Verk.Redis, ~w(GET #{@queue_key})) == nil
  end

  test "clear!" do
    Redix.command!(Verk.Redis, ~w(LPUSH #{@queue_key} 1 2 3))
    assert clear!(@queue) == nil

    assert Redix.command!(Verk.Redis, ~w(GET #{@queue_key})) == nil
  end

  test "range" do
    job = %Verk.Job{class: "Class", args: []}
    json = Poison.encode!(job)
    Redix.command!(Verk.Redis, ~w(LPUSH #{@queue_key} #{json}))

    assert range(@queue) == {:ok, [%{ job | original_json: json }]}
  end

  test "range with no items" do
    assert range(@queue) == {:ok, []}
  end

  test "range!" do
    assert range!(@queue) == []
  end

  test "delete_job having job with original_json" do
    job = %Verk.Job{class: "Class", args: []}
    json = Poison.encode!(job)

    Redix.command!(Verk.Redis, ~w(LPUSH #{@queue_key} #{json}))

    job = %{ job | original_json: json}

    assert delete_job(@queue, job) == :ok
  end

  test "delete_job! having job with original_json" do
    job = %Verk.Job{class: "Class", args: []}
    json = Poison.encode!(job)

    Redix.command!(Verk.Redis, ~w(LPUSH #{@queue_key} #{json}))

    job = %{ job | original_json: json}

    assert delete_job!(@queue, job) == nil
  end

  test "delete_job with original_json" do
    json = %Verk.Job{class: "Class", args: []} |> Poison.encode!

    assert delete_job(@queue, json) == {:error, %RuntimeError{message: ~s(Job not found in queue "#{@queue}".)}}

    Redix.command!(Verk.Redis, ~w(LPUSH #{@queue_key} #{json}))

    assert delete_job(@queue, json) == :ok
  end

  test "delete_job! with original_json" do
    json = %Verk.Job{class: "Class", args: []} |> Poison.encode!

    Redix.command!(Verk.Redis, ~w(LPUSH #{@queue_key} #{json}))

    assert delete_job!(@queue, json) == nil
  end
end
