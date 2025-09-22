defmodule DragNStampWeb.LiveHelpers do
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    socket = assign_current_user(socket, session)
    {:cont, socket}
  end

  defp assign_current_user(socket, session) do
    case session do
      %{"user_id" => user_id} ->
        try do
          # Use a shorter timeout for user lookup to prevent connection pool exhaustion
          user = DragNStamp.Repo.get(DragNStamp.Accounts.User, user_id)
          assign(socket, :current_user, user)
        rescue
          DBConnection.ConnectionError -> 
            # Log the error but don't crash the LiveView
            require Logger
            Logger.warning("Database connection error while fetching user #{user_id}")
            assign(socket, :current_user, nil)
        end

      _ ->
        assign(socket, :current_user, nil)
    end
  end
end