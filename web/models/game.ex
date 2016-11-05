defmodule PairsOne.Game do
  @moduledoc """
  Game persistence with Redis.

  Note that currently the board can only be a square (n*n, not n*m).
  It would require a minor refactoring to remove this limitation.
  """

  alias PairsOne.Theme

  defstruct id: "", cards: [], players: [], theme: "eighties", flips: 2, turn: -1, visibility: "public"

  @redis_prefix "game:"

  @doc """
  Fetch persisted game by its id
  """
  def get(id) do
    id |> get_json |> Poison.decode!
  end

  @doc """
  Check whether game with given id is persisted
  """
  def exists?(id) do
    {:ok, conn} = Redix.start_link
    res = Redix.command(conn, ["EXISTS", "#{@redis_prefix}#{id}"])
    conn |> Redix.stop
    case res do
      {:ok, res} -> res == 1
      _ -> false
    end
  end

  @doc """
  Create and returns new game given its params
  """
  def create(%{"board_size" => board_size, "players_number" => players_number, "theme" => theme_name, "visibility" => visibility}) do
    players_number = String.to_integer players_number
    board_size = String.to_integer board_size

    id = UUID.uuid4 |> String.split("-") |> List.last

    players = (0..players_number - 1) |> Enum.map(fn _ -> %PairsOne.Player{id: "", name: ""} end)

    game = %PairsOne.Game{
      id: id,
      cards: cards(board_size, Theme.cards_number(theme_name)),
      players: players,
      theme: theme_name,
      visibility: visibility
    }

    save!(id, game)

    game
  end

  @doc """
  Save game with provided id
  """
  def save!(id, game) do
    {:ok, game_string} = Poison.encode(game)
    {:ok, conn} = Redix.start_link
    conn |> Redix.command(["SET", "#{@redis_prefix}#{id}", game_string])
    conn |> Redix.command(["EXPIRE", "#{@redis_prefix}#{id}", 24 * 60 * 60])
    conn |> Redix.stop
    game
  end

  @doc """
  Given new params, reset completed game
  """
  def replay(game, %{"theme" => theme_name}) do
    players = Enum.map game["players"], fn (player) -> %{player | "score" => 0, "turns" => 0, "inaccurateTurns" => 0} end

    theme = Theme.get(theme_name)

    cards = game["cards"]
            |> length
            |> :math.sqrt
            |> round
            |> cards(theme.cards)

    game = %{game | "cards" => cards, "players" => players, "theme" => theme_name}

    save!(game["id"], game)
  end

  @doc """
  Given player id and game, try to join the player to the game:
  1) If player is already in the game (which happens when the user reloads the page), return that player.
  2) If player is new, try to find a vacant slot.
  3) Otherwise return nil.
  """
  def join_player(game, %{"id" => id, "name" => _} = player) do
    index = player_index(game["players"], id)
    join_player_at(game, index, player)
  end

  # Return list of shuffled cards on the board, given board size and number of cards in the theme
  defp cards(board_size, cards_number) do
    card_values = Enum.take_random(1..cards_number, trunc(board_size * board_size / 2))
    double_values = card_values ++ card_values
    double_values |> Enum.shuffle |> Enum.map(fn value -> %PairsOne.Card{value: value} end)
  end

  # Do not join player at a given index if the index is nil
  defp join_player_at(_, nil, _) do
  end

  # Join player at a given index
  defp join_player_at(game, index, player) do
    players = game["players"]

    player_overrides = %{
      "id" => player["id"],
      "name" => player["name"],
      "joined" => true,
      "online" => true
    }

    player = Map.merge(Enum.at(players, index), player_overrides)

    players = List.replace_at(players, index, player)

    game = %{game | "players" => players}

    game = set_turn(game)

    save!(game["id"], game)

    player
  end

  # Set initial game turn if all players have joined
  defp set_turn(%{"turn" => -1, "players" => players} = game) do
    turn = if all_players_joined?(players) do 0 else -1 end
    %{game | "turn" => turn}
  end

  # Do not change turn if the game is running already
  defp set_turn(game) do
    game
  end

  # Check whether all players in the game have "joined" status
  def all_players_joined?(players) do
    Enum.all?(players, fn(p) -> p["joined"] end)
  end

  def any_player_online?(game) do
    Enum.any?(game["players"], fn(p) -> p["online"] end)
  end

  def game_data_for_list(game) do
    playerJson = fn(player) ->
      %{name: player["online"]}
    end

    size = length(game["cards"]) |> :math.sqrt |> round
    %{
      id: game["id"],
      theme: game["theme"],
      size: "#{size}x#{size}",
      players: Enum.map(game["players"], playerJson)
    }
  end

  # Given player id, try to find at what index to join the player
  defp player_index(players, player_id) do
    ok? = fn(player) ->
      player["id"] == player_id || not player["joined"]
    end

    Enum.find_index(players, ok?)
  end

  # Given game's id, fetches game's JSON from Redis
  defp get_json(id) do
    {:ok, conn} = Redix.start_link
    res = Redix.command(conn, ["GET", "#{@redis_prefix}#{id}"])
    conn |> Redix.stop
    case res do
      {:ok, game_string} -> game_string
      _ -> :undefined
    end
  end
end
