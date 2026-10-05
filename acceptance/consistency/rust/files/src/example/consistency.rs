// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(unused_variables, non_snake_case)]
use crate::lawspec_data::Views;
use std::collections::HashMap;
use std::sync::Mutex;

// A page-view counter with one replica per thread.
static REPLICAS: Mutex<Vec<HashMap<std::thread::ThreadId, i64>>> = Mutex::new(Vec::new());

pub fn newViews(value0: ()) -> Views {
    let mut replicas = REPLICAS.lock().unwrap();
    replicas.push(HashMap::new());
    Views { id: (replicas.len() - 1) as i32 }
}

pub fn hit(value0: Views) -> i64 {
    let mut replicas = REPLICAS.lock().unwrap();
    let mine = replicas[value0.id as usize].entry(std::thread::current().id()).or_insert(0);
    *mine += 1;
    *mine
}

pub fn total(value0: Views) -> i64 {
    REPLICAS.lock().unwrap()[value0.id as usize].values().sum()
}
