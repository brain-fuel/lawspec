// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store, an ETS table of each log's records.
import gleam/list
import gleam/option.{type Option, None, Some}
import lawspec/abilities/example/composition as abilities_example_composition
import lawspec/data
import lawspec/effects
import lawspec/failures

@external(erlang, "composition_store", "open")
fn open() -> data.Store

@external(erlang, "composition_store", "close")
fn close(store: data.Store) -> Nil

@external(erlang, "composition_store", "records")
fn records(store: data.Store, log: String) -> Option(List(String))

@external(erlang, "composition_store", "put")
fn put(store: data.Store, log: String, records: List(String)) -> Nil

pub fn open_store(_argument0: Nil) -> data.Store {
  open()
}

pub fn close_store(store: data.Store) -> Nil {
  close(store)
}

pub fn logs_handler(store: data.Store) -> abilities_example_composition.Logs {
  abilities_example_composition.logs(
    fn(log) { put(store, log, []) },
    fn(log, record) {
      case records(store, log) {
        None -> failures.fail(data.ProblemUnknownLog)
        Some(_) if record == "" -> failures.fail(data.ProblemEmptyRecord)
        Some(existing) -> {
          put(store, log, list.append(existing, [record]))
          list.length(existing)
        }
      }
    },
  )
}

pub fn reader_handler(store: data.Store) -> abilities_example_composition.Reader {
  abilities_example_composition.reader(fn(log) {
    case records(store, log) {
      None -> None
      Some(existing) -> Some(list.length(existing))
    }
  })
}

pub fn writer_handler(store: data.Store) -> abilities_example_composition.Writer {
  let last = effects.new_cell(None)
  abilities_example_composition.writer(
    fn(log, record) {
      case records(store, log) {
        Some(existing) if record != "" -> {
          put(store, log, list.append(existing, [record]))
          effects.write_cell(last, Some(list.length(existing)))
          True
        }
        _ -> False
      }
    },
    fn() { effects.read_cell(last) },
  )
}
