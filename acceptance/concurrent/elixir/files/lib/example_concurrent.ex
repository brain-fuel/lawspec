# ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
defmodule Example.Concurrent do
  alias LawSpec.Data.{WorkQueue, Tags, Cache}
  def new_queue(:ok), do: %WorkQueue{id: :beam_collections.new(0)}
  def offer(%WorkQueue{id: id}, value) do
    true = :beam_collections.offer(id, value)
    :ok
  end
  def poll(%WorkQueue{id: id}), do: :beam_collections.poll(id)
  def queue_size(%WorkQueue{id: id}), do: :beam_collections.size(id)
  def new_tags(:ok), do: %Tags{id: :beam_collections.new(1)}
  def tag(%Tags{id: id}, value), do: :beam_collections.add(id, value)
  def untag(%Tags{id: id}, value), do: :beam_collections.remove(id, value)
  def tagged(%Tags{id: id}, value), do: :beam_collections.contains(id, value)
  def new_cache(:ok), do: %Cache{id: :beam_collections.new(2)}
  def store(%Cache{id: id}, key, value), do: :beam_collections.put(id, key, value)
  def fetch(%Cache{id: id}, key), do: :beam_collections.get(id, key)
  def evict(%Cache{id: id}, key), do: :beam_collections.evict(id, key)
end
