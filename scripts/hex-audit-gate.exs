# `mix hex.audit` uses one non-zero exit code for two findings with different
# CI policies: security advisories must block a build, while a package that an
# upstream maintainer retires must remain visible without breaking unrelated
# work. Hex applies the reviewable advisory acknowledgements from mix.exs; this
# wrapper only separates the resulting exit status.

defmodule HexAuditGate do
  @advisory_failure "Found packages with security advisories"
  @retirement_failure "Found retired packages"
  @ansi_escape ~r/\e\[[0-9;]*m/

  def run do
    {output, status} = System.cmd("mix", ["hex.audit"], stderr_to_stdout: true)
    IO.write(output)

    plain_output = Regex.replace(@ansi_escape, output, "")

    cond do
      status == 0 ->
        0

      String.contains?(plain_output, @advisory_failure) ->
        status

      String.contains?(plain_output, @retirement_failure) ->
        IO.puts("\nRetired dependencies are reported above but do not block CI.")
        0

      true ->
        IO.puts(:stderr, "\nhex.audit failed without a finding summary; failing closed.")
        status
    end
  end
end

System.halt(HexAuditGate.run())
