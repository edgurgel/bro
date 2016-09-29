defmodule Verk.JobTest do
  use ExUnit.Case
  alias Verk.Job

  test "decode! includes original json" do
    payload = ~s({ "queue" : "test_queue", "args" : [1, 2, 3],
                 "max_retry_count" : 5})

    assert Job.decode!(payload) == %Job{ queue: "test_queue", args: [1, 2, 3], original_json: payload, max_retry_count: 5}
  end
end
