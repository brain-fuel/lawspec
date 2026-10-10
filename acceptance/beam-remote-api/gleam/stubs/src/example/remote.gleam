// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/example/remote as abilities_example_remote

pub fn native_probe(_argument0: Nil) -> Bool {
  panic as "Not implemented: example.remote::nativeProbe"
}

pub fn offset_handler() -> abilities_example_remote.Offset {
  abilities_example_remote.offset(
    fn(_argument0) { panic as "Not implemented: example.remote::ability::Offset.shift" }
  )
}
