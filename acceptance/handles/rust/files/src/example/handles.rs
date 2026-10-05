// Scaffolded by LawSpec. User-owned; never overwritten.
// Rust's standard library has no concurrent queue, so a Jobs handle wraps a
// queue behind a lock.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

type Queue = Arc<Mutex<VecDeque<i32>>>;

fn queue(jobs: &crate::lawspec_data::Jobs) -> &Queue {
    jobs.native::<Queue>().expect("a Jobs handle")
}

pub fn newJobs(value0: ()) -> crate::lawspec_data::Jobs {
    ls::Handle::new(Queue::default())
}

pub fn submit(value0: crate::lawspec_data::Jobs, value1: i32) -> () {
    queue(&value0).lock().unwrap().push_back(value1);
}

pub fn take(value0: crate::lawspec_data::Jobs) -> Option<i32> {
    queue(&value0).lock().unwrap().pop_front()
}

pub fn pending(value0: crate::lawspec_data::Jobs) -> i32 {
    queue(&value0).lock().unwrap().len() as i32
}
