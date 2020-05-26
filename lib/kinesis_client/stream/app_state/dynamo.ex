defmodule KinesisClient.Stream.AppState.Dynamo do
  @moduledoc false
  alias KinesisClient.Stream.AppState.Adapter, as: AppStateAdapter
  alias KinesisClient.Stream.AppState.ShardLease
  alias ExAws.Dynamo

  @behaviour AppStateAdapter

  @impl AppStateAdapter
  def create_lease(app_name, shard_id, lease_owner, _opts \\ []) do
    update_opt = [condition_expression: "attribute_not_exists(shard_id)"]

    shard_lease = %ShardLease{
      shard_id: shard_id,
      lease_owner: lease_owner,
      completed: false,
      lease_count: 1
    }

    case Dynamo.put_item(app_name, shard_lease, update_opt) |> ExAws.request() do
      {:ok, _} ->
        :ok

      {:error, {"ConditionalCheckFailedException", "The conditional request failed"}} ->
        :already_exists

      output ->
        output
    end
  end

  @impl AppStateAdapter
  def get_lease(app_name, shard_id, _opts) do
    case Dynamo.get_item(app_name, %{"shard_id" => shard_id}) |> ExAws.request() do
      {:ok, %{"Item" => _} = item} -> item |> decode_item()
      {:ok, _} -> :not_found
      other -> other
    end
  end

  @impl AppStateAdapter
  def renew_lease(app_name, %{shard_id: shard_id, lease_count: lease_count} = shard_lease, _opts) do
    updated_count = lease_count + 1

    update_opt = [
      condition_expression: "lease_count = :lc AND lease_owner = :lo",
      expression_attribute_values: %{
        lc: lease_count,
        lo: shard_lease.lease_owner,
        new_lease_count: updated_count
      },
      update_expression: "SET lease_count = :new_lease_count",
      return_values: "UPDATED_NEW"
    ]

    case Dynamo.update_item(app_name, %{"shard_id" => shard_id}, update_opt) |> ExAws.request() do
      {:ok, %{"Attributes" => %{"lease_count" => _}}} -> {:ok, updated_count}
      {:error, {"ConditionalCheckFailedException", _}} -> {:error, :lease_renew_failed}
      reply -> reply
    end
  end

  @impl AppStateAdapter
  def take_lease(app_name, shard_id, new_lease_owner, lease_count, _opts) do
    updated_count = lease_count + 1

    update_opt = [
      condition_expression: "lease_count = :lc AND lease_owner <> :lo",
      expression_attribute_values: %{
        lc: lease_count,
        lo: new_lease_owner,
        new_lease_count: updated_count
      },
      update_expression: "SET lease_count = :new_lease_count, lease_owner = :lo",
      return_values: "UPDATED_NEW"
    ]

    case Dynamo.update_item(app_name, %{"shard_id" => shard_id}, update_opt) |> ExAws.request() do
      {:ok, %{"Attributes" => %{"lease_count" => _}}} -> {:ok, updated_count}
      {:error, {"ConditionalCheckFailedException", _}} -> {:error, :lease_take_failed}
      reply -> reply
    end
  end

  @impl AppStateAdapter
  def update_checkpoint(app_name, shard_id, lease_owner, checkpoint, _opts) do
    update_opt = [
      condition_expression: "lease_owner = :lo",
      expression_attribute_values: %{
        lo: lease_owner,
        checkpoint_num: checkpoint
      },
      update_expression: "SET checkpoint = :checkpoint_num",
      return_values: "UPDATED_NEW"
    ]

    case Dynamo.update_item(app_name, %{"shard_id" => shard_id}, update_opt) |> ExAws.request() do
      {:ok, %{"Attributes" => %{"checkpoint" => %{"S" => ^checkpoint}}}} -> :ok
      {:error, {"ConditionalCheckFailedException", _}} -> {:error, :lease_owner_match}
      reply -> reply
    end
  end

  defp decode_item(item) do
    item
    |> Dynamo.decode_item(as: KinesisClient.Stream.AppState.ShardLease)
  end
end
