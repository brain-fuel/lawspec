#[derive(Clone, Debug)]
pub struct Wrapped<T> {
    pub stored: T,
}

#[derive(Clone, Debug)]
pub enum Link<T> {
    End,
    Next {
        item: T,
        remainder: Option<Box<Link<T>>>,
    },
}

#[derive(Clone, Debug)]
pub enum Forest<T> {
    Item { datum: T },
    Group { trees: Vec<Forest<T>> },
}

#[derive(Clone, Debug)]
pub struct Seal {}

pub fn copy<T>(value: T) -> T {
    value
}
