defmodule Managoat.OAuth.TestInstance do
  @moduledoc "The instance the suite drives: TestRepo, default schema, the recording host."
  use Managoat.OAuth, otp_app: :managoat_oauth, host: Managoat.OAuth.Host.Recording
end

defmodule Managoat.OAuth.PrefixedInstance do
  @moduledoc "The same, over tables in the scratch schema the migration test creates."
  use Managoat.OAuth, otp_app: :managoat_oauth, host: Managoat.OAuth.Host.Recording
end

defmodule Managoat.OAuth.UnconfiguredInstance do
  @moduledoc "An instance nothing configured, for the error the config loader raises."
  use Managoat.OAuth, otp_app: :managoat_oauth, host: Managoat.OAuth.Host.Recording
end
