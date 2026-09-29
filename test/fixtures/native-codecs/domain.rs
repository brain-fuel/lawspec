#[derive(Clone, Debug)]
pub struct Parcel<T>(T);
impl<T> Parcel<T> {
    pub fn new(value: T) -> Self {
        Self(value)
    }
    pub fn into_inner(self) -> T {
        self.0
    }
}

// Application representation has no recursive Box nodes.
#[derive(Clone, Debug)]
pub struct FlatChain<T> {
    items: Vec<T>,
    explicit_stop: bool,
}
impl<T> FlatChain<T> {
    pub fn new(items: Vec<T>, explicit_stop: bool) -> Self {
        Self {
            items,
            explicit_stop,
        }
    }
    pub fn into_parts(self) -> (Vec<T>, bool) {
        (self.items, self.explicit_stop)
    }
}

#[derive(Clone, Debug)]
pub struct Positive(i8);
impl Positive {
    pub fn new(value: i8) -> Self {
        Self(value)
    }
    pub fn into_inner(self) -> i8 {
        self.0
    }
}

pub fn copy<T>(value: T) -> T {
    value
}
