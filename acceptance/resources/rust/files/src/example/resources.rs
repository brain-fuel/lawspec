// User-owned LawSpec adapters for the resources example.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

// An in-memory store. At most three may be open at once, so a store that is
// never closed is noticed.
struct Store {
    items: Mutex<HashMap<i32, i32>>,
    open: Mutex<bool>,
}

static OPEN_COUNT: AtomicUsize = AtomicUsize::new(0);

fn store(value: &crate::lawspec_data::Store) -> &Arc<Store> {
    value.native::<Arc<Store>>().expect("a Store handle")
}

// LawSpec: (Unit -> example.resources::type::Store)
pub fn openStore(value0: ()) -> crate::lawspec_data::Store {
    if OPEN_COUNT.fetch_add(1, Ordering::SeqCst) >= 3 {
        panic!("too many open stores: one was never closed");
    }
    ls::Handle::new(Arc::new(Store { items: Mutex::new(HashMap::new()), open: Mutex::new(true) }))
}

// LawSpec: (example.resources::type::Store -> Unit)
pub fn closeStore(value0: crate::lawspec_data::Store) -> () {
    let mut open = store(&value0).open.lock().unwrap();
    if *open {
        *open = false;
        OPEN_COUNT.fetch_sub(1, Ordering::SeqCst);
    }
}

// LawSpec: (example.resources::type::Store -> Unit)
pub fn clearStore(value0: crate::lawspec_data::Store) -> () {
    store(&value0).items.lock().unwrap().clear();
}

// LawSpec: (example.resources::type::Store -> (Int32 -> (Int32 -> Unit)))
pub fn put(value0: crate::lawspec_data::Store, value1: i32, value2: i32) -> () {
    let s = store(&value0);
    assert!(*s.open.lock().unwrap(), "the store is closed");
    s.items.lock().unwrap().insert(value1, value2);
}

// LawSpec: (example.resources::type::Store -> (Int32 -> Maybe (Int32)))
pub fn get(value0: crate::lawspec_data::Store, value1: i32) -> Option<i32> {
    let s = store(&value0);
    assert!(*s.open.lock().unwrap(), "the store is closed");
    s.items.lock().unwrap().get(&value1).copied()
}

// LawSpec: (example.resources::type::Store -> Bool)
pub fn isOpen(value0: crate::lawspec_data::Store) -> bool {
    *store(&value0).open.lock().unwrap()
}

// LawSpec: (example.resources::type::Store -> Int32)
pub fn size(value0: crate::lawspec_data::Store) -> i32 {
    store(&value0).items.lock().unwrap().len() as i32
}

// LawSpec: (Text -> (Int32 -> Unit))
pub fn writeNote(value0: String, value1: i32) -> () {
    std::fs::write(std::path::Path::new(&value0).join("note.txt"), value1.to_string()).unwrap();
}

// LawSpec: (Text -> Maybe (Int32))
pub fn readNote(value0: String) -> Option<i32> {
    std::fs::read_to_string(std::path::Path::new(&value0).join("note.txt")).ok().map(|t| t.parse().unwrap())
}

// LawSpec: (Int32 -> Bool)
pub fn canListen(value0: i32) -> bool {
    std::net::TcpListener::bind(("127.0.0.1", value0 as u16)).is_ok()
}

// LawSpec: (Int32 -> Unit)
pub fn setGreeting(value0: i32) -> () {
    // SAFETY: a law that changes the environment takes a SavedEnvironment,
    // which holds the environment for its case alone.
    unsafe { std::env::set_var("LAWSPEC_EXAMPLE_GREETING", value0.to_string()) };
}

// LawSpec: (Unit -> Maybe (Int32))
pub fn greeting(value0: ()) -> Option<i32> {
    std::env::var("LAWSPEC_EXAMPLE_GREETING").ok().map(|t| t.parse().unwrap())
}
