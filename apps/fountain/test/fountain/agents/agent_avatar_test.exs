defmodule Fountain.Agents.AgentAvatarTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents

  describe "upload_avatar/3" do
    test "stores avatar data and sets avatar_media_type on the agent" do
      agent = insert_agent()

      assert {:ok, updated} = Agents.upload_avatar(agent, "img-data", "image/jpeg")
      assert updated.avatar_media_type == "image/jpeg"
    end

    test "replaces an existing avatar" do
      agent = insert_agent()
      {:ok, with_avatar} = Agents.upload_avatar(agent, "first", "image/png")
      {:ok, replaced} = Agents.upload_avatar(with_avatar, "second", "image/jpeg")

      assert replaced.avatar_media_type == "image/jpeg"

      avatar = Agents.get_avatar(replaced)
      assert avatar.data == "second"
    end

    test "rejects a media type outside the image allowlist" do
      # The stored media type is echoed into Content-Type at serve time, and
      # LiveView's upload accept: list passes an entry whose filename
      # extension matches even when the declared MIME type does not — so
      # without this check a crafted client stores text/html and gets it
      # served as active content from the app's own origin.
      agent = insert_agent()

      assert {:error, :invalid_media_type} =
               Agents.upload_avatar(agent, "<script>alert(1)</script>", "text/html")

      assert Agents.get_avatar(agent) == nil
    end
  end

  describe "delete_avatar/1" do
    test "clears avatar_media_type and removes the blob" do
      agent = insert_agent()
      {:ok, with_avatar} = Agents.upload_avatar(agent, "blob", "image/png")

      assert {:ok, cleared} = Agents.delete_avatar(with_avatar)
      assert cleared.avatar_media_type == nil
      assert Agents.get_avatar(cleared) == nil
    end

    test "succeeds when agent has no avatar" do
      agent = insert_agent()

      assert {:ok, updated} = Agents.delete_avatar(agent)
      assert updated.avatar_media_type == nil
    end
  end

  describe "get_avatar/1" do
    test "returns nil when no avatar has been uploaded" do
      agent = insert_agent()
      assert Agents.get_avatar(agent) == nil
    end

    test "returns the avatar blob when one exists" do
      agent = insert_agent()
      {:ok, updated} = Agents.upload_avatar(agent, "blob-bytes", "image/webp")

      avatar = Agents.get_avatar(updated)
      assert avatar.data == "blob-bytes"
    end
  end
end
