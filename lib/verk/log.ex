defmodule Verk.Log do
  @moduledoc """
  Helper module to log when a job starts, fails or finishes.
  """

  require Logger
  import Logger
  alias Verk.Job

  def start(%Job{jid: job_id, class: module}, process_id) do
    info("#{module} #{job_id} start", process_id: inspect(process_id))
  end

  def done(%Job{jid: job_id, class: module}, start_time, process_id) do
    info("#{module} #{job_id} done: #{elapsed_time(start_time)}", process_id: inspect(process_id))
  end

  def fail(%Job{jid: job_id, class: module}, start_time, process_id) do
    info("#{module} #{job_id} fail: #{elapsed_time(start_time)}", process_id: inspect(process_id))
  end

  defp elapsed_time(start_time) do
    duration = Timex.diff(Timex.now, start_time, :duration)

    if Timex.Duration.to_seconds(duration) == 0 do
      milliseconds_diff = Timex.Duration.to_milliseconds(duration)
      "#{trunc(milliseconds_diff)} ms"
    else
      "#{trunc(Timex.Duration.to_seconds(duration))} s"
    end
  end
end
