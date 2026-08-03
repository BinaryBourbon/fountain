defmodule Fountain.TelemetryTick do
  @moduledoc """
  Guard for `telemetry_poller` measurement functions (#365, #395).

  The poller catches all three classes — `error`, `exit` and `throw` — and
  permanently drops a measurement that fails, so a single boot tick racing
  Repo startup or one DB blip silently kills a gauge for the node's
  lifetime. The class Repo actually produces under a checkout timeout or a
  dying pool is an *exit*, which the original `rescue`-only guard (#365)
  did not cover (#395). Skip the datapoint and let the next tick retry.
  """

  require Logger

  @spec run(String.t(), (-> any())) :: :ok
  def run(label, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.warning("#{label} tick skipped: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("#{label} tick skipped: #{inspect({kind, reason})}")
      :ok
  end
end
