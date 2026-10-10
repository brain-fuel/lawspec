# ref:REQ-law-primitives
defmodule Example.BeamResources do
  def open_store(a0), do: :beam_resource_support.open_store(a0)
  def close_store(a0), do: :beam_resource_support.close_store(a0)
  def size(a0), do: :beam_resource_support.size(a0)
  def write(a0, a1), do: :beam_resource_support.write(a0, a1)
  def is_open(a0), do: :beam_resource_support.is_open(a0)
  def directory_empty(a0), do: :beam_resource_support.directory_empty(a0)
  def write_note(a0, a1), do: :beam_resource_support.write_note(a0, a1)
  def note_matches(a0, a1), do: :beam_resource_support.note_matches(a0, a1)
  def file_empty(a0), do: :beam_resource_support.file_empty(a0)
  def set_greeting(a0), do: :beam_resource_support.set_greeting(a0)
  def greeting_matches(a0), do: :beam_resource_support.greeting_matches(a0)
  def greeting_absent(a0), do: :beam_resource_support.greeting_absent(a0)
end
