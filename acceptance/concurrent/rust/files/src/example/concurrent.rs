// Scaffolded by LawSpec. User-owned; never overwritten.
// A queue, a set and a map shared between threads, each guarded by its own
// lock.
#![allow(non_snake_case)]
use crate::lawspec_data::{Cache, Tags, WorkQueue};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

type Registry<T> = LazyLock<Mutex<HashMap<i32, Arc<Mutex<T>>>>>;

static IDS: AtomicI32 = AtomicI32::new(0);
static QUEUES: Registry<VecDeque<i32>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static SETS: Registry<HashSet<i32>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static MAPS: Registry<HashMap<i8, i64>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn new<T: Default>(registry: &Registry<T>) -> i32 {
    let id = IDS.fetch_add(1, Ordering::SeqCst);
    registry.lock().unwrap().insert(id, Arc::new(Mutex::new(T::default())));
    id
}

// A structure by its handle; generated tests may name one first.
fn get<T: Default>(registry: &Registry<T>, id: i32) -> Arc<Mutex<T>> {
    registry.lock().unwrap().entry(id).or_default().clone()
}

pub fn newQueue(value0: ()) -> WorkQueue {
    WorkQueue { id: new(&QUEUES) }
}

pub async fn offer(value0: WorkQueue, value1: i32) {
    get(&QUEUES, value0.id).lock().unwrap().push_back(value1);
}

pub async fn poll(value0: WorkQueue) -> Option<i32> {
    let items = get(&QUEUES, value0.id);
    items.lock().unwrap().pop_front()
}

pub async fn queueSize(value0: WorkQueue) -> i64 {
    get(&QUEUES, value0.id).lock().unwrap().len() as i64
}

pub fn newTags(value0: ()) -> Tags {
    Tags { id: new(&SETS) }
}

pub async fn tag(value0: Tags, value1: i32) -> bool {
    let items = get(&SETS, value0.id);
    let mut items = items.lock().unwrap();
    let added = !items.contains(&value1);
    items.insert(value1);
    added
}

pub async fn untag(value0: Tags, value1: i32) -> bool {
    get(&SETS, value0.id).lock().unwrap().remove(&value1)
}

pub async fn tagged(value0: Tags, value1: i32) -> bool {
    get(&SETS, value0.id).lock().unwrap().contains(&value1)
}

pub fn newCache(value0: ()) -> Cache {
    Cache { id: new(&MAPS) }
}

pub async fn store(value0: Cache, value1: i8, value2: i64) -> Option<i64> {
    let entries = get(&MAPS, value0.id);
    let mut entries = entries.lock().unwrap();
    let previous = entries.get(&value1).copied();
    entries.insert(value1, value2);
    previous
}

pub async fn fetch(value0: Cache, value1: i8) -> Option<i64> {
    get(&MAPS, value0.id).lock().unwrap().get(&value1).copied()
}

pub async fn evict(value0: Cache, value1: i8) -> Option<i64> {
    get(&MAPS, value0.id).lock().unwrap().remove(&value1)
}
