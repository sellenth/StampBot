defmodule DragNStampWeb.LiveHelpers do
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    socket = assign_current_user(socket, session)
    {:cont, socket}
  end

  defp assign_current_user(socket, session) do
    case session do
      %{"user_id" => user_id} ->
        user = DragNStamp.Accounts.get_user(user_id)
        assign(socket, :current_user, user)

      _ ->
        assign(socket, :current_user, nil)
    end
  end
end