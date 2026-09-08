defmodule Fountain.Build.HexAdvisories do
  @moduledoc """
  Acknowledgments restricted to the exact reviewed Hex artifact.

  EEF-CVE-2026-32686's September 8 feed lost the fixed boundary and lists
  Decimal 3.1.1 as affected. The maintainer identifies 3.0.0 as patched:
  https://github.com/ericmj/decimal/security/advisories/GHSA-rhv4-8758-jx7v

  The reviewed 3.1.1 package rejects the reported exponent inputs by default.
  Remove this acknowledgment when the EEF feed is corrected. Any version,
  checksum or repository change drops it automatically; other advisories retain
  their normal gate. Parsing the lock file never evaluates its contents.
  """

  @decimal [
    :hex,
    :decimal,
    "3.1.1",
    "430d87b04011ce6cbd4fd205be758311a81f87d552d40904abd00f015935b1d0",
    [:mix],
    [],
    "hexpm",
    "c5f25f2ced74a0587d03e6023f595db8e924c9d3922c8c8ffd9edfc4498cf1f6"
  ]

  def for_lock(path) do
    with {:ok, source} <- File.read(path),
         {:ok, {:%{}, _, entries}} <- Code.string_to_quoted(source, emit_warnings: false),
         [{:{}, _, @decimal}] <- for({:decimal, value} <- entries, do: value) do
      ["EEF-CVE-2026-32686"]
    else
      _ -> []
    end
  end
end
