// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store, a handle around a shared map.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

// An in-memory log store: each log's records, newest last.
struct LogStore {
    logs: Mutex<HashMap<String, Vec<String>>>,
    open: Mutex<bool>,
}

fn logs(value: &crate::lawspec_data::Store) -> &Arc<LogStore> {
    value.native::<Arc<LogStore>>().expect("a Store handle")
}

// LawSpec: (Unit -> example.composition::type::Store)
pub fn openStore(value0: ()) -> crate::lawspec_data::Store {
    ls::Handle::new(Arc::new(LogStore {
        logs: Mutex::new(HashMap::new()),
        open: Mutex::new(true),
    }))
}

// LawSpec: (example.composition::type::Store -> Unit)
pub fn closeStore(value0: crate::lawspec_data::Store) -> () {
    *logs(&value0).open.lock().unwrap() = false;
}

/// The native handler of Logs: create, append.
pub struct LogsHandler {
    pub resource: crate::lawspec_data::Store,
}

impl LogsHandler {
    pub fn new(resource: crate::lawspec_data::Store) -> Self {
        Self { resource }
    }
}

impl crate::lawspec_abilities::example_composition::Logs for LogsHandler {
    fn create(&self, value0: std::string::String) -> () {
        logs(&self.resource)
            .logs
            .lock()
            .unwrap()
            .insert(value0, vec![]);
    }

    fn append(&self, value0: std::string::String, value1: std::string::String) -> i64 {
        let mut all = logs(&self.resource).logs.lock().unwrap();
        let Some(records) = all.get_mut(&value0) else {
            drop(all);
            ls::fail(crate::lawspec_data::Problem::UnknownLog);
        };
        if value1.is_empty() {
            drop(all);
            ls::fail(crate::lawspec_data::Problem::EmptyRecord);
        }
        records.push(value1);
        (records.len() - 1) as i64
    }
}

/// The native handler of Reader: size.
pub struct ReaderHandler {
    pub resource: crate::lawspec_data::Store,
}

impl ReaderHandler {
    pub fn new(resource: crate::lawspec_data::Store) -> Self {
        Self { resource }
    }
}

impl crate::lawspec_abilities::example_composition::Reader for ReaderHandler {
    fn size(&self, value0: std::string::String) -> std::option::Option<i64> {
        logs(&self.resource)
            .logs
            .lock()
            .unwrap()
            .get(&value0)
            .map(|records| records.len() as i64)
    }
}

/// The native handler of Writer: write, lastOffset.
pub struct WriterHandler {
    pub resource: crate::lawspec_data::Store,
    last: Mutex<Option<i64>>,
}

impl WriterHandler {
    pub fn new(resource: crate::lawspec_data::Store) -> Self {
        Self {
            resource,
            last: Mutex::new(None),
        }
    }
}

impl crate::lawspec_abilities::example_composition::Writer for WriterHandler {
    fn write(&self, value0: std::string::String, value1: std::string::String) -> bool {
        let mut all = logs(&self.resource).logs.lock().unwrap();
        match all.get_mut(&value0) {
            Some(records) if !value1.is_empty() => {
                records.push(value1);
                *self.last.lock().unwrap() = Some((records.len() - 1) as i64);
                true
            }
            _ => false,
        }
    }

    fn lastOffset(&self) -> std::option::Option<i64> {
        *self.last.lock().unwrap()
    }
}
